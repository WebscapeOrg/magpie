//! Sender pictures painted in Marmalade's ligne-claire style (C-039).
//!
//! The main machine's engine paints one picture for each sender in an account's Inbox with OpenAI's image
//! model and Marmalade's avatar prompts. A sender with a contact photo is redrawn from that photo, a
//! sender at a company from the company's logo (one picture per registrable domain), and anyone
//! else as a monogram of one letter, so no face is invented. `inbox.avatar` then serves the painted
//! picture cut to the circle.
//!
//! Invariants:
//! - Only a contact photo or a company logo, and the prompt text in `prompts`, leave Magpie. Names,
//!   addresses, subjects and message text are never sent.
//! - Each picture is paid for once. A contact whose photo address changes is painted again only
//!   when the photo's pixels changed. A refused picture is not asked for again, a lost one at most
//!   three times, and a day's spending stops at `DAILY_LIMIT_CENTS`, counted before each request.
//! - A paid picture outlives a passing gap in the contacts answer: senders keep their portraits
//!   while contacts are unknown, and a picture no sender uses is kept for `ORPHAN_KEEP` before it is
//!   deleted. Pictures of the senders of an account removed from Magpie are deleted at the next run;
//!   signing out keeps them, so signing in again does not pay for them again.
//! - The key lives in the platform keyring and is never returned, logged or written elsewhere.
//!   Saving or removing it changes `keyGeneration` in the state before and after the keyring
//!   changes, which stops any run that still holds the old key, in whichever process it runs, from
//!   sending further requests.
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
/// How long a picture no sender uses is kept, in case its sender returns to it.
const ORPHAN_KEEP: i64 = 30 * 86_400_000;
/// How long a sender who is no longer in the Inbox is remembered.
const SENDER_KEEP: i64 = 90 * 86_400_000;
const STATE: &str = "state.json";
const STATE_LIMIT: u64 = 16 * 1024 * 1024;
const MASTER_LIMIT: u64 = 2 * 1024 * 1024;

/// Changes whenever a picture is painted, so the window asks for its senders' pictures again.
/// Starts at the process's start time, so a restarted engine does not repeat an earlier number.
static REVISION: AtomicU64 = AtomicU64::new(0);

fn seed_revision() {
    let _ = REVISION.compare_exchange(0, now().max(1) as u64, Ordering::Relaxed, Ordering::Relaxed);
}

