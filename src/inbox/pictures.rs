//! Sender pictures painted in Marmalade's ligne-claire style (C-039).
//!
//! The main machine's engine, and the engine inside Magpie on the iPhone and iPad (C-040), paints one
//! picture for each sender in an account's Inbox with OpenAI's image model and Marmalade's avatar
//! prompts. The phone paints only while Magpie is in the foreground, when the app asks it to. A sender with a contact photo is redrawn from that photo, a
//! sender at a company from the company's logo (one picture per registrable domain), and anyone
//! else as a monogram of one letter, so no face is invented. `inbox.avatar` then serves the painted
//! picture cut to the circle.
//!
//! Invariants:
//! - Only a contact photo or a company logo, and the prompt text in `prompts`, leave Magpie. Names,
//!   addresses, subjects and message text are never sent. On the phone the painted pictures also go
//!   to Dave's private iCloud database for his other devices, each with its picture id, kind, paint
//!   time and, for a portrait, the photo's fingerprint.
//! - Each picture is paid for once on each device, and usually once across Dave's devices: a
//!   picture taken in from iCloud is not painted again, but two devices can both paint a new sender
//!   before either has shared it. A contact whose photo address changes is painted again only
//!   when the photo's pixels changed. A refused picture is not asked for again, a lost one at most
//!   three times, and a day's spending stops at `DAILY_LIMIT_CENTS`, counted before each request.
//! - A paid picture outlives a passing gap in the contacts answer: senders keep their portraits
//!   while contacts are unknown, and a picture no sender uses is kept for `ORPHAN_KEEP` before it is
//!   deleted. Pictures of the senders of an account removed from Magpie are deleted at the next run;
//!   signing out keeps them, so signing in again does not pay for them again.
//! - The key lives in the platform keyring (the iPhone's device-only Keychain on the phone) and is
//!   never returned, logged or written elsewhere.
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

/// OpenAI's gpt-image-2.5 Sunburst, which Dave chose for Magpie on Linux and for Marmalade (Q-007).
/// The iPhone and iPad use gpt-image-2.5 Flare, which Dave chose for them to get a feel for that
/// model (C-040); both are billed at the same token prices.
pub(crate) const MODEL: &str = if super::PHONE_WRITER { "gpt-image-2.5-flare" } else { "gpt-image-2.5-sunburst" };
pub(crate) const DAILY_LIMIT_CENTS: i64 = 300;
/// Attempts for a picture that keeps failing for reasons that may pass, with the waits between them.
const ATTEMPTS: i64 = 3;
const RETRY_WAITS: [i64; 2] = [3_600_000, 6 * 3_600_000];
/// How often one account's Inbox is looked at for new senders.
const RUN_EVERY: i64 = 60_000;
const MAX_SENDERS: usize = 2_000;
/// Pictures asked for at once. The phone asks for one, so leaving Magpie cuts off at most one.
const IN_FLIGHT: usize = if super::PHONE_WRITER { 1 } else { 2 };
const RATE_WAIT: i64 = 60_000;
const LOST_WAIT: i64 = 5 * 60_000;
/// After every `CUT_OFFS` requests for the same picture that iOS cut off, that picture waits
/// `CUT_OFF_WAIT` and the next one goes first, so short visits to the app do not ask for the same
/// picture again and again.
const CUT_OFFS: i64 = 2;
const CUT_OFF_WAIT: i64 = 10 * 60_000;
const BILLING_WAIT: i64 = 3_600_000;
const MODEL_WAIT: i64 = 24 * 3_600_000;
/// How long painting leaves a keyring it could not read before reading it again. Reading a locked
/// keyring asks the desktop to unlock it, so painting must not ask on every turn.
const KEYRING_WAIT: i64 = 5 * 60_000;
/// Rejected request settings in a row, with no picture painted between them, after which Magpie
/// stops painting for `MODEL_WAIT` instead of giving up each picture.
const REFUSAL_RUN: usize = 3;
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
        row.remove("cutOffs");
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
    Painted { jpeg: Vec<u8>, cents: i64, micro_dollars: i64, reference: Option<String> },
    /// The contact's photo has the same pixels as the one already painted; nothing was sent.
    Unchanged,
    /// The contact photo could not be fetched; nothing was sent.
    NoReference,
    /// Magpie left the foreground before the request was sent, so nothing was sent.
    Stopped,
    /// Magpie left the foreground while the request was under way and the answer was lost. iOS may
    /// have cut it off, so it says nothing about OpenAI or the picture. `charged` as for `Lost`.
    CutOff { charged: bool },
    /// OpenAI answered with a picture Magpie could not use. It was paid for at the reported cost.
    Unusable { cents: i64, micro_dollars: i64 },
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

