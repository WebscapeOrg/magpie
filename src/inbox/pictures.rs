//! Sender pictures painted in Marmalade's ligne-claire style (C-039).
//!
//! Enterprise's engine paints one picture for each sender in an account's Inbox with OpenAI's image
//! model and Marmalade's avatar prompts. A sender with a contact photo is redrawn from that photo, a
//! sender at a company from the company's logo (one picture per domain), and anyone else as a
//! monogram of one letter, so no face is invented. `inbox.avatar` then serves the painted picture
//! cut to the circle.
//!
//! Invariants:
//! - Only a contact photo or a company logo, and the prompt text in `prompts`, leave Magpie. Names,
//!   addresses, subjects and message text are never sent.
//! - Each picture is paid for once. A refused picture is not asked for again, a lost one at most
//!   three times, and a day's spending stops at `DAILY_LIMIT_CENTS`, counted before each request.
//! - The key lives in the platform keyring and is never returned, logged or written elsewhere.
mod openai;
mod prompts;

use super::{avatars, now};
use crate::credentials::{self, CredentialKey, CredentialKind, Secret};
use crate::platform::{dirs::AppDirs, private_fs as fs};
use serde_json::{Value, json};
use std::{
    collections::{HashMap, HashSet},
    fs::File,
    io::Read,
    sync::{
        Arc, Mutex,
        atomic::{AtomicU64, Ordering},
    },
};

/// The model Marmalade paints its X avatars with (`OpenAI::ImageClient::DEFAULT_MODEL`).
pub(crate) const MODEL: &str = "gpt-image-2";
pub(crate) const DAILY_LIMIT_CENTS: i64 = 300;
/// Attempts for a picture that keeps failing for reasons that may pass, with the waits between them.
const ATTEMPTS: i64 = 3;
const RETRY_WAITS: [i64; 2] = [3_600_000, 6 * 3_600_000];
/// How often one account's Inbox is looked at for new senders.
const RUN_EVERY: i64 = 60_000;
const MAX_SENDERS: usize = 2_000;
const IN_FLIGHT: usize = 2;
const RATE_WAIT: i64 = 60_000;
const LOST_WAIT: i64 = 5 * 60_000;
const BILLING_WAIT: i64 = 3_600_000;
const MODEL_WAIT: i64 = 24 * 3_600_000;
const STATE: &str = "state.json";
const STATE_LIMIT: u64 = 16 * 1024 * 1024;
const MASTER_LIMIT: u64 = 2 * 1024 * 1024;

/// Changes whenever a picture is painted, so the window asks for its senders' pictures again.
static REVISION: AtomicU64 = AtomicU64::new(0);

pub(crate) fn revision() -> u64 {
    REVISION.load(Ordering::Relaxed)
}

fn slot() -> CredentialKey {
    CredentialKey {
        provider: "openai".into(),
        account_id: "default".into(),
        kind: CredentialKind::OpenAiApiKey,
    }
}

/// A 64-character hex name for a list of parts; addresses never appear in file or field names.
fn id(parts: &[&str]) -> String {
    super::store::key(parts).trim_end_matches(".json").to_owned()
}

#[derive(Clone, Debug, PartialEq, Eq)]
enum Subject {
    /// A contact with a photo; a changed photo is a new subject and is painted again.
    Person { address: String, photo: String },
    Organization { domain: String },
    Monogram { letter: char },
}

impl Subject {
    fn id(&self) -> String {
        match self {
            Self::Person { address, photo } => id(&["picture-person", address, photo]),
            Self::Organization { domain } => id(&["picture-organization", domain]),
            Self::Monogram { letter } => id(&["picture-monogram", &letter.to_string()]),
        }
    }
    fn kind(&self) -> &'static str {
        match self {
            Self::Person { .. } => "person",
            Self::Organization { .. } => "organization",
            Self::Monogram { .. } => "monogram",
        }
    }
}

/// The address and the monogram letter of each distinct sender, in the order given.
fn senders(headers: &[String]) -> Vec<(String, char)> {
    let mut seen = HashSet::new();
    let mut result = Vec::new();
    for header in headers {
        let Ok(list) = mailparse::addrparse(header) else {
            continue;
        };
        let Some(mailparse::MailAddr::Single(single)) = list.first().cloned() else {
            continue;
        };
        let Ok(address) = avatars::email(&single.addr) else {
            continue;
        };
        if seen.insert(address.clone()) {
            let name = single.display_name.unwrap_or_default();
            let letter = letter(&name, &address);
            result.push((address, letter));
        }
    }
    result
}