pub(crate) fn revision() -> u64 {
    seed_revision();
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

fn is_name(subject: &str) -> bool {
    subject.len() == 64 && subject.bytes().all(|b| b.is_ascii_hexdigit())
}

fn digest(bytes: &[u8]) -> String {
    use sha2::{Digest, Sha256};
    format!("{:x}", Sha256::digest(bytes))
}

#[derive(Clone, Debug, PartialEq, Eq)]
enum Subject {
    /// A contact with a photo: one picture per account and address. `photo` is where the photo is
    /// fetched from; a new address is checked again, and repainted only if the pixels changed.
    Person { account: String, address: String, photo: String },
    Organization { domain: String },
    Monogram { letter: char },
}

impl Subject {
    fn id(&self) -> String {
        match self {
            Self::Person { account, address, .. } => id(&["picture-person", account, address]),
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

/// A picture to paint now, with the fingerprint of the photo it was last painted from when it is
/// being checked again.
type Due = (Subject, Option<String>);

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

/// The domain a company registers, so `news.acme.co.uk` and `em12.acme.co.uk` share `acme.co.uk`'s
/// picture. Only the ICANN section of the public suffix list counts: names under a hosting suffix
/// such as `github.io` are free to make, so they share their host's picture. Without a known
/// suffix, the last two labels. Invariant: the result is a suffix of a domain `avatars::email`
/// accepted.
fn registrable(domain: &str) -> &str {
    let starts: Vec<usize> = std::iter::once(0)
        .chain(domain.match_indices('.').map(|(index, _)| index + 1))
        .collect();
    for (position, start) in starts.iter().enumerate() {
        let candidate = &domain[*start..];
        let icann = psl::suffix(candidate.as_bytes())
            .is_some_and(|suffix| suffix.typ() == Some(psl::Type::Icann) && suffix.as_bytes() == candidate.as_bytes());
        if icann {
            return position.checked_sub(1).map_or(domain, |label| &domain[starts[label]..]);
        }
    }
    starts.len().checked_sub(2).map_or(domain, |label| &domain[starts[label]..])
}

fn subject_for(account: &str, address: &str, letter: char, photos: &Value) -> Subject {
    let domain = address.split_once('@').map(|(_, domain)| domain).unwrap_or("");
    if let Some(photo) = photos[address]
        .as_str()
        .filter(|url| url.starts_with("https://") && url.len() <= 2048)
    {
        return Subject::Person {
            account: account.to_owned(),
            address: address.to_owned(),
            photo: photo.to_owned(),
        };
    }
    let company = registrable(domain);
    if !domain.is_empty() && !avatars::consumer(domain) && !avatars::consumer(company) {
        return Subject::Organization {
            domain: company.to_owned(),
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

fn state_size(dir: &File) -> Result<u64, &'static str> {
    match fs::regular_readonly(dir, STATE)? {
        Some(file) => file.metadata().map(|m| m.len()).map_err(|_| "pictures_storage_unavailable"),
        None => Ok(0),
    }
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

/// Which saved key the state belongs to; saving or removing the key changes it.
fn generation(state: &Value) -> u64 {
    state["keyGeneration"].as_u64().unwrap_or(0)
}

/// The problem that stops all painting now, if any. Key problems last until the key changes.
fn blocking_problem(state: &Value, at: i64) -> Option<&str> {
    let problem = state["problem"].as_str()?;
    match state["retryAt"].as_i64() {
        Some(retry) if retry <= at => None,
        _ => Some(problem),
    }
}

/// Forgets the senders of accounts no longer in Magpie's account list and senders not seen in an
/// Inbox for `SENDER_KEEP`. A picture whose senders belonged to a removed account is deleted with
/// its file at once; any other picture no sender uses is deleted once it has been unused for
/// `ORPHAN_KEEP`.
fn forget(dir: &File, state: &mut Value, accounts: &HashSet<String>, at: i64) -> Result<(), &'static str> {
    let mut senders = object(state, "senders")?;
    let mut signed_out = HashSet::new();
    let oldest = today(at - SENDER_KEEP);
    senders.retain(|_, row| {
        if !row["account"].as_str().is_some_and(|account| accounts.contains(account)) {
            if let Some(subject) = row["subject"].as_str() {
                signed_out.insert(subject.to_owned());
            }
            return false;
        }
        row["seen"].as_str().is_none_or(|seen| seen >= oldest.as_str())
    });
    let referenced: HashSet<String> = senders
        .values()
        .filter_map(|row| row["subject"].as_str().map(str::to_owned))
        .collect();
    let mut subjects = object(state, "subjects")?;
    let mut gone = Vec::new();
    for (subject, row) in subjects.iter_mut() {
        if referenced.contains(subject) {
            if let Some(row) = row.as_object_mut() {
                row.remove("orphaned");
            }
        } else if signed_out.contains(subject) {
            gone.push(subject.clone());
        } else {
            match row["orphaned"].as_i64() {
                Some(since) if at - since >= ORPHAN_KEEP => gone.push(subject.clone()),
                Some(_) => {}
                None => row["orphaned"] = json!(at),
            }
        }
    }
    for subject in gone {
        subjects.remove(&subject);
        if is_name(&subject) {
            fs::remove_owned(dir, &format!("{subject}.jpg"))?;
        }
    }
    state["senders"] = Value::Object(senders);
    state["subjects"] = Value::Object(subjects);
    Ok(())
}

fn new_row(subject: &Subject) -> Value {
    let mut row = json!({"state":"waiting","attempts":0,"kind":subject.kind()});
    if let Subject::Person { photo, .. } = subject {
        row["photo"] = json!(photo);
    }
    row
}

fn clear_retry(row: &mut Value) {
    if let Some(row) = row.as_object_mut() {
        row.remove("retryAt");
        row.remove("reason");
    }
}

/// Takes a contact's new photo address: a painted portrait is checked again, a refused one tried
/// again.
fn adopt(row: &mut Value, photo: &str) {
    if row["photo"] == photo {
        return;
    }
    row["photo"] = json!(photo);
    let next = match row["state"].as_str() {
        Some("painted") => "recheck",
        Some("failed") => "waiting",
        _ => return,
    };
    row["state"] = json!(next);
    row["attempts"] = json!(0);
    clear_retry(row);
}

/// Records which picture each Inbox sender gets and returns the pictures due for painting, each
/// once, portraits first. While `contacts_known` is false a sender keeps a portrait it already has,
/// because a missing photo then means only that the contacts could not be read.
fn assign(
    state: &mut Value,
    account: &str,
    assignments: &[(String, Subject)],
    contacts_known: bool,
    at: i64,
) -> Result<Vec<Due>, &'static str> {
    let day = today(at);
    let mut senders = object(state, "senders")?;
    let mut subjects = object(state, "subjects")?;
    let mut due = Vec::new();
    let mut listed = HashSet::new();
    for (sender, subject) in assignments {
        let subject_id = subject.id();
        let current = senders.get(sender).and_then(|row| row["subject"].as_str()).map(str::to_owned);
        let kept = current.filter(|current| {
            !contacts_known && *current != subject_id && subjects.get(current).is_some_and(|row| row["kind"] == "person")
        });
        if let Some(kept) = kept {
            senders.insert(sender.clone(), json!({"subject":kept,"account":account,"seen":day}));
            continue;
        }
        senders.insert(sender.clone(), json!({"subject":subject_id,"account":account,"seen":day}));
        let row = subjects.entry(subject_id.clone()).or_insert_with(|| new_row(subject));
        if let Subject::Person { photo, .. } = subject {
            adopt(row, photo);
        }
        let state = row["state"].as_str().unwrap_or("");
        let ready = row["retryAt"].as_i64().is_none_or(|retry| retry <= at);
        if matches!(state, "waiting" | "recheck") && ready && listed.insert(subject_id) {
            let previous = (state == "recheck").then(|| row["reference"].as_str().map(str::to_owned)).flatten();
            due.push((subject.clone(), previous));
        }
    }
    due.sort_by_key(|(subject, _)| !matches!(subject, Subject::Person { .. }));
    state["senders"] = Value::Object(senders);
    state["subjects"] = Value::Object(subjects);
    Ok(due)
}

/// Sets aside the estimate for one picture, unless painting is stopped, the key has changed since
/// the run read it, or the day's limit would be passed.
fn reserve(state: &mut Value, at: i64, key_generation: u64) -> bool {
    if generation(state) != key_generation || blocking_problem(state, at).is_some() {
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
    /// `reference` is the fingerprint of the contact photo it was painted from.
    Painted { jpeg: Vec<u8>, cents: i64, reference: Option<String> },
    /// The contact's photo has the same pixels as the one already painted; nothing was sent.
    Unchanged,
    /// The contact photo could not be fetched; nothing was sent.
    NoReference,
    Fault(openai::Fault),
}

/// Ends a picture's attempts: a portrait being checked again keeps its current picture.
fn give_up(row: &mut Value) {
    let next = if row["state"] == "recheck" { "painted" } else { "failed" };
    row["state"] = json!(next);
    if let Some(row) = row.as_object_mut() {
        row.remove("retryAt");
    }
}

fn failed_once(row: &mut Value, reason: &str, at: i64) {
    let attempts = row["attempts"].as_i64().unwrap_or(0) + 1;
    row["attempts"] = json!(attempts);
    row["reason"] = json!(reason);
    if attempts >= ATTEMPTS {
        give_up(row);
    } else {
        row["retryAt"] = json!(at + RETRY_WAITS[(attempts - 1) as usize]);
    }
}

fn stop(state: &mut Value, problem: &str, wait: Option<i64>, at: i64) {
    state["problem"] = json!(problem);
    state["retryAt"] = wait.map_or(Value::Null, |wait| json!(at + wait));
}

/// Writes a finished picture or the failure, and says whether painting must stop for now. A key
/// refusal counts only while `key_generation` is still the saved key's.
fn record(
    dir: &File,
    state: &mut Value,
    subject: &str,
    outcome: Outcome,
    at: i64,
    key_generation: u64,
) -> Result<bool, &'static str> {
    let refund = -openai::ESTIMATE_CENTS;
    let same_key = generation(state) == key_generation;
    let mut subjects = object(state, "subjects")?;
    let Some(row) = subjects.get_mut(subject) else {
        state["subjects"] = Value::Object(subjects);
        return Ok(false);
    };
    let halt = match outcome {
        Outcome::Painted { jpeg, cents, reference } => {
            if let Err(error) = fs::atomic_replace(dir, &format!("{subject}.jpg"), &jpeg) {
                state["subjects"] = Value::Object(subjects);
                return Err(error);
            }
            let mut painted = json!({"state":"painted","painted":at,"attempts":0,"kind":row["kind"]});
            if let Some(photo) = row.get("photo") {
                painted["photo"] = photo.clone();
            }
            if let Some(reference) = reference {
                painted["reference"] = json!(reference);
            }
            *row = painted;
            adjust(state, at, cents - openai::ESTIMATE_CENTS);
            seed_revision();
            REVISION.fetch_add(1, Ordering::Relaxed);
            false
        }
        Outcome::Unchanged => {
            adjust(state, at, refund);
            row["state"] = json!("painted");
            row["attempts"] = json!(0);
            clear_retry(row);
            false
        }
        Outcome::NoReference => {
            adjust(state, at, refund);
            failed_once(row, "pictures_reference_unavailable", at);
            false
        }
        Outcome::Fault(openai::Fault::Refused) => {
            adjust(state, at, refund);
            row["reason"] = json!("pictures_refused");
            give_up(row);
            false
        }
        // A fault answered to a key that has since been replaced or removed says nothing about the
        // saved key, so it does not pause painting.
        Outcome::Fault(openai::Fault::Lost { charged }) => {
            if !charged {
                adjust(state, at, refund);
            }
            failed_once(row, "pictures_unreachable", at);
            if same_key {
                stop(state, "pictures_unreachable", Some(LOST_WAIT), at);
            }
            true
        }
        Outcome::Fault(fault) => {
            adjust(state, at, refund);
            if same_key {
                match fault {
                    openai::Fault::Key(problem) => stop(state, problem, None, at),
                    openai::Fault::Billing => stop(state, "pictures_billing", Some(BILLING_WAIT), at),
                    openai::Fault::RateLimited(wait) => {
                        stop(state, "pictures_rate_limited", Some(wait.unwrap_or(0).max(RATE_WAIT)), at)
                    }
                    _ => stop(state, "pictures_model_unavailable", Some(MODEL_WAIT), at),
                }
            }
            true
        }
    };
    state["subjects"] = Value::Object(subjects);
    Ok(halt)
}

/// Contact photos and company logos that tests supply, by address; tests never fetch from the
/// network.
#[cfg(test)]
static TEST_REFERENCES: Mutex<Vec<(String, String)>> = Mutex::new(Vec::new());

#[cfg(test)]
fn test_reference(address: &str) -> Option<String> {
    let references = TEST_REFERENCES.lock().ok()?;
    references.iter().find(|(known, _)| known == address).map(|(_, data)| data.clone())
}

async fn photo(url: &str) -> Option<String> {
    #[cfg(test)]
    let found = test_reference(url);
    #[cfg(not(test))]
    let found = crate::public_http::image(url).await.ok();
    found
}

async fn logo(domain: &str) -> Option<String> {
    #[cfg(test)]
    let found = test_reference(&format!("logo:{domain}"));
    #[cfg(not(test))]
    let found = avatars::organization_image(domain).await;
    found
}

async fn reference(data: Option<String>) -> Option<Vec<u8>> {
    let data = data?;
    tokio::task::spawn_blocking(move || avatars::artwork::reference(&data).ok())
        .await
        .ok()
        .flatten()
}

async fn paint(subject: &Subject, previous: Option<&str>, key: &Secret) -> Outcome {
    let (request, fingerprint) = match subject {
        Subject::Person { photo: address, .. } => {
            let Some(png) = reference(photo(address).await).await else {
                return Outcome::NoReference;
            };
            let fingerprint = digest(&png);
            if previous == Some(fingerprint.as_str()) {
                return Outcome::Unchanged;
            }
            (openai::Request::Edit { prompt: prompts::portrait(), reference: png }, Some(fingerprint))
        }
        Subject::Organization { domain } => match reference(logo(domain).await).await {
            Some(png) => (openai::Request::Edit { prompt: prompts::logo(domain), reference: png }, None),
            None => (openai::Request::Generate { prompt: prompts::text_logo(domain) }, None),
        },
        Subject::Monogram { letter } => (openai::Request::Generate { prompt: prompts::monogram(*letter) }, None),
    };
    match openai::paint(key, MODEL, &request).await {
        Ok(painted) => {
            let cents = painted.cents;
            match tokio::task::spawn_blocking(move || avatars::artwork::master(painted.png)).await {
                Ok(Ok(jpeg)) => Outcome::Painted { jpeg, cents, reference: fingerprint },
                _ => Outcome::Fault(openai::Fault::Lost { charged: true }),
            }
        }
        Err(fault) => Outcome::Fault(fault),
    }
}

/// The key this process last read from the keyring, with the key generation it was read under.
static KEY: Mutex<Option<(u64, Option<Arc<Secret>>)>> = Mutex::new(None);

fn forget_cached_key() {
    if let Ok(mut cache) = KEY.lock() {
        *cache = None;
    }
}

/// The saved key for this key generation. The keyring is read again only after the key changes.
async fn saved_key(key_generation: u64) -> Result<Option<Arc<Secret>>, &'static str> {
    // Tests each use their own keyring, so they always read it.
    if !cfg!(test)
        && let Ok(cache) = KEY.lock()
        && let Some((_, key)) = cache.as_ref().filter(|(cached, _)| *cached == key_generation)
    {
        return Ok(key.clone());
    }
    let key = match credentials::get(slot()).await {
        Ok(key) => Some(Arc::new(key)),
        Err(credentials::Error::Missing) => None,
        Err(_) => return Err("pictures_key_storage"),
    };
    if let Ok(mut cache) = KEY.lock() {
        *cache = Some((key_generation, key.clone()));
    }
    Ok(key)
}

/// Forgets what belongs to removed accounts when no account is left.
async fn forget_only() -> Result<(), &'static str> {
    blocking(|| {
        if directory(false)?.is_none() {
            return Ok(());
        }
        change(|dir, state| forget(dir, state, &HashSet::new(), now()))
    })
    .await
}

/// Paints the account's due senders, at most `IN_FLIGHT` at a time.
async fn run(
    accounts: Vec<String>,
    account: String,
    gmail: Arc<crate::providers::gmail::Session>,
    local_mail: Arc<crate::local_mail::LocalMail>,
) -> Result<(), &'static str> {
    let known: HashSet<String> = accounts.iter().map(|account| id(&["picture-account", account])).collect();
    let (stopped, key_generation) = blocking(move || {
        change(|dir, state| {
            forget(dir, state, &known, now())?;
            Ok((blocking_problem(state, now()).is_some(), generation(state)))
        })
    })
    .await?;
    if stopped {
        return Ok(());
    }
    let Some(key) = saved_key(key_generation).await? else {
        return Ok(());
    };
    let headers = local_mail.inbox_senders(&account, MAX_SENDERS).await?;
    let senders = senders(&headers);
    if senders.is_empty() {
        return Ok(());
    }
    let (photos, contacts_known) = avatars::contact_photos(&gmail, &account)
        .await
        .unwrap_or_else(|_| (json!({}), false));
    let assignments: Vec<(String, Subject)> = senders
        .iter()
        .map(|(address, letter)| {
            let subject = subject_for(&account, address, *letter, &photos);
            (id(&["picture-sender", &account, address]), subject)
        })
        .collect();
    let owner = id(&["picture-account", &account]);
    let due =
        blocking(move || change(|_, state| assign(state, &owner, &assignments, contacts_known, now()))).await?;
    if due.is_empty() {
        return Ok(());
    }
    paint_all(due, key, key_generation).await
}

async fn paint_all(due: Vec<Due>, key: Arc<Secret>, key_generation: u64) -> Result<(), &'static str> {
    let mut queue = due.into_iter();
    let mut tasks = tokio::task::JoinSet::new();
    let mut running = HashMap::new();
    let mut stopped = false;
    // A storage failure stops new requests, but the requests already sent are still recorded.
    let mut failure = None;
    loop {
        while !stopped && tasks.len() < IN_FLIGHT {
            let Some((subject, previous)) = queue.next() else {
                break;
            };
            match blocking(move || change(|_, state| Ok(reserve(state, now(), key_generation)))).await {
                Ok(true) => {}
                Ok(false) => {
                    stopped = true;
                    break;
                }
                Err(error) => {
                    failure.get_or_insert(error);
                    stopped = true;
                    break;
                }
            }
            let key = key.clone();
            let name = subject.id();
            let task = tasks.spawn(openai::inherit(async move {
                let outcome = paint(&subject, previous.as_deref(), &key).await;
                (subject.id(), outcome)
            }));
            running.insert(task.id(), name);
        }
        let Some(finished) = tasks.join_next_with_id().await else {
            return failure.map_or(Ok(()), Err);
        };
        // A task that panicked may have been charged: count it as a lost, charged attempt.
        let (subject, outcome) = match finished {
            Ok((task, (subject, outcome))) => {
                running.remove(&task);
                (subject, outcome)
            }
            Err(error) => match running.remove(&error.id()) {
                Some(subject) => (subject, Outcome::Fault(openai::Fault::Lost { charged: true })),
                None => continue,
            },
        };
        match blocking(move || change(|dir, state| record(dir, state, &subject, outcome, now(), key_generation))).await {
            Ok(false) => {}
            Ok(true) => stopped = true,
            Err(error) => {
                failure.get_or_insert(error);
                stopped = true;
            }
        }
    }
}

/// Starts painting for the account whose turn it is, unless a run is under way. Never waits. With
/// no account left it only forgets what the removed accounts left behind.
pub(crate) struct Painter {
    busy: Arc<tokio::sync::Semaphore>,
    turns: Mutex<HashMap<String, i64>>,
    /// The account list the prepared painted avatars were last checked against.
    listed: Mutex<Option<Vec<String>>>,
}

impl Default for Painter {
    fn default() -> Self {
        Self {
            busy: Arc::new(tokio::sync::Semaphore::new(1)),
            turns: Mutex::new(HashMap::new()),
            listed: Mutex::new(None),
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
        // The empty name stands for the forget-only turn when no account is signed in.
        let candidates = if accounts.is_empty() { vec![String::new()] } else { accounts.clone() };
        let account = {
            let Ok(mut turns) = self.turns.lock() else {
                return;
            };
            turns.retain(|account, _| candidates.contains(account));
            let next = candidates
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
        // When the account list changes, and once after the engine starts, drop the prepared painted
        // avatars of accounts no longer listed.
        let mut sorted = accounts.clone();
        sorted.sort();
        let changed = self.listed.lock().is_ok_and(|mut listed| {
            let changed = listed.as_ref() != Some(&sorted);
            if changed {
                *listed = Some(sorted.clone());
            }
            changed
        });
        tokio::spawn(async move {
            let _permit = permit;
            if changed {
                let _ = blocking(move || avatars::forget_painted(&sorted)).await;
            }
            let _ = if account.is_empty() {
                forget_only().await
            } else {
                run(accounts, account, gmail, local_mail).await
            };
        });
    }
}

/// The painted picture for this account's sender: its file name and when it was painted. A
/// portrait being checked again keeps showing its current picture. Blocks: call it off the async
/// threads.
pub(crate) fn painted(account: &str, address: &str) -> Result<Option<(String, i64)>, &'static str> {
    static CACHE: Mutex<Option<(u64, std::time::SystemTime, Value)>> = Mutex::new(None);
    let Some(dir) = directory(false)? else {
        return Ok(None);
    };
    let Some(file) = fs::regular_readonly(&dir, STATE)? else {
        return Ok(None);
    };
    let metadata = file.metadata().map_err(|_| "pictures_storage_unavailable")?;
    let version = (metadata.len(), metadata.modified().map_err(|_| "pictures_storage_unavailable")?);
    let mut cache = CACHE.lock().map_err(|_| "pictures_storage_unavailable")?;
    if cache.as_ref().is_none_or(|(len, modified, _)| (*len, *modified) != version) {
        *cache = Some((version.0, version.1, read_state(&dir)?));
    }
    let state = &cache.as_ref().ok_or("pictures_storage_unavailable")?.2;
    let sender = id(&["picture-sender", account, address]);
    let subject = state["senders"][&sender]["subject"].as_str().unwrap_or("").to_owned();
    let row = &state["subjects"][&subject];
    let shown = matches!(row["state"].as_str(), Some("painted" | "recheck"));
    Ok(shown
        .then(|| row["painted"].as_i64())
        .flatten()
        .filter(|_| is_name(&subject))
        .map(|painted| (subject, painted)))
}

/// A painted picture as a JPEG data URL. Blocks: call it off the async threads.
pub(crate) fn picture(subject: &str) -> Result<Option<String>, &'static str> {
    use base64::{Engine, engine::general_purpose::STANDARD};
    if !is_name(subject) {
        return Ok(None);
    }
    let Some(dir) = directory(false)? else {
        return Ok(None);
    };
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
    Ok(Some(format!("data:image/jpeg;base64,{}", STANDARD.encode(bytes))))
}

/// What Settings shows: whether a key is saved, what stops painting, and the counts. Spending is
/// estimated from OpenAI's reported usage at list prices; it is not OpenAI's bill.
pub(crate) async fn status() -> Result<Value, &'static str> {
    let (state, size) = blocking(|| match directory(false)? {
        Some(dir) => Ok((read_state(&dir)?, state_size(&dir)?)),
        None => Ok((json!({}), 0)),
    })
    .await?;
    let present = saved_key(generation(&state)).await?.is_some();
    let at = now();
    let mut counts: HashMap<&str, i64> = HashMap::new();
    for row in state["subjects"].as_object().into_iter().flatten().map(|(_, row)| row) {
        let shown = match row["state"].as_str().unwrap_or("") {
            "recheck" => "painted",
            other => other,
        };
        *counts.entry(shown).or_default() += 1;
    }
    let full = (size > STATE_LIMIT / 10 * 9).then_some("pictures_storage_full");
    Ok(json!({
        "present": present,
        "model": MODEL,
        "problem": blocking_problem(&state, at).or(full),
        "painted": counts.get("painted").copied().unwrap_or(0),
        "waiting": counts.get("waiting").copied().unwrap_or(0),
        "failed": counts.get("failed").copied().unwrap_or(0),
        "spentTodayCents": spent_today(&state, at),
        "dailyLimitCents": DAILY_LIMIT_CENTS,
    }))
}