/// The pictures whose request settings were rejected since the last one painted, oldest first.
fn refusal_run(state: &Value) -> Vec<String> {
    let run = state["refusedRun"].as_array().into_iter().flatten();
    let mut run: Vec<String> = run.filter_map(|id| id.as_str().map(str::to_owned)).collect();
    let older = run.len().saturating_sub(REFUSAL_RUN - 1);
    run.drain(..older);
    run
}

/// Pauses painting. A pause already in force that lasts as long or longer, or until the key changes,
/// is kept, so a late answer from the other request in flight cannot shorten it.
fn stop(state: &mut Value, problem: &str, wait: Option<i64>, at: i64) {
    let until = wait.map(|wait| at + wait);
    if blocking_problem(state, at).is_some() {
        match (state["retryAt"].as_i64(), until) {
            (None, _) => return,
            (Some(current), Some(until)) if current >= until => return,
            _ => {}
        }
    }
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
    // Only cut-offs in a row hold a picture back; any other outcome but leaving before the request
    // starts the count again.
    if !matches!(outcome, Outcome::CutOff { .. } | Outcome::Stopped)
        && let Some(fields) = row.as_object_mut()
    {
        fields.remove("cutOffs");
    }
    let halt = match outcome {
        Outcome::Painted { jpeg, cents, reference, .. } => {
            if let Err(error) = fs::atomic_replace(dir, &format!("{subject}.jpg"), &jpeg) {
                state["subjects"] = Value::Object(subjects);
                return Err(error);
            }
            // The model is kept so a later change of model can tell which pictures it painted.
            let mut painted = json!({"state":"painted","painted":at,"attempts":0,"kind":row["kind"],"model":MODEL});
            if let Some(photo) = row.get("photo") {
                painted["photo"] = photo.clone();
            }
            if let Some(reference) = reference {
                painted["reference"] = json!(reference);
            }
            *row = painted;
            adjust(state, at, cents - openai::ESTIMATE_CENTS);
            if let Some(fields) = state.as_object_mut() {
                fields.remove("refusedRun");
            }
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
        // Nothing was sent; the picture waits for the next turn in the foreground.
        Outcome::Stopped => {
            adjust(state, at, refund);
            true
        }
        // A request iOS cut off counts no attempt and does not pause painting; one that may have
        // been charged keeps its reservation. A picture cut off repeatedly waits for a while.
        Outcome::CutOff { charged } => {
            if !charged {
                adjust(state, at, refund);
            }
            let cut_offs = row["cutOffs"].as_i64().unwrap_or(0) + 1;
            if cut_offs >= CUT_OFFS {
                row["retryAt"] = json!(at + CUT_OFF_WAIT);
                if let Some(row) = row.as_object_mut() {
                    row.remove("cutOffs");
                }
            } else {
                row["cutOffs"] = json!(cut_offs);
            }
            true
        }
        Outcome::Unusable { cents, .. } => {
            adjust(state, at, cents - openai::ESTIMATE_CENTS);
            failed_once(row, "pictures_unusable", at);
            false
        }
        // A rejected setting says nothing about the picture, so the picture is never given up for
        // it: it is asked for again after `MODEL_WAIT`. A run of them, or one while painting is
        // stopped for them, is taken as OpenAI rejecting Magpie's request, and pauses painting.
        Outcome::Fault(openai::Fault::Rejected) if same_key => {
            adjust(state, at, refund);
            row["reason"] = json!("pictures_request_rejected");
            row["retryAt"] = json!(at + MODEL_WAIT);
            let mut run = refusal_run(state);
            run.push(subject.to_owned());
            if run.len() >= REFUSAL_RUN || blocking_problem(state, at) == Some("pictures_request_rejected") {
                state["refusedRun"] = json!([]);
                stop(state, "pictures_request_rejected", Some(MODEL_WAIT), at);
                true
            } else {
                state["refusedRun"] = json!(run);
                false
            }
        }
        // An answer to a key that has since been replaced leaves the picture as it was.
        Outcome::Fault(openai::Fault::Rejected) => {
            adjust(state, at, refund);
            false
        }
        // A refusal by the safety system does not always repeat, so the picture is asked for
        // again before it is given up.
        Outcome::Fault(openai::Fault::Refused) => {
            adjust(state, at, refund);
            failed_once(row, "pictures_refused", at);
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

/// Set by a test to hold a run after a picture's answer and before it is saved: the run says it
/// has arrived, then waits for a permit.
#[cfg(test)]
#[allow(clippy::type_complexity)]
static TEST_SAVING_GATE: Mutex<Option<(tokio::sync::mpsc::UnboundedSender<()>, Arc<tokio::sync::Semaphore>)>> =
    Mutex::new(None);

#[cfg(test)]
async fn test_saving_gate() {
    let gate = TEST_SAVING_GATE.lock().ok().and_then(|gate| gate.clone());
    if let Some((arrived, permits)) = gate {
        let _ = arrived.send(());
        if let Ok(permit) = permits.acquire().await {
            permit.forget();
        }
    }
}

/// Set by a test to have the app leave the foreground while the next photo or logo is fetched.
#[cfg(all(test, feature = "mobile"))]
static TEST_LEAVE_WHILE_FETCHING: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

#[cfg(test)]
fn test_reference(address: &str) -> Option<String> {
    #[cfg(feature = "mobile")]
    if TEST_LEAVE_WHILE_FETCHING.swap(false, Ordering::AcqRel) {
        super::claude::diagnostics::foreground(false);
    }
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
    // Fetching the reference takes time, so the app may have left since the picture was reserved.
    // Read before the foreground check, so a departure between the two is seen as one during the
    // request.
    let left_before = departures();
    if !may_start() {
        return Outcome::Stopped;
    }
    match openai::paint(key, MODEL, &request).await {
        Ok(painted) => {
            let (cents, micro_dollars) = (painted.cents, painted.micro_dollars);
            match tokio::task::spawn_blocking(move || avatars::artwork::master(painted.png)).await {
                Ok(Ok(jpeg)) => Outcome::Painted { jpeg, cents, micro_dollars, reference: fingerprint },
                _ => Outcome::Unusable { cents, micro_dollars },
            }
        }
        Err(openai::Fault::Lost { charged }) if departures() != left_before => Outcome::CutOff { charged },
        Err(fault) => Outcome::Fault(fault),
    }
}

/// Pictures started and not yet saved with their cost, so leaving the app can wait for them.
static UNDER_WAY: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);

/// Counts one picture in `UNDER_WAY` for as long as it lives.
struct UnderWay;

impl UnderWay {
    fn new() -> Self {
        UNDER_WAY.fetch_add(1, Ordering::AcqRel);
        UnderWay
    }
}

impl Drop for UnderWay {
    fn drop(&mut self) {
        UNDER_WAY.fetch_sub(1, Ordering::AcqRel);
    }
}

/// Whether a picture is being asked for or saved.
#[cfg_attr(not(feature = "mobile"), allow(dead_code))]
pub(crate) fn under_way() -> bool {
    UNDER_WAY.load(Ordering::Acquire) > 0
}

/// Whether the phone still shows sender pictures. Hiding them stops the run under way after the
/// picture in hand; asking for pictures again allows them. Linux has no such switch.
#[cfg(feature = "mobile")]
static WANTED: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(true);

#[cfg(feature = "mobile")]
pub(crate) fn want(wanted: bool) {
    WANTED.store(wanted, Ordering::Release);
}

/// What this process last read from the keyring: the key (or that none is saved), or the time the
/// read failed.
type KeyRead = Result<Option<Arc<Secret>>, i64>;

/// The last keyring read, with the key generation it was read under.
static KEY: Mutex<Option<(u64, KeyRead)>> = Mutex::new(None);

fn forget_cached_key() {
    if let Ok(mut cache) = KEY.lock() {
        *cache = None;
    }
}

/// Who asks for the key. Settings reads a keyring that failed again at once, because the user may
/// just have unlocked it; painting waits `KEYRING_WAIT`.
#[derive(Clone, Copy, PartialEq)]
enum Asker {
    Painting,
    Settings,
}

/// The answer an earlier read gives for this key generation, or None when the keyring must be read.
fn cached_key(
    cache: Option<&(u64, KeyRead)>,
    key_generation: u64,
    asker: Asker,
    at: i64,
) -> Option<Result<Option<Arc<Secret>>, &'static str>> {
    let (read_under, read) = cache?;
    if *read_under != key_generation {
        return None;
    }
    match read {
        Ok(key) => Some(Ok(key.clone())),
        Err(failed) if asker == Asker::Painting && at.saturating_sub(*failed) < KEYRING_WAIT => {
            Some(Err("pictures_key_storage"))
        }
        Err(_) => None,
    }
}

/// The saved key for this key generation. The keyring is read again only after the key changes,
/// or after a failed read (see `Asker`).
async fn saved_key(key_generation: u64, asker: Asker) -> Result<Option<Arc<Secret>>, &'static str> {
    // Tests each use their own keyring, so they always read it.
    if !cfg!(test)
        && let Ok(cache) = KEY.lock()
        && let Some(answer) = cached_key(cache.as_ref(), key_generation, asker, now())
    {
        return answer;
    }
    let read: KeyRead = match credentials::get(slot()).await {
        Ok(key) => Ok(Some(Arc::new(key))),
        Err(credentials::Error::Missing) => Ok(None),
        Err(_) => Err(now()),
    };
    if let Ok(mut cache) = KEY.lock() {
        *cache = Some((key_generation, read.clone()));
    }
    read.map_err(|_| "pictures_key_storage")
}

/// Forgets the senders of accounts not in `accounts`, and the pictures only they used, as the next
/// painting run would. The phone calls it when an account is removed, because without a key no
/// painting run comes. Blocks.
#[cfg(feature = "mobile")]
pub(crate) fn forget_removed(accounts: &[String]) -> Result<(), &'static str> {
    if directory(false)?.is_none() {
        return Ok(());
    }
    let known: HashSet<String> = accounts.iter().map(|account| id(&["picture-account", account])).collect();
    change(|dir, state| forget(dir, state, &known, now()))
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

/// Matches the account's senders to their pictures and paints the due ones, at most `IN_FLIGHT` at a
/// time. Without a key, or while painting is stopped, it only matches them, so pictures painted
/// earlier or taken in from another device show; a device that has none does nothing more.
async fn run(
    accounts: Vec<String>,
    account: String,
    gmail: Arc<crate::providers::gmail::Session>,
    local_mail: Arc<crate::local_mail::LocalMail>,
) -> Result<(), &'static str> {
    let known: HashSet<String> = accounts.iter().map(|account| id(&["picture-account", account])).collect();
    let (stopped, key_generation, shown) = blocking(move || {
        change(|dir, state| {
            forget(dir, state, &known, now())?;
            Ok((blocking_problem(state, now()).is_some(), generation(state), has_pictures(state)))
        })
    })
    .await?;
    // A keyring that cannot be read is treated as no key here; Settings reports it.
    let key = if stopped { None } else { saved_key(key_generation, Asker::Painting).await.ok().flatten() };
    if key.is_none() && !shown {
        return Ok(());
    }
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
    match_and_paint(owner, assignments, contacts_known, key, key_generation).await
}