/// The first letter of the sender's name, or of the address when the name does not start with an
/// ASCII letter or digit. Invariant: the only character a monogram prompt can contain.
fn letter(name: &str, address: &str) -> char {
    let first = |text: &str| text.chars().find(|c| c.is_alphanumeric());
    first(name)
        .filter(char::is_ascii_alphanumeric)
        .or_else(|| first(address).filter(char::is_ascii_alphanumeric))
        .map(|c| c.to_ascii_uppercase())
        .unwrap_or('M')
}

fn subject_for(address: &str, letter: char, photos: &Value) -> Subject {
    let domain = address.split_once('@').map(|(_, domain)| domain).unwrap_or("");
    if let Some(photo) = photos[address]
        .as_str()
        .filter(|url| url.starts_with("https://") && url.len() <= 2048)
    {
        return Subject::Person {
            address: address.to_owned(),
            photo: photo.to_owned(),
        };
    }
    if !avatars::consumer(domain) {
        return Subject::Organization {
            domain: domain.to_owned(),
        };
    }
    Subject::Monogram { letter }
}

fn directory(create: bool) -> Result<Option<File>, &'static str> {
    fs::directories(&AppDirs::discover()?.state, &["omamail", "pictures"], create)
}

fn read_state(dir: &File) -> Result<Value, &'static str> {
    let Some(file) = fs::regular_readonly(dir, STATE)? else {
        return Ok(json!({}));
    };
    let mut bytes = Vec::new();
    file.take(STATE_LIMIT + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| "pictures_storage_unavailable")?;
    if bytes.len() as u64 > STATE_LIMIT {
        return Err("pictures_storage_unavailable");
    }
    let state: Value = serde_json::from_slice(&bytes).map_err(|_| "pictures_storage_unavailable")?;
    if !state.is_object() {
        return Err("pictures_storage_unavailable");
    }
    Ok(state)
}

/// Changes the state under the pictures lock, waiting up to two seconds for another holder.
/// Blocks the calling thread, so async callers run it through `blocking`.
fn change<T>(run: impl FnOnce(&File, &mut Value) -> Result<T, &'static str>) -> Result<T, &'static str> {
    let dir = directory(true)?.ok_or("pictures_storage_unavailable")?;
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(2);
    let _lock = loop {
        match fs::lock_exclusive(&dir, ".lock") {
            Err("private_fs_busy") if std::time::Instant::now() < deadline => {
                std::thread::sleep(std::time::Duration::from_millis(10));
            }
            other => break other?,
        }
    };
    let mut state = read_state(&dir)?;
    let before = state.clone();
    let result = run(&dir, &mut state)?;
    if state == before {
        return Ok(result);
    }
    let bytes = serde_json::to_vec(&state).map_err(|_| "pictures_storage_unavailable")?;
    if bytes.len() as u64 > STATE_LIMIT {
        return Err("pictures_storage_unavailable");
    }
    fs::atomic_replace(&dir, STATE, &bytes)?;
    fs::sync_dir(&dir)?;
    Ok(result)
}

async fn blocking<T: Send + 'static>(
    work: impl FnOnce() -> Result<T, &'static str> + Send + 'static,
) -> Result<T, &'static str> {
    tokio::task::spawn_blocking(work)
        .await
        .map_err(|_| "pictures_storage_unavailable")?
}

fn object(value: &mut Value, field: &str) -> Result<serde_json::Map<String, Value>, &'static str> {
    match value.get_mut(field).map(Value::take) {
        None | Some(Value::Null) => Ok(serde_json::Map::new()),
        Some(Value::Object(map)) => Ok(map),
        Some(_) => Err("pictures_storage_unavailable"),
    }
}

fn today(at: i64) -> String {
    use chrono::TimeZone;
    chrono::Local
        .timestamp_millis_opt(at)
        .single()
        .map(|time| time.format("%Y-%m-%d").to_string())
        .unwrap_or_default()
}