/// Clears the problem and moves to a new key generation, which stops runs holding the old key from
/// sending further requests.
fn key_changed() -> impl FnOnce() -> Result<u64, &'static str> + Send + 'static {
    || {
        change(|_, state| {
            let next = generation(state) + 1;
            if let Some(fields) = state.as_object_mut() {
                fields.remove("problem");
                fields.remove("retryAt");
            }
            state["keyGeneration"] = json!(next);
            Ok(next)
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
    around_key_change(credentials::put(slot(), secret)).await?;
    status().await
}

/// Changes the key generation before the keyring changes, so runs holding the old key stop, and
/// again after it, so a run that read the keyring during the change does not keep what it read.
async fn around_key_change(
    update: impl std::future::Future<Output = Result<(), credentials::Error>>,
) -> Result<(), &'static str> {
    forget_cached_key();
    blocking(key_changed()).await?;
    match update.await {
        Ok(()) | Err(credentials::Error::Missing) => {}
        Err(_) => return Err("pictures_key_storage"),
    }
    forget_cached_key();
    let mut last = Ok(0);
    for _ in 0..3 {
        last = blocking(key_changed()).await;
        if last.is_ok() {
            break;
        }
    }
    last.map(|_| ())
}

pub(crate) async fn remove_key() -> Result<Value, &'static str> {
    around_key_change(credentials::delete(slot())).await?;
    status().await
}

#[cfg(test)]
#[path = "pictures_tests.rs"]
mod tests;