/// Whether any picture is painted, here or on another device, for a sender to be matched to.
fn has_pictures(state: &Value) -> bool {
    state["subjects"]
        .as_object()
        .is_some_and(|subjects| subjects.values().any(|row| matches!(row["state"].as_str(), Some("painted" | "recheck"))))
}

/// Records which picture each sender gets and, with a key, paints the ones due. A sender newly
/// given a painted picture, such as one taken in from iCloud, tells the window to show it.
async fn match_and_paint(
    owner: String,
    assignments: Vec<(String, Subject)>,
    contacts_known: bool,
    key: Option<Arc<Secret>>,
    key_generation: u64,
) -> Result<(), &'static str> {
    let (due, newly_shown) = blocking(move || {
        change(|_, state| {
            let before = shown_pictures(state, &assignments);
            let due = assign(state, &owner, &assignments, contacts_known, now())?;
            Ok((due, shown_pictures(state, &assignments) != before))
        })
    })
    .await?;
    if newly_shown {
        seed_revision();
        REVISION.fetch_add(1, Ordering::Relaxed);
    }
    let Some(key) = key else {
        return Ok(());
    };
    if due.is_empty() {
        return Ok(());
    }
    paint_all(due, key, key_generation).await
}

/// The painted picture each of these senders shows, if any.
fn shown_pictures(state: &Value, assignments: &[(String, Subject)]) -> Vec<Option<String>> {
    assignments
        .iter()
        .map(|(sender, _)| {
            let subject = state["senders"][sender]["subject"].as_str()?;
            matches!(state["subjects"][subject]["state"].as_str(), Some("painted" | "recheck")).then(|| subject.to_owned())
        })
        .collect()
}