fn spent_today(state: &Value, at: i64) -> i64 {
    if state["day"].as_str() == Some(today(at).as_str()) {
        state["spentCents"].as_i64().unwrap_or(0)
    } else {
        0
    }
}

/// The problem that stops all painting now, if any. Key problems last until the key changes.
fn blocking_problem(state: &Value, at: i64) -> Option<&str> {
    let problem = state["problem"].as_str()?;
    match state["retryAt"].as_i64() {
        Some(retry) if retry <= at => None,
        _ => Some(problem),
    }
}

/// Forgets the senders of accounts that are no longer signed in, and every picture no sender
/// refers to any more, with its file.
fn forget(dir: &File, state: &mut Value, accounts: &HashSet<String>) -> Result<(), &'static str> {
    let mut senders = object(state, "senders")?;
    senders.retain(|_, row| row["account"].as_str().is_some_and(|account| accounts.contains(account)));
    let referenced: HashSet<String> = senders
        .values()
        .filter_map(|row| row["subject"].as_str().map(str::to_owned))
        .collect();
    let mut subjects = object(state, "subjects")?;
    let gone: Vec<String> = subjects
        .keys()
        .filter(|subject| !referenced.contains(*subject))
        .cloned()
        .collect();
    for subject in gone {
        subjects.remove(&subject);
        if subject.len() == 64 && subject.bytes().all(|b| b.is_ascii_hexdigit()) {
            fs::remove_owned(dir, &format!("{subject}.jpg"))?;
        }
    }
    state["senders"] = Value::Object(senders);
    state["subjects"] = Value::Object(subjects);
    Ok(())
}

/// Records which picture each Inbox sender gets and returns the pictures due for painting, in the
/// order of the senders, each once.
fn assign(
    state: &mut Value,
    account: &str,
    assignments: &[(String, Subject)],
    at: i64,
) -> Result<Vec<Subject>, &'static str> {
    let mut senders = object(state, "senders")?;
    let mut subjects = object(state, "subjects")?;
    let mut due = Vec::new();
    let mut listed = HashSet::new();
    for (sender, subject) in assignments {
        let subject_id = subject.id();
        senders.insert(sender.clone(), json!({"subject":subject_id,"account":account}));
        let row = subjects
            .entry(subject_id.clone())
            .or_insert_with(|| json!({"state":"waiting","attempts":0,"kind":subject.kind()}));
        let waiting = row["state"] == "waiting" && row["retryAt"].as_i64().is_none_or(|retry| retry <= at);
        if waiting && listed.insert(subject_id) {
            due.push(subject.clone());
        }
    }
    state["senders"] = Value::Object(senders);
    state["subjects"] = Value::Object(subjects);
    Ok(due)
}

/// Sets aside the estimate for one picture, unless painting is stopped or the day's limit would be
/// passed.
fn reserve(state: &mut Value, at: i64) -> bool {
    if blocking_problem(state, at).is_some() {
        return false;
    }
    let spent = spent_today(state, at);
    if spent + openai::ESTIMATE_CENTS > DAILY_LIMIT_CENTS {
        return false;
    }
    state["day"] = json!(today(at));
    state["spentCents"] = json!(spent + openai::ESTIMATE_CENTS);
    true
}

fn adjust(state: &mut Value, at: i64, cents: i64) {
    let spent = spent_today(state, at);
    state["day"] = json!(today(at));
    state["spentCents"] = json!((spent + cents).max(0));
}

enum Outcome {
    Painted { jpeg: Vec<u8>, cents: i64 },
    /// The contact photo could not be fetched; nothing was sent.
    NoReference,
    Fault(openai::Fault),
}

fn failed_once(row: &mut Value, reason: &str, at: i64) {
    let attempts = row["attempts"].as_i64().unwrap_or(0) + 1;
    row["attempts"] = json!(attempts);
    row["reason"] = json!(reason);
    if attempts >= ATTEMPTS {
        row["state"] = json!("failed");
        if let Some(row) = row.as_object_mut() {
            row.remove("retryAt");
        }
    } else {
        row["retryAt"] = json!(at + RETRY_WAITS[(attempts - 1) as usize]);
    }
}