/// Whether a listed picture still waits for painting; one taken in from iCloud since the run listed
/// it does not.
fn still_due(state: &Value, subject: &str) -> bool {
    matches!(state["subjects"][subject]["state"].as_str(), Some("waiting" | "recheck"))
}

/// What a finished request cost in billionths of a dollar for the spending page: a painted picture
/// from its reported usage, and one lost after it may have been charged at the estimate the daily
/// limit keeps for it.
/// A picture's reservation in billionths of a dollar.
fn estimate() -> u64 {
    u64::try_from(openai::ESTIMATE_CENTS).unwrap_or(0).saturating_mul(10_000_000)
}

fn spent_on(outcome: &Outcome) -> u64 {
    let micro_dollars = match outcome {
        Outcome::Painted { micro_dollars, .. } | Outcome::Unusable { micro_dollars, .. } => *micro_dollars,
        Outcome::Fault(openai::Fault::Lost { charged: true }) | Outcome::CutOff { charged: true } => {
            openai::ESTIMATE_CENTS * 10_000
        }
        _ => 0,
    };
    u64::try_from(micro_dollars).unwrap_or(0).saturating_mul(1_000)
}

/// Whether a new picture may be asked for. On the phone only while Magpie is in the foreground,
/// because iOS freezes the app soon after it leaves and a picture cut off there may still be
/// charged, and only while sender pictures are shown.
fn may_start() -> bool {
    #[cfg(feature = "mobile")]
    if super::PHONE_WRITER {
        return super::claude::diagnostics::active() && WANTED.load(Ordering::Acquire);
    }
    true
}