fn stop(state: &mut Value, problem: &str, wait: Option<i64>, at: i64) {
    state["problem"] = json!(problem);
    state["retryAt"] = wait.map_or(Value::Null, |wait| json!(at + wait));
}

/// Writes a finished picture or the failure, and says whether painting must stop for now.
fn record(dir: &File, state: &mut Value, subject: &str, outcome: Outcome, at: i64) -> Result<bool, &'static str> {
    let refund = -openai::ESTIMATE_CENTS;
    let mut subjects = object(state, "subjects")?;
    let Some(row) = subjects.get_mut(subject) else {
        state["subjects"] = Value::Object(subjects);
        return Ok(false);
    };
    let halt = match outcome {
        Outcome::Painted { jpeg, cents } => {
            if let Err(error) = fs::atomic_replace(dir, &format!("{subject}.jpg"), &jpeg) {
                state["subjects"] = Value::Object(subjects);
                return Err(error);
            }
            *row = json!({"state":"painted","painted":at,"attempts":0,"kind":row["kind"]});
            adjust(state, at, cents - openai::ESTIMATE_CENTS);
            REVISION.fetch_add(1, Ordering::Relaxed);
            false
        }
        Outcome::NoReference => {
            adjust(state, at, refund);
            failed_once(row, "pictures_reference_unavailable", at);
            false
        }
        Outcome::Fault(openai::Fault::Refused) => {
            adjust(state, at, refund);
            row["state"] = json!("failed");
            row["reason"] = json!("pictures_refused");
            if let Some(row) = row.as_object_mut() {
                row.remove("retryAt");
            }
            false
        }
        Outcome::Fault(openai::Fault::Lost { charged }) => {
            if !charged {
                adjust(state, at, refund);
            }
            failed_once(row, "pictures_unreachable", at);
            stop(state, "pictures_unreachable", Some(LOST_WAIT), at);
            true
        }
        Outcome::Fault(fault) => {
            adjust(state, at, refund);
            match fault {
                openai::Fault::Key(problem) => stop(state, problem, None, at),
                openai::Fault::Billing => stop(state, "pictures_billing", Some(BILLING_WAIT), at),
                openai::Fault::RateLimited(wait) => {
                    stop(state, "pictures_rate_limited", Some(wait.unwrap_or(0).max(RATE_WAIT)), at)
                }
                _ => stop(state, "pictures_model_unavailable", Some(MODEL_WAIT), at),
            }
            true
        }
    };
    state["subjects"] = Value::Object(subjects);
    Ok(halt)
}

async fn reference(data: Option<String>) -> Option<Vec<u8>> {
    let data = data?;
    tokio::task::spawn_blocking(move || avatars::artwork::reference(&data).ok())
        .await
        .ok()
        .flatten()
}

async fn paint(subject: &Subject, key: &Secret) -> Outcome {
    let request = match subject {
        Subject::Person { photo, .. } => {
            let Some(png) = reference(crate::public_http::image(photo).await.ok()).await else {
                return Outcome::NoReference;
            };
            openai::Request::Edit { prompt: prompts::portrait(), reference: png }
        }
        Subject::Organization { domain } => match reference(avatars::organization_image(domain).await).await {
            Some(png) => openai::Request::Edit { prompt: prompts::logo(domain), reference: png },
            None => openai::Request::Generate { prompt: prompts::text_logo(domain) },
        },
        Subject::Monogram { letter } => openai::Request::Generate { prompt: prompts::monogram(*letter) },
    };
    match openai::paint(key, MODEL, &request).await {
        Ok(painted) => {
            let cents = painted.cents;
            match tokio::task::spawn_blocking(move || avatars::artwork::master(painted.png)).await {
                Ok(Ok(jpeg)) => Outcome::Painted { jpeg, cents },
                _ => Outcome::Fault(openai::Fault::Lost { charged: true }),
            }
        }
        Err(fault) => Outcome::Fault(fault),
    }
}

/// Paints the account's due senders, at most `IN_FLIGHT` at a time.
async fn run(
    accounts: Vec<String>,
    account: String,
    gmail: Arc<crate::providers::gmail::Session>,
    local_mail: Arc<crate::local_mail::LocalMail>,
) -> Result<(), &'static str> {
    let known: HashSet<String> = accounts.iter().map(|account| id(&["picture-account", account])).collect();
    let stopped = blocking(move || {
        change(|dir, state| {
            forget(dir, state, &known)?;
            Ok(blocking_problem(state, now()).is_some())
        })
    })
    .await?;
    if stopped {
        return Ok(());
    }
    let headers = local_mail.inbox_senders(&account, MAX_SENDERS).await?;
    let senders = senders(&headers);
    if senders.is_empty() {
        return Ok(());
    }
    let photos = avatars::contacts(&gmail, &account, "").await.unwrap_or(json!({}));
    let assignments: Vec<(String, Subject)> = senders
        .iter()
        .map(|(address, letter)| {
            (id(&["picture-sender", &account, address]), subject_for(address, *letter, &photos))
        })
        .collect();
    let owner = id(&["picture-account", &account]);
    let due = blocking(move || change(|_, state| assign(state, &owner, &assignments, now()))).await?;
    if due.is_empty() {
        return Ok(());
    }
    let key = match credentials::get(slot()).await {
        Ok(key) => Arc::new(key),
        Err(credentials::Error::Missing) => return Ok(()),
        Err(_) => return Err("pictures_key_storage"),
    };
    paint_all(due, key).await
}

async fn paint_all(due: Vec<Subject>, key: Arc<Secret>) -> Result<(), &'static str> {
    let mut queue = due.into_iter();
    let mut tasks = tokio::task::JoinSet::new();
    let mut stopped = false;
    loop {
        while !stopped && tasks.len() < IN_FLIGHT {
            let Some(subject) = queue.next() else {
                break;
            };
            if !blocking(|| change(|_, state| Ok(reserve(state, now())))).await? {
                stopped = true;
                break;
            }
            let key = key.clone();
            tasks.spawn(openai::inherit(async move {
                let outcome = paint(&subject, &key).await;
                (subject.id(), outcome)
            }));
        }
        let Some(finished) = tasks.join_next().await else {
            return Ok(());
        };
        let Ok((subject, outcome)) = finished else {
            continue;
        };
        if blocking(move || change(|dir, state| record(dir, state, &subject, outcome, now()))).await? {
            stopped = true;
        }
    }
}

/// Starts painting for the account whose turn it is, unless a run is under way. Never waits.
pub(crate) struct Painter {
    busy: Arc<tokio::sync::Semaphore>,
    turns: Mutex<HashMap<String, i64>>,
}

impl Default for Painter {
    fn default() -> Self {
        Self {
            busy: Arc::new(tokio::sync::Semaphore::new(1)),
            turns: Mutex::new(HashMap::new()),
        }
    }
}

impl Painter {

    pub(crate) fn start(
        &self,
        accounts: Vec<String>,
        gmail: Arc<crate::providers::gmail::Session>,
        local_mail: Arc<crate::local_mail::LocalMail>,
    ) {
        let Ok(permit) = self.busy.clone().try_acquire_owned() else {
            return;
        };
        let at = now();
        let account = {
            let Ok(mut turns) = self.turns.lock() else {
                return;
            };
            turns.retain(|account, _| accounts.contains(account));
            let next = accounts
                .iter()
                .filter(|account| turns.get(*account).is_none_or(|last| at - last >= RUN_EVERY))
                .min_by_key(|account| turns.get(*account).copied().unwrap_or(0))
                .cloned();
            if let Some(account) = &next {
                turns.insert(account.clone(), at);
            }
            next
        };
        let Some(account) = account else {
            return;
        };
        tokio::spawn(async move {
            let _permit = permit;
            let _ = run(accounts, account, gmail, local_mail).await;
        });
    }
}