/// How many times the app has left the foreground; a change means it left during a request. The
/// desktop never leaves it.
fn departures() -> u64 {
    #[cfg(feature = "mobile")]
    if super::PHONE_WRITER {
        return super::claude::diagnostics::suspensions();
    }
    0
}

/// A picture being painted: its subject, its reservation on the spending page and whether that was
/// written, and its place in `UNDER_WAY`, which ends when the entry is dropped.
struct Running {
    subject: String,
    ledger: String,
    reserved: bool,
    _under_way: UnderWay,
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
            if !may_start() {
                stopped = true;
                break;
            }
            let Some((subject, previous)) = queue.next() else {
                break;
            };
            let name = subject.id();
            let listed = name.clone();
            let reserved =
                blocking(move || change(|_, state| Ok(still_due(state, &listed).then(|| reserve(state, now(), key_generation)))));
            match reserved.await {
                Ok(Some(true)) => {}
                Ok(None) => continue,
                Ok(Some(false)) => {
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
            // Counted until the picture and its cost are saved, so leaving the app waits for it.
            let under_way = UnderWay::new();
            // The spending page counts the reservation until the cost is known, as the limit does.
            let ledger = format!("pictures-{name}-{}", now());
            let reserved = super::spending::reserve(ledger.clone(), "pictures", estimate()).await;
            let task = tasks.spawn(openai::inherit(async move {
                let outcome = paint(&subject, previous.as_deref(), &key).await;
                (subject.id(), outcome)
            }));
            running.insert(task.id(), Running { subject: name, ledger, reserved, _under_way: under_way });
        }
        let Some(finished) = tasks.join_next_with_id().await else {
            return failure.map_or(Ok(()), Err);
        };
        // A task that panicked may have been charged: count it as a lost, charged attempt.
        let (subject, entry, outcome) = match finished {
            Ok((task, (subject, outcome))) => (subject, running.remove(&task), outcome),
            Err(error) => match running.remove(&error.id()) {
                Some(entry) => (entry.subject.clone(), Some(entry), Outcome::Fault(openai::Fault::Lost { charged: true })),
                None => continue,
            },
        };
        #[cfg(test)]
        test_saving_gate().await;
        let spent = spent_on(&outcome);
        let recorded = blocking(move || change(|dir, state| record(dir, state, &subject, outcome, now(), key_generation))).await;
        if let Some(entry) = entry {
            super::spending::settle(entry.ledger, "pictures", spent, entry.reserved).await;
        }
        match recorded {
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
    /// The account list the prepared painted avatars were last cleaned against.
    listed: Arc<Mutex<Option<Vec<String>>>>,
}

impl Default for Painter {
    fn default() -> Self {
        Self {
            busy: Arc::new(tokio::sync::Semaphore::new(1)),
            turns: Mutex::new(HashMap::new()),
            listed: Arc::new(Mutex::new(None)),
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
        // Until a cleaning succeeds for the current account list, and so once after the engine
        // starts, drop the prepared painted avatars of accounts no longer listed.
        let mut sorted = accounts.clone();
        sorted.sort();
        let listed = self.listed.clone();
        let changed = listed.lock().is_ok_and(|listed| listed.as_ref() != Some(&sorted));
        tokio::spawn(async move {
            let _permit = permit;
            if changed {
                let cleaned = sorted.clone();
                if blocking(move || avatars::forget_painted(&cleaned)).await.is_ok()
                    && let Ok(mut listed) = listed.lock()
                {
                    *listed = Some(sorted);
                }
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
    Ok(jpeg(&dir, subject)?.map(|bytes| format!("data:image/jpeg;base64,{}", STANDARD.encode(bytes))))
}

/// A painted picture's JPEG, or None when it is missing or larger than any picture Magpie keeps.
fn jpeg(dir: &File, subject: &str) -> Result<Option<Vec<u8>>, &'static str> {
    let Some(file) = fs::regular_readonly(dir, &format!("{subject}.jpg"))? else {
        return Ok(None);
    };
    let mut bytes = Vec::new();
    file.take(MASTER_LIMIT + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| "pictures_storage_unavailable")?;
    Ok((bytes.len() as u64 <= MASTER_LIMIT).then_some(bytes))
}

/// What Settings shows: whether a key is saved, what stops painting, and the counts. Spending is
/// estimated from OpenAI's reported usage at list prices; it is not OpenAI's bill. When the keyring
/// cannot be read, `present` is null and the keyring is the problem; the counts are still given.
pub(crate) async fn status() -> Result<Value, &'static str> {
    let (state, size) = blocking(|| match directory(false)? {
        Some(dir) => Ok((read_state(&dir)?, state_size(&dir)?)),
        None => Ok((json!({}), 0)),
    })
    .await?;
    let (present, keyring) = match saved_key(generation(&state), Asker::Settings).await {
        Ok(key) => (json!(key.is_some()), None),
        Err(problem) => (Value::Null, Some(problem)),
    };
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
        "problem": keyring.or(blocking_problem(&state, at)).or(full),
        "painted": counts.get("painted").copied().unwrap_or(0),
        "waiting": counts.get("waiting").copied().unwrap_or(0),
        "failed": counts.get("failed").copied().unwrap_or(0),
        "spentTodayCents": spent_today(&state, at),
        "dailyLimitCents": DAILY_LIMIT_CENTS,
    }))
}

/// Moves to a new key generation, which stops runs holding the old key from sending further
/// requests. Once the keyring has changed (`settled`), it also clears the problem that paused
/// painting, since that problem belonged to the old key.
fn key_changed(settled: bool) -> impl FnOnce() -> Result<u64, &'static str> + Send + 'static {
    move || {
        change(|_, state| {
            let next = generation(state) + 1;
            if settled && let Some(fields) = state.as_object_mut() {
                fields.remove("problem");
                fields.remove("retryAt");
                fields.remove("refusedRun");
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
    blocking(key_changed(false)).await?;
    match update.await {
        Ok(()) | Err(credentials::Error::Missing) => {}
        Err(_) => return Err("pictures_key_storage"),
    }
    forget_cached_key();
    let mut last = Ok(0);
    for _ in 0..3 {
        last = blocking(key_changed(true)).await;
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

/// Most pictures one call hands over or takes in, so a reply stays a few megabytes.
#[cfg(any(feature = "mobile", test))]
const SHARE_BATCH: usize = 8;
/// Widest side and largest size of a picture taken from iCloud: twice the side Magpie paints
/// (`avatars::artwork::master`, 512 pixels), and far more than such a JPEG needs.
#[cfg(any(feature = "mobile", test))]
const SHARED_SIDE_LIMIT: u32 = 1024;
#[cfg(any(feature = "mobile", test))]
const SHARED_LIMIT: u64 = 1024 * 1024;

/// Pictures painted on this device that iCloud does not have yet, with their JPEGs, for the app to
/// share with Dave's other devices. A row's `uploaded` is the `painted` time iCloud has, so a
/// picture painted again is shared again, and one taken from iCloud is never sent back. The photo
/// address is not shared: the other device has its own from the contacts.
#[cfg(any(feature = "mobile", test))]
pub(crate) async fn to_share(params: &Value) -> Result<Value, &'static str> {
    use base64::{Engine, engine::general_purpose::STANDARD};
    let limit = params
        .as_object()
        .filter(|fields| fields.len() == 1)
        .and(params["limit"].as_u64())
        .filter(|limit| (1..=SHARE_BATCH as u64).contains(limit))
        .ok_or("invalid_params")? as usize;
    blocking(move || {
        let Some(dir) = directory(false)? else {
            return Ok(json!({"pictures": []}));
        };
        let state = read_state(&dir)?;
        let mut pictures = Vec::new();
        for (subject, row) in state["subjects"].as_object().into_iter().flatten() {
            if pictures.len() == limit {
                break;
            }
            let Some(painted) = row["painted"].as_i64() else {
                continue;
            };
            if !is_name(subject) || row["state"] != "painted" || row["uploaded"].as_i64() == Some(painted) {
                continue;
            }
            let Some(kind) = row["kind"].as_str().filter(|kind| KINDS.contains(kind)) else {
                continue;
            };
            let Some(bytes) = jpeg(&dir, subject)?.filter(|bytes| bytes.len() as u64 <= SHARED_LIMIT) else {
                continue;
            };
            let mut picture = json!({"subject": subject, "kind": kind, "painted": painted, "jpeg": STANDARD.encode(bytes)});
            if let Some(reference) = row["reference"].as_str() {
                picture["reference"] = json!(reference);
            }
            pictures.push(picture);
        }
        Ok(json!({"pictures": pictures}))
    })
    .await
}

/// Records that iCloud now has these pictures as painted at these times.
#[cfg(any(feature = "mobile", test))]
pub(crate) async fn shared(params: &Value) -> Result<Value, &'static str> {
    let rows = params
        .as_object()
        .filter(|fields| fields.len() == 1)
        .and(params["pictures"].as_array())
        .filter(|rows| rows.len() <= SHARE_BATCH)
        .ok_or("invalid_params")?;
    let mut done = Vec::new();
    for row in rows {
        let subject = row["subject"].as_str().filter(|subject| is_name(subject));
        let painted = row["painted"].as_i64();
        match (row.as_object().map(serde_json::Map::len), subject, painted) {
            (Some(2), Some(subject), Some(painted)) => done.push((subject.to_owned(), painted)),
            _ => return Err("invalid_params"),
        }
    }
    let marked = blocking(move || {
        change(|_, state| {
            let mut subjects = object(state, "subjects")?;
            let mut marked = 0;
            for (subject, painted) in done {
                if let Some(row) = subjects.get_mut(&subject).filter(|row| row["painted"].as_i64() == Some(painted)) {
                    row["uploaded"] = json!(painted);
                    marked += 1;
                }
            }
            state["subjects"] = Value::Object(subjects);
            Ok(marked)
        })
    })
    .await?;
    Ok(json!({"marked": marked}))
}

/// Records that iCloud has none of the pictures any more, because their zone was deleted, so every
/// painted picture is shared again.
#[cfg(any(feature = "mobile", test))]
pub(crate) async fn unshared(params: &Value) -> Result<Value, &'static str> {
    if params.as_object().is_none_or(|fields| !fields.is_empty()) {
        return Err("invalid_params");
    }
    let cleared = blocking(|| {
        if directory(false)?.is_none() {
            return Ok(0);
        }
        change(|_, state| {
            let mut subjects = object(state, "subjects")?;
            let mut cleared = 0;
            for row in subjects.values_mut() {
                if row.as_object_mut().and_then(|fields| fields.remove("uploaded")).is_some() {
                    cleared += 1;
                }
            }
            state["subjects"] = Value::Object(subjects);
            Ok(cleared)
        })
    })
    .await?;
    Ok(json!({"cleared": cleared}))
}

#[cfg(any(feature = "mobile", test))]
const KINDS: [&str; 3] = ["person", "organization", "monogram"];

/// One picture from iCloud, checked: iCloud is Dave's own, but what it returns is read like any
/// other outside data.
#[cfg(any(feature = "mobile", test))]
struct Shared {
    subject: String,
    kind: String,
    painted: i64,
    jpeg: Vec<u8>,
    reference: Option<String>,
}

#[cfg(any(feature = "mobile", test))]
fn shared_picture(row: &Value, at: i64) -> Option<Shared> {
    use base64::{Engine, engine::general_purpose::STANDARD};
    let fields = row.as_object()?;
    let known = ["subject", "kind", "painted", "jpeg", "reference"];
    if !fields.keys().all(|key| known.contains(&key.as_str())) {
        return None;
    }
    let subject = row["subject"].as_str().filter(|subject| is_name(subject))?;
    let kind = row["kind"].as_str().filter(|kind| KINDS.contains(kind))?;
    // A day's grace for another device's clock.
    let painted = row["painted"].as_i64().filter(|painted| *painted > 0 && *painted <= at + 86_400_000)?;
    let encoded = row["jpeg"].as_str().filter(|text| text.len() as u64 <= SHARED_LIMIT.div_ceil(3) * 4)?;
    let jpeg = STANDARD.decode(encoded).ok().filter(|bytes| bytes.len() as u64 <= SHARED_LIMIT)?;
    let reader = || image::ImageReader::with_format(std::io::Cursor::new(&jpeg), image::ImageFormat::Jpeg);
    let (width, height) = reader().into_dimensions().ok()?;
    // Magpie's own encoder (`avatars::artwork::master`) makes every shared picture and always ends
    // it with the end-of-image marker, so a picture cut off in transit is refused rather than
    // shown; the decoder alone accepts one.
    if !jpeg.starts_with(&[0xFF, 0xD8, 0xFF])
        || !jpeg.ends_with(&[0xFF, 0xD9])
        || width == 0
        || height == 0
        || width.max(height) > SHARED_SIDE_LIMIT
    {
        return None;
    }
    // The whole image is decoded, so a picture whose data the decoder cannot read is refused.
    reader().decode().ok()?;
    let reference = match &row["reference"] {
        Value::Null => None,
        Value::String(text) if is_name(text) => Some(text.clone()),
        _ => return None,
    };
    Some(Shared { subject: subject.to_owned(), kind: kind.to_owned(), painted, jpeg, reference })
}

/// Takes pictures another of Dave's devices painted, so this one shows them without painting
/// them again. A picture this device has painted at the same time or later is kept. A portrait keeps
/// this device's photo address, so the next run checks it against the photo's fingerprint without
/// cost, and a row keeps the time it became unused, so an unused picture still goes after
/// `ORPHAN_KEEP`. Invalid ones are counted as refused and skipped, so one bad record cannot hold up
/// the rest.
#[cfg(any(feature = "mobile", test))]
pub(crate) async fn import(params: &Value) -> Result<Value, &'static str> {
    let rows = params
        .as_object()
        .filter(|fields| fields.len() == 1)
        .and(params["pictures"].as_array())
        .filter(|rows| rows.len() <= SHARE_BATCH)
        .ok_or("invalid_params")?;
    let at = now();
    let checked: Vec<Option<Shared>> = rows.iter().map(|row| shared_picture(row, at)).collect();
    let (stored, kept, refused) = blocking(move || {
        change(|dir, state| {
            let mut subjects = object(state, "subjects")?;
            let (mut stored, mut kept, mut refused) = (0, 0, 0);
            for picture in checked {
                let Some(picture) = picture else {
                    refused += 1;
                    continue;
                };
                let current = subjects.get(&picture.subject);
                if current.is_some_and(|row| row["kind"] != picture.kind.as_str()) {
                    refused += 1;
                    continue;
                }
                let shown = current.is_some_and(|row| matches!(row["state"].as_str(), Some("painted" | "recheck")));
                if shown && current.and_then(|row| row["painted"].as_i64()).is_some_and(|mine| mine >= picture.painted) {
                    kept += 1;
                    continue;
                }
                if let Err(error) = fs::atomic_replace(dir, &format!("{}.jpg", picture.subject), &picture.jpeg) {
                    state["subjects"] = Value::Object(subjects);
                    return Err(error);
                }
                let mut row =
                    json!({"state":"painted","painted":picture.painted,"attempts":0,"kind":picture.kind,"uploaded":picture.painted});
                if let Some(reference) = picture.reference {
                    row["reference"] = json!(reference);
                }
                for field in ["photo", "orphaned"] {
                    if let Some(value) = current.map(|row| &row[field]).filter(|value| !value.is_null()) {
                        row[field] = value.clone();
                    }
                }
                subjects.insert(picture.subject, row);
                stored += 1;
            }
            state["subjects"] = Value::Object(subjects);
            Ok((stored, kept, refused))
        })
    })
    .await?;
    if stored > 0 {
        seed_revision();
        REVISION.fetch_add(1, Ordering::Relaxed);
    }
    Ok(json!({"stored": stored, "kept": kept, "refused": refused, "pictures": revision()}))
}

#[cfg(test)]
#[path = "pictures_tests.rs"]
mod tests;