/// The painted picture for this account's sender as a JPEG data URL, and when it was painted.
pub(crate) fn painted(account: &str, address: &str) -> Result<Option<(String, i64)>, &'static str> {
    use base64::{Engine, engine::general_purpose::STANDARD};
    static CACHE: Mutex<Option<(u64, std::time::SystemTime, Value)>> = Mutex::new(None);
    let Some(dir) = directory(false)? else {
        return Ok(None);
    };
    let Some(file) = fs::regular_readonly(&dir, STATE)? else {
        return Ok(None);
    };
    let metadata = file.metadata().map_err(|_| "pictures_storage_unavailable")?;
    let version = (metadata.len(), metadata.modified().map_err(|_| "pictures_storage_unavailable")?);
    let found = {
        let mut cache = CACHE.lock().map_err(|_| "pictures_storage_unavailable")?;
        if cache.as_ref().is_none_or(|(len, modified, _)| (*len, *modified) != version) {
            *cache = Some((version.0, version.1, read_state(&dir)?));
        }
        let state = &cache.as_ref().ok_or("pictures_storage_unavailable")?.2;
        let sender = id(&["picture-sender", account, address]);
        let subject = state["senders"][&sender]["subject"].as_str().unwrap_or("").to_owned();
        let row = &state["subjects"][&subject];
        (row["state"] == "painted")
            .then(|| row["painted"].as_i64())
            .flatten()
            .map(|painted| (subject, painted))
    };
    let Some((subject, painted)) = found else {
        return Ok(None);
    };
    if subject.len() != 64 || !subject.bytes().all(|b| b.is_ascii_hexdigit()) {
        return Ok(None);
    }
    let Some(file) = fs::regular_readonly(&dir, &format!("{subject}.jpg"))? else {
        return Ok(None);
    };
    let mut bytes = Vec::new();
    file.take(MASTER_LIMIT + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| "pictures_storage_unavailable")?;
    if bytes.len() as u64 > MASTER_LIMIT {
        return Ok(None);
    }
    Ok(Some((format!("data:image/jpeg;base64,{}", STANDARD.encode(bytes)), painted)))
}

/// What Settings shows: whether a key is saved, what stops painting, and the counts.
pub(crate) async fn status() -> Result<Value, &'static str> {
    let present = match credentials::get(slot()).await {
        Ok(_) => true,
        Err(credentials::Error::Missing) => false,
        Err(_) => return Err("pictures_key_storage"),
    };
    let state = blocking(|| match directory(false)? {
        Some(dir) => read_state(&dir),
        None => Ok(json!({})),
    })
    .await?;
    let at = now();
    let mut counts: HashMap<&str, i64> = HashMap::new();
    for row in state["subjects"].as_object().into_iter().flatten().map(|(_, row)| row) {
        *counts.entry(row["state"].as_str().unwrap_or("")).or_default() += 1;
    }
    Ok(json!({
        "present": present,
        "model": MODEL,
        "problem": blocking_problem(&state, at),
        "painted": counts.get("painted").copied().unwrap_or(0),
        "waiting": counts.get("waiting").copied().unwrap_or(0),
        "failed": counts.get("failed").copied().unwrap_or(0),
        "spentTodayCents": spent_today(&state, at),
        "dailyLimitCents": DAILY_LIMIT_CENTS,
    }))
}

fn clear_problem() -> impl FnOnce() -> Result<(), &'static str> + Send + 'static {
    || {
        change(|_, state| {
            if let Some(fields) = state.as_object_mut() {
                fields.remove("problem");
                fields.remove("retryAt");
            }
            Ok(())
        })
    }
}

/// Checks the key with OpenAI before it is saved, so a mistyped or revoked key is refused at once.
pub(crate) async fn set_key(text: &str) -> Result<Value, &'static str> {
    let text = text.trim();
    if !openai::valid_key(text) {
        return Err("pictures_key_format");
    }
    let secret = Secret::new(text.as_bytes().to_vec()).map_err(|_| "pictures_key_format")?;
    if let Err(fault) = openai::check(&secret, MODEL).await {
        return Err(match fault {
            openai::Fault::Key(problem) => problem,
            openai::Fault::Billing => "pictures_billing",
            openai::Fault::Model => "pictures_model_unavailable",
            openai::Fault::RateLimited(_) => "pictures_rate_limited",
            _ => "pictures_unreachable",
        });
    }
    credentials::put(slot(), secret)
        .await
        .map_err(|_| "pictures_key_storage")?;
    blocking(clear_problem()).await?;
    status().await
}

pub(crate) async fn remove_key() -> Result<Value, &'static str> {
    match credentials::delete(slot()).await {
        Ok(()) | Err(credentials::Error::Missing) => {}
        Err(_) => return Err("pictures_key_storage"),
    }
    blocking(clear_problem()).await?;
    status().await
}

#[cfg(test)]
#[path = "pictures_tests.rs"]
mod tests;
