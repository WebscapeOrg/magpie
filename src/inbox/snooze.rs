//! Snooze keeps its schedule in Gmail. A snoozed thread carries a hidden label named for its
//! five-minute wake slot, such as `Magpie-snooze-2026-11-02-0500-UTC`, so every Magpie signed in
//! to the account (desktop, iPhone, iPad) can list and wake it, whichever runs first.
//! `snoozes.json` mirrors those labels on this device: it answers snapshots offline and holds
//! snoozes Gmail has not confirmed yet. Each change gives the row a new `generation`.
use super::{account, fields, now, store};
use serde_json::{Map, Value, json};
use std::collections::{BTreeMap, HashSet};
use std::future::Future;
use std::time::{Duration, Instant};

type Result<T> = std::result::Result<T, &'static str>;
const FILE: &str = "snoozes.json";
/// Wake times are labelled in five-minute slots, rounded up so no device wakes a thread early.
const SLOT: i64 = 300_000;
const ROWS: usize = 1000;
const LABELS: usize = 200;
const DISCOVER_EVERY: i64 = 60_000;
const RELIST_AFTER: i64 = 600_000;
const LISTS_PER_RUN: usize = 5;
const READS_PER_RUN: usize = 20;
const WORK_PER_RUN: usize = 10;
const MAX_SECONDS: u64 = 40;
/// An emptied due slot label stays this long before Magpie deletes it, so a Magpie that was off
/// meanwhile can tell a label removed after its mail returned from one deleted before its time.
const KEEP_DUE: i64 = 3 * 86_400_000;
/// A snooze that cannot read its thread in this time is saved to finish once Gmail answers.
const RESOLVE_WITHIN: Duration = Duration::from_secs(25);
/// A snooze Gmail could not take or return is tried again after a growing pause, so one that keeps
/// failing never holds up the others. Only failures caused by the message itself wait more than
/// five minutes, so mail returns soon after the network or Dave's Google access is back.
const BACKOFF: i64 = 60_000;
const BACKOFF_OFFLINE: i64 = 5 * 60_000;
const BACKOFF_MAX: i64 = 6 * 3_600_000;

/// The Gmail operations snooze needs, so its rules can be tested without a server.
pub(super) trait Mail: Sync {
    fn read(&self, account: &str, id: &str) -> impl Future<Output = Result<Value>> + Send;
    fn thread(
        &self,
        account: &str,
        thread: &str,
    ) -> impl Future<Output = Result<Vec<Value>>> + Send;
    fn labels(&self, account: &str) -> impl Future<Output = Result<Value>> + Send;
    fn create_label(&self, account: &str, name: &str)
    -> impl Future<Output = Result<Value>> + Send;
    fn delete_label(&self, account: &str, id: &str) -> impl Future<Output = Result<()>> + Send;
    fn modify(
        &self,
        account: &str,
        ids: &[String],
        add: &[String],
        remove: &[String],
    ) -> impl Future<Output = Result<()>> + Send;
    fn list(
        &self,
        account: &str,
        label: &str,
        page: &str,
    ) -> impl Future<Output = Result<Value>> + Send;
    fn accounts(&self) -> impl Future<Output = Result<Vec<String>>> + Send;
}

impl Mail for crate::providers::gmail::Session {
    async fn read(&self, account: &str, id: &str) -> Result<Value> {
        self.call(
            "gmail.read",
            &json!({"accountId":account,"id":id,"full":false}),
        )
        .await
    }
    async fn thread(&self, account: &str, thread: &str) -> Result<Vec<Value>> {
        self.thread_labels(account, thread).await
    }
    async fn labels(&self, account: &str) -> Result<Value> {
        self.all_labels(account).await
    }
    async fn create_label(&self, account: &str, name: &str) -> Result<Value> {
        self.call(
            "gmail.createLabel",
            &json!({"accountId":account,"name":name,"hidden":true}),
        )
        .await
    }
    async fn delete_label(&self, account: &str, id: &str) -> Result<()> {
        match self
            .call("gmail.deleteLabel", &json!({"accountId":account,"id":id}))
            .await
        {
            Ok(_) | Err("gmail_not_found") => Ok(()),
            Err(error) => Err(error),
        }
    }
    async fn modify(
        &self,
        account: &str,
        ids: &[String],
        add: &[String],
        remove: &[String],
    ) -> Result<()> {
        self.call_withdrawable(
            "gmail.batchModify",
            &json!({"accountId":account,"ids":ids,"addLabelIds":add,"removeLabelIds":remove}),
        )
        .await
        .map(|_| ())
    }
    async fn list(&self, account: &str, label: &str, page: &str) -> Result<Value> {
        let mut params = json!({"accountId":account,"query":"","pageSize":100,"labelId":label});
        if !page.is_empty() {
            params["pageToken"] = json!(page);
        }
        self.call("gmail.list", &params).await
    }
    async fn accounts(&self) -> Result<Vec<String>> {
        let saved = tokio::task::spawn_blocking(crate::account::list_readonly)
            .await
            .map_err(|_| "inbox_unavailable")??;
        Ok(saved["accounts"]
            .as_array()
            .into_iter()
            .flatten()
            .filter(|row| row["provider"] == "gmail")
            .filter_map(|row| row["id"].as_str())
            .map(str::to_owned)
            .collect())
    }
}

/// Records that this device keeps snooze bookkeeping for the account, so `drop_accounts` removes it
/// once the account signs out, even when no snooze of it is left.
fn note(account: &str) -> Result<()> {
    let key = store::key(&["snooze-accounts"]);
    if bookkeeping(&key)?["accounts"]
        .as_array()
        .is_some_and(|list| list.iter().any(|v| v == account))
    {
        return Ok(());
    }
    store::update(&key, |saved| {
        if !saved["accounts"].is_array() {
            *saved = json!({"accounts":[]});
        }
        if let Some(list) = saved["accounts"].as_array_mut()
            && !list.iter().any(|v| v == account)
        {
            list.push(json!(account));
        }
        Ok(())
    })
}

/// Reads a bookkeeping file, starting it again when it is damaged. These files only save work, so a
/// damaged one must not stop snooze on this device.
fn bookkeeping(name: &str) -> Result<Value> {
    match store::read(name) {
        Ok(Some(saved)) if saved.is_object() => Ok(saved),
        Ok(_) => Ok(json!({})),
        Err("inbox_storage_invalid") => {
            store::replace(name, &json!({}))?;
            Ok(json!({}))
        }
        Err(error) => Err(error),
    }
}
fn random() -> Result<String> {
    let mut entropy = [0; 16];
    rustls::crypto::ring::default_provider()
        .secure_random
        .fill(&mut entropy)
        .map_err(|_| "snooze_storage_failed")?;
    use base64::Engine;
    Ok(base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(entropy))
}
/// A new generation for a change to a thread's snooze, noting the account so its bookkeeping is
/// cleared when it signs out.
fn advance(account: &str, thread: &str) -> Result<String> {
    if thread.is_empty() {
        return random();
    }
    note(account)?;
    random()
}

fn rows() -> Result<Map<String, Value>> {
    match store::read(FILE)?.unwrap_or(json!({})) {
        Value::Object(rows) => Ok(rows),
        _ => Err("inbox_storage_invalid"),
    }
}
fn change(run: impl FnOnce(&mut Map<String, Value>) -> Result<()>) -> Result<()> {
    store::update(FILE, |saved| {
        run(saved.as_object_mut().ok_or("inbox_storage_invalid")?)
    })
}
fn forget(key: &str) -> Result<()> {
    change(|rows| {
        rows.remove(key);
        Ok(())
    })
}
/// Saves a snooze, replacing any other snooze of the same thread once its thread is known.
fn record(key: &str, row: Value) -> Result<()> {
    change(|rows| {
        let thread = row["threadId"].as_str().unwrap_or("");
        if !thread.is_empty() && row["ids"].as_array().is_some_and(|ids| !ids.is_empty()) {
            rows.retain(|other, saved| {
                other == key
                    || saved["accountId"] != row["accountId"]
                    || saved["threadId"] != thread
            });
        }
        if rows.len() >= ROWS && !rows.contains_key(key) {
            return Err("snooze_limit");
        }
        rows.insert(key.to_owned(), row);
        Ok(())
    })
}
/// Clears the record of failed attempts once a row's change lands.
fn settled(row: &mut Value) {
    if let Some(fields) = row.as_object_mut() {
        fields.remove("attempts");
        fields.remove("retryAt");
    }
}
fn confirm(key: &str, name: &str, label: &str) -> Result<()> {
    change(|rows| {
        if let Some(row) = rows.get_mut(key).filter(|row| row["label"] == name) {
            row["state"] = json!("sleeping");
            row["labelId"] = json!(label);
            settled(row);
        }
        Ok(())
    })
}
/// Moves a row to the slot another device chose, with a new generation for the thread.
fn readopt(key: &str, slot: &Slot, generation: &str) -> Result<()> {
    change(|rows| {
        if let Some(row) = rows.get_mut(key) {
            row["generation"] = json!(generation);
            row["label"] = json!(slot.name);
            row["labelId"] = json!(slot.id);
            row["until"] = json!(slot.until);
            row["state"] = json!("sleeping");
            settled(row);
        }
        Ok(())
    })
}
/// Puts a row that failed off until its pause ends, doubling the pause each time.
fn defer(key: &str, error: &str) -> Result<()> {
    let cap = if lasting(error) {
        BACKOFF_MAX
    } else {
        BACKOFF_OFFLINE
    };
    change(|rows| {
        if let Some(row) = rows.get_mut(key) {
            let attempts = row["attempts"].as_u64().unwrap_or(0).min(20);
            row["attempts"] = json!(attempts + 1);
            row["retryAt"] = json!(now() + (BACKOFF << attempts.min(10)).min(cap));
        }
        Ok(())
    })
}

pub(super) fn snapshot(account: &str) -> Result<Value> {
    Ok(json!(
        rows()?
            .into_values()
            .filter(|v| v["accountId"] == account)
            .collect::<Vec<_>>()
    ))
}

fn safe_id(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= 256
        && id
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
}
fn message_id(id: &str) -> bool {
    crate::mail::action::validate_message_id(crate::mail::Provider::Gmail, id).is_ok()
}
/// Failures that say nothing about the message, so the snooze is kept and tried again.
fn transient(error: &str) -> bool {
    matches!(
        error,
        "gmail_timeout"
            | "gmail_http_failed"
            | "gmail_server_rate_limited"
            | "gmail_session_invalidated"
            | "gmail_queue_dropped"
            | "gmail_request_deferred"
            | "session_failed"
    )
}
/// Failures caused by the message or its saved snooze, which signing in again or a working network
/// does not fix.
fn lasting(error: &str) -> bool {
    error.starts_with("snooze_")
        || matches!(
            error,
            "gmail_invalid_response"
                | "gmail_response_too_large"
                | "gmail_invalid_input"
                | "agent_context_too_large"
                | "inbox_storage_invalid"
        )
}
/// Failures that say the message itself can no longer be snoozed, so a saved snooze of it ends.
fn ended(error: &str) -> bool {
    matches!(
        error,
        "gmail_not_found" | "snooze_invalid_folder" | "snooze_invalid_thread"
    )
}
fn has(message: &Value, label: &str) -> bool {
    message["labelIds"]
        .as_array()
        .is_some_and(|labels| labels.iter().any(|v| v == label))
}
fn binned(message: &Value) -> bool {
    has(message, "TRASH") || has(message, "SPAM")
}
fn plain(text: &str) -> String {
    text.chars()
        .map(|c| if c.is_control() { ' ' } else { c })
        .take(300)
        .collect()
}

/// The slot label for a wake time.
fn slot(until: i64) -> Result<(i64, String)> {
    let at = until
        .checked_add(SLOT - 1)
        .ok_or("snooze_invalid_time")?
        .div_euclid(SLOT)
        * SLOT;
    let time = chrono::DateTime::from_timestamp_millis(at).ok_or("snooze_invalid_time")?;
    Ok((
        at,
        time.format("Magpie-snooze-%Y-%m-%d-%H%M-UTC").to_string(),
    ))
}
/// The wake time a Magpie slot label names. Any other label is not Magpie's and is ignored.
fn slot_time(name: &str) -> Option<i64> {
    let lower = name.to_ascii_lowercase();
    let stamp = lower.strip_prefix("magpie-snooze-")?.strip_suffix("-utc")?;
    if stamp.len() != 15 {
        return None;
    }
    let at = chrono::NaiveDateTime::parse_from_str(stamp, "%Y-%m-%d-%H%M")
        .ok()?
        .and_utc()
        .timestamp_millis();
    (slot(at).ok()?.1.to_ascii_lowercase() == lower).then_some(at)
}
/// True for Magpie's snooze slot labels, which Magpie keeps out of the label lists it shows.
pub(crate) fn is_snooze_label(name: &str) -> bool {
    slot_time(name).is_some() || name.eq_ignore_ascii_case(RETURNED_LABEL)
}
/// Marks mail a snooze brought back, in the same Gmail change as the wake, so every device keeps
/// it out of bundles (bundles.rs): it was snoozed to be seen again as its own row.
pub(crate) const RETURNED_LABEL: &str = "Magpie-snooze-returned";
/// How many mails returned without their mark are remembered, newest kept.
const UNMARKED_LIMIT: usize = 2000;
/// The hidden label that marks returned mail, made on first use.
async fn returned_mark(gmail: &impl Mail, account: &str) -> Result<String> {
    let find = |labels: &Value| -> Option<String> {
        labels
            .as_array()?
            .iter()
            .find(|label| label["rawName"].as_str().is_some_and(|name| name.eq_ignore_ascii_case(RETURNED_LABEL)))?["id"]
            .as_str()
            .filter(|id| safe_id(id))
            .map(str::to_owned)
    };
    if let Some(id) = find(&gmail.labels(account).await?) {
        return Ok(id);
    }
    match gmail.create_label(account, RETURNED_LABEL).await {
        Ok(created) => created["id"]
            .as_str()
            .filter(|id| safe_id(id))
            .map(str::to_owned)
            .ok_or("gmail_invalid_response"),
        // Invariant: Gmail refuses a duplicate name, so a label another Magpie made a moment ago
        // is found by listing again.
        Err(error) => find(&gmail.labels(account).await?).ok_or(error),
    }
}
#[derive(Clone, Debug, PartialEq)]
struct Slot {
    id: String,
    name: String,
    until: i64,
}
/// Magpie's slot labels in a labels listing, earliest first.
fn slots(labels: &Value) -> Vec<Slot> {
    let mut found: Vec<Slot> = labels
        .as_array()
        .into_iter()
        .flatten()
        .filter(|label| label["system"] != true)
        .filter_map(|label| {
            let id = label["id"].as_str().filter(|id| safe_id(id))?;
            let name = label["rawName"].as_str()?;
            Some(Slot {
                id: id.to_owned(),
                name: name.to_owned(),
                until: slot_time(name)?,
            })
        })
        .collect();
    found.sort_by(|a, b| (a.until, &a.id).cmp(&(b.until, &b.id)));
    found
}

/// Magpie's slot labels from a labels listing Gmail answered in full. A listing without Gmail's own
/// Inbox label is refused, so a broken answer never reads as every slot label deleted.
fn listing(labels: Result<Value>) -> Result<Vec<Slot>> {
    let labels = labels?;
    if !labels
        .as_array()
        .is_some_and(|all| all.iter().any(|label| label["id"] == "INBOX"))
    {
        return Err("gmail_invalid_response");
    }
    Ok(slots(&labels))
}

struct Thread {
    id: String,
    messages: Vec<Value>,
    subject: Value,
}
fn id_of(message: &Value) -> Option<&str> {
    message["id"].as_str().filter(|id| message_id(id))
}
/// When Gmail received a message, in milliseconds.
fn received(message: &Value) -> Option<i64> {
    let value = &message["internalDate"];
    value
        .as_str()
        .and_then(|text| text.parse().ok())
        .or_else(|| value.as_i64())
}
impl Thread {
    /// The thread's messages a snooze takes out of the Inbox: those `keep` allows, never mail in
    /// Trash or Spam.
    fn ids(&self, keep: impl Fn(&Value, &str) -> bool) -> Result<Vec<String>> {
        let ids: Vec<String> = self
            .messages
            .iter()
            .filter(|message| !binned(message))
            .filter_map(|message| id_of(message).filter(|id| keep(message, id)))
            .map(str::to_owned)
            .collect();
        if ids.is_empty() || ids.len() > 1000 {
            return Err("snooze_invalid_thread");
        }
        Ok(ids)
    }
    fn carries(&self, label: &str) -> bool {
        self.messages.iter().any(|message| has(message, label))
    }
}
/// The message's thread as Gmail reports it now; a caller's or the mirror's idea of the thread
/// is never used to choose what is changed.
async fn resolve(gmail: &impl Mail, account: &str, id: &str) -> Result<Thread> {
    let resource = gmail.read(account, id).await?;
    if has(&resource, "TRASH") || has(&resource, "SPAM") || has(&resource, "DRAFT") {
        return Err("snooze_invalid_folder");
    }
    let thread = resource["threadId"]
        .as_str()
        .filter(|thread| safe_id(thread))
        .ok_or("gmail_invalid_response")?;
    let messages = match gmail.thread(account, thread).await {
        Err("agent_context_too_large") => return Err("snooze_invalid_thread"),
        other => other?,
    };
    Ok(Thread {
        id: thread.to_owned(),
        messages,
        subject: crate::message::content::summarize(&resource, now())?["subject"].clone(),
    })
}

/// The slot label's id, creating it hidden when the account has none yet.
async fn ensure(gmail: &impl Mail, account: &str, name: &str, known: &[Slot]) -> Result<String> {
    let find = |known: &[Slot]| {
        known
            .iter()
            .find(|slot| slot.name.eq_ignore_ascii_case(name))
            .map(|slot| slot.id.clone())
    };
    if let Some(id) = find(known) {
        return Ok(id);
    }
    // Emptied due labels wait to be deleted, so only slots still to come count against the limit.
    if known.iter().filter(|slot| slot.until > now()).count() >= LABELS {
        return Err("snooze_limit");
    }
    match gmail.create_label(account, name).await {
        Ok(created) => created["id"]
            .as_str()
            .filter(|id| safe_id(id))
            .map(str::to_owned)
            .ok_or("gmail_invalid_response"),
        // Invariant: Gmail refuses a duplicate name, so a label another Magpie made a moment ago
        // is found by listing again, whatever the refusal said.
        Err(error) => find(&slots(&gmail.labels(account).await?)).ok_or(error),
    }
}

/// Labels the messages for their slot and takes them out of the Inbox in one change, so Gmail
/// never holds the thread half snoozed. An earlier Magpie slot on the thread is removed with it.
async fn settle(
    gmail: &impl Mail,
    account: &str,
    thread: &Thread,
    ids: &[String],
    name: &str,
    known: &[Slot],
) -> Result<String> {
    let label = ensure(gmail, account, name, known).await?;
    let mut remove = vec!["INBOX".to_owned()];
    remove.extend(
        known
            .iter()
            .filter(|slot| slot.id != label && thread.carries(&slot.id))
            .map(|slot| slot.id.clone())
            .take(99),
    );
    gmail.modify(account, ids, &[label.clone()], &remove).await?;
    Ok(label)
}

/// The slot Gmail had for this snooze as this device last saw it, kept on a snooze that has not
/// reached Gmail so a later change made on another device can be told apart from it.
fn seen(saved: &Map<String, Value>, key: &str, account: &str, thread: Option<&str>) -> Value {
    let row = saved.get(key).or_else(|| {
        thread.and_then(|thread| {
            saved
                .values()
                .find(|row| row["accountId"] == account && row["threadId"] == thread)
        })
    });
    match row {
        Some(row) if row["state"] == "sleeping" => row["label"].clone(),
        Some(row) => row["over"].clone(),
        None => Value::Null,
    }
}

/// The slot this device holds for a thread under a snooze other than `key`, as `seen` reads it.
fn held(account: &str, key: &str, thread: &str) -> Result<Option<String>> {
    let saved = rows()?;
    let found = saved.iter().find(|(other, row)| {
        other.as_str() != key && row["accountId"] == account && row["threadId"] == thread
    });
    Ok(found.and_then(|(other, _)| seen(&saved, other, account, None).as_str().map(str::to_owned)))
}

async fn snooze(gmail: &impl Mail, p: &Value) -> Result<Value> {
    fields(p, &["accountId", "id", "until", "subject", "action"])?;
    let action = match p.get("action") {
        None => None,
        Some(value) => Some(value.as_str().filter(|text| safe_id(text)).ok_or("invalid_params")?),
    };
    let account = account(p)?;
    let id = p["id"].as_str().ok_or("invalid_params")?;
    crate::mail::action::validate_message_id(crate::mail::Provider::Gmail, id)?;
    let shown = match p.get("subject") {
        None => String::new(),
        Some(value) => plain(value.as_str().ok_or("invalid_params")?),
    };
    let until = p["until"]
        .as_i64()
        .filter(|t| *t > now() + 1000 && *t < now() + 5 * 366 * 86_400_000)
        .ok_or("snooze_invalid_time")?;
    let (_, name) = slot(until)?;
    let key = store::key(&[&account, id]);
    let at = now();
    let resolved = tokio::time::timeout(RESOLVE_WITHIN, resolve(gmail, &account, id)).await;
    let thread = match resolved.unwrap_or(Err("gmail_timeout")) {
        Ok(thread) => thread,
        Err(error) if transient(error) => {
            // Invariant: An offline snooze is saved unresolved, with no thread or message ids,
            // until tick reads its thread from Gmail. It then snoozes only mail Gmail received
            // by `at`, when Dave chose it. The caller's subject is only displayed.
            let over = seen(&rows()?, &key, &account, None);
            record(
                &key,
                json!({"generation":random()?,"accountId":account,"id":id,"ids":[],"until":until,"state":"pending","subject":shown,"threadId":"","label":name,"at":at,"over":over}),
            )?;
            return Err("snooze_pending_retry");
        }
        Err(error) => return Err(error),
    };
    let ids = thread.ids(|_, _| true)?;
    let saved = rows()?;
    // Invariant: a snooze this one replaces has already taken its mail out of the Inbox, and Undo
    // must still return that mail.
    let replaced: Vec<&Value> = saved.values().filter(|row| row["accountId"] == *account && row["threadId"] == *thread.id).collect();
    let over = seen(&saved, &key, &account, Some(&thread.id));
    let generation = advance(&account, &thread.id)?;
    record(
        &key,
        json!({"generation":generation,"accountId":account,"id":id,"ids":ids,"until":until,"state":"pending","subject":thread.subject,"threadId":thread.id,"label":name,"at":at,"over":over,"action":action}),
    )?;
    let known = listing(gmail.labels(&account).await);
    // Invariant: sleeping mail can only be recognised from the labels, so without them nothing is
    // saved for Undo and the snooze cannot be undone.
    if let Ok(known) = &known {
        note_before(&key, before_this(&thread, known, action, &replaced))?;
    }
    let landed = match known {
        Ok(known) => settle(gmail, &account, &thread, &ids, &name, &known).await,
        Err(error) => Err(error),
    };
    match landed {
        Ok(label) => confirm(&key, &name, &label)?,
        Err("snooze_limit") => {
            forget(&key)?;
            return Err("snooze_limit");
        }
        // Invariant: On unknown mutation outcome, retain the durable pending record for
        // idempotent retry.
        Err(_) => return Err("snooze_pending_retry"),
    }
    Ok(json!({"ok":true,"until":until}))
}

/// Where a conversation's mail is just before a snooze, which Undo puts back: "inbox", the name of
/// the snooze already holding it, or "" for neither.
fn places(thread: &Thread, known: &[Slot]) -> Value {
    let places: Map<String, Value> = thread
        .messages
        .iter()
        .filter_map(|message| {
            let place = if has(message, "INBOX") {
                "inbox"
            } else {
                known.iter().rev().find(|slot| has(message, &slot.id)).map_or("", |slot| slot.name.as_str())
            };
            Some((id_of(message)?.to_owned(), json!(place)))
        })
        .collect();
    Value::Object(places)
}

/// What Undo puts back for this snooze.
/// Invariant: a bundle can snooze one conversation more than once in a single action, when a mail's
/// summary is not loaded, so Undo goes back to before the first snooze of that action.
fn before_this(thread: &Thread, known: &[Slot], action: Option<&str>, replaced: &[&Value]) -> Value {
    let mut before = places(thread, known);
    let earlier = action.and_then(|action| replaced.iter().find(|row| row["action"] == action));
    if let (Some(fields), Some(saved)) = (before.as_object_mut(), earlier.and_then(|row| row["before"].as_object())) {
        fields.extend(saved.clone());
    }
    before
}

/// Forgets what discovery last saw of a label.
/// Invariant: Undo can put mail back under a label discovery has just found empty, and an emptied
/// label is not listed again for days, so that mail would miss its time.
fn look_again(account: &str, label: &str) -> Result<()> {
    let marks_key = store::key(&["snooze-labels", account]);
    let mut marks = bookkeeping(&marks_key)?;
    for field in ["empty", "listed"] {
        if let Some(seen) = marks.get_mut(field).and_then(Value::as_object_mut) {
            seen.remove(label);
        }
    }
    store::write(&marks_key, &marks)
}

fn note_before(key: &str, before: Value) -> Result<()> {
    change(|rows| {
        if let Some(row) = rows.get_mut(key) {
            row["before"] = before;
        }
        Ok(())
    })
}

/// Applies a saved snooze Gmail has not confirmed. It snoozes only the mail Dave snoozed: the
/// messages saved with it, or for an offline snooze those Gmail received by then. It gives way
/// when the thread shows the snooze was changed on another device since.
async fn retry(gmail: &impl Mail, account: &str, key: &str, row: &Value, known: &[Slot]) -> Result<()> {
    let id = row["id"]
        .as_str()
        .filter(|id| message_id(id))
        .ok_or("inbox_storage_invalid")?;
    let until = row["until"].as_i64().ok_or("inbox_storage_invalid")?;
    let name = match row["label"].as_str() {
        Some(name) if slot_time(name).is_some() => name.to_owned(),
        _ => slot(until)?.1,
    };
    let thread = match resolve(gmail, account, id).await {
        Ok(thread) => thread,
        Err(error) if ended(error) => return forget(key),
        Err(error) => return Err(error),
    };
    let stored: Option<HashSet<&str>> = row["ids"]
        .as_array()
        .filter(|ids| !ids.is_empty())
        .map(|ids| ids.iter().filter_map(Value::as_str).collect());
    let at = row["at"].as_i64();
    let wanted = |message: &Value, mid: &str| match &stored {
        Some(stored) => stored.contains(mid),
        // Gmail's label-only reads carry internalDate (inference: the format documentation does
        // not list it). A message without one is snoozed with the rest, as before.
        None => mid == id || at.zip(received(message)).is_none_or(|(at, got)| got <= at),
    };
    let on_thread: Vec<&Slot> = known.iter().filter(|slot| thread.carries(&slot.id)).collect();
    let mut fresh = row.clone();
    settled(&mut fresh);
    fresh["threadId"] = json!(thread.id);
    fresh["subject"] = thread.subject.clone();
    fresh["label"] = json!(name);
    fresh["state"] = json!("pending");
    if let Some(own) = on_thread
        .iter()
        .find(|slot| slot.name.eq_ignore_ascii_case(&name))
    {
        // The earlier change reached Gmail; only its answer was lost.
        fresh["ids"] = json!(thread.ids(|message, mid| has(message, &own.id) || wanted(message, mid)).unwrap_or_default());
        record(key, fresh)?;
        return confirm(key, &name, &own.id);
    }
    // An offline snooze started from another message of a thread snoozed here saw that snooze, so
    // only a slot other than it counts as a later change.
    let over = match row["over"].as_str() {
        Some(over) => Some(over.to_owned()),
        None => held(account, key, &thread.id)?,
    };
    let over = over.as_deref();
    let changed = on_thread
        .iter()
        .any(|slot| over.is_none_or(|over| !slot.name.eq_ignore_ascii_case(over)));
    let woken_early =
        on_thread.is_empty() && over.and_then(slot_time).is_some_and(|due| due > now());
    if changed || woken_early {
        // Dave snoozed or returned this thread on another device after choosing this snooze
        // here, so that later choice stands.
        advance(account, &thread.id)?;
        forget(key)?;
        return Ok(());
    }
    let ids = match thread.ids(wanted) {
        Ok(ids) => ids,
        Err(_) => return forget(key),
    };
    fresh["generation"] = json!(advance(account, &thread.id)?);
    fresh["ids"] = json!(ids);
    record(key, fresh)?;
    match settle(gmail, account, &thread, &ids, &name, known).await {
        Ok(label) => confirm(key, &name, &label),
        Err("snooze_limit") => {
            forget(key)?;
            Err("snooze_limit")
        }
        Err(error) => Err(error),
    }
}

enum Woke {
    Done,
    Gone,
    Moved(Slot),
}
fn wanted_ids(row: &Value) -> Result<HashSet<&str>> {
    let ids = row["ids"].as_array().ok_or("inbox_storage_invalid")?;
    if ids.len() > 1000 {
        return Err("inbox_storage_invalid");
    }
    let mut wanted = HashSet::new();
    for id in ids {
        let id = id.as_str().ok_or("inbox_storage_invalid")?;
        crate::mail::action::validate_message_id(crate::mail::Provider::Gmail, id)?;
        wanted.insert(id);
    }
    Ok(wanted)
}
fn thread_of(row: &Value) -> Result<&str> {
    row["threadId"]
        .as_str()
        .filter(|thread| safe_id(thread))
        .ok_or("inbox_storage_invalid")
}
/// Returns a snoozed thread to the Inbox: the messages carrying a Magpie slot and those saved with
/// the snooze. A message already in the Inbox keeps its read state, and mail in Trash or Spam
/// only loses the slot label. A due wake leaves alone a thread Gmail shows returned or snoozed
/// again elsewhere; a chosen wake returns it from wherever it is.
async fn wake(
    gmail: &impl Mail,
    account: &str,
    row: &Value,
    chosen: bool,
    restore: bool,
    known: &[Slot],
) -> Result<Woke> {
    let wanted = wanted_ids(row)?;
    // Invariant: An unresolved snooze never reached Gmail, so there is nothing to return.
    if wanted.is_empty() {
        return Ok(Woke::Gone);
    }
    let messages = match gmail.thread(account, thread_of(row)?).await {
        Err("gmail_not_found") => return Ok(Woke::Gone),
        other => other?,
    };
    let on_thread: Vec<&Slot> = known
        .iter()
        .filter(|slot| messages.iter().any(|message| has(message, &slot.id)))
        .collect();
    if !chosen {
        let own = row["label"].as_str();
        // Invariant: Magpie deletes a due label only KEEP_DUE after its time, so an own label
        // missing sooner was deleted in Gmail and the mail saved with the snooze still returns.
        let deleted = own.is_some_and(|name| !known.iter().any(|slot| slot.name.eq_ignore_ascii_case(name)))
            && row["until"].as_i64().is_some_and(|until| until > now() - KEEP_DUE);
        match on_thread.last() {
            // Its label is off the thread, or went after Magpie's time to keep it: another Magpie
            // returned it.
            None if own.is_some() && !deleted => return Ok(Woke::Gone),
            Some(latest)
                if !own.is_some_and(|name| {
                    on_thread.iter().any(|slot| slot.name.eq_ignore_ascii_case(name))
                }) =>
            {
                return Ok(Woke::Moved((*latest).clone()));
            }
            _ => {}
        }
    }
    let remove: Vec<String> = on_thread
        .iter()
        .map(|slot| slot.id.clone())
        .take(100)
        .collect();
    let snoozed = |message: &Value| on_thread.iter().any(|slot| has(message, &slot.id));
    let before = |id: &str| row["before"].get(id).and_then(Value::as_str);
    let (mut back, mut clear) = (Vec::new(), Vec::new());
    let mut asleep: BTreeMap<&str, Vec<String>> = BTreeMap::new();
    for message in &messages {
        let Some(id) = id_of(message) else { continue };
        // Invariant: Undo touches only the mail its snooze saw; mail that arrived since stays as it is.
        if restore && before(id).is_none() {
            continue;
        }
        if binned(message) || has(message, "INBOX") {
            // Invariant: Mail in Trash or Spam loses the slot label but never returns to the Inbox.
            if snoozed(message) {
                clear.push(id.to_owned());
            }
        } else if restore && before(id) != Some("inbox") {
            // Invariant: Undo puts mail back as it was: mail in the Inbox returns, mail another
            // snooze held goes back to that snooze, and other mail only loses this label. Mail whose
            // earlier snooze label has gone returns, so nothing is left with neither.
            match before(id).filter(|place| !place.is_empty()) {
                None if snoozed(message) => clear.push(id.to_owned()),
                None => {}
                Some(place) => match known.iter().find(|slot| slot.name.eq_ignore_ascii_case(place)) {
                    Some(slot) => asleep.entry(slot.id.as_str()).or_default().push(id.to_owned()),
                    None => back.push(id.to_owned()),
                },
            }
        } else if snoozed(message) || wanted.contains(id) {
            back.push(id.to_owned());
        }
    }
    if !back.is_empty() {
        // Invariant: the mark never holds up a wake; a network failure retries the wake, and a
        // failure that would not go away returns the mail without the mark and says why.
        // Invariant: Undo puts mail back as it was, so it is neither unread nor marked as returned.
        let add = if restore {
            vec!["INBOX".to_owned()]
        } else {
            match returned_mark(gmail, account).await {
                Ok(mark) => vec!["INBOX".to_owned(), "UNREAD".to_owned(), mark],
                Err(error) if transient(error) => return Err(error),
                Err(error) => {
                    eprintln!("magpie: snooze return mark unavailable: {error}");
                    if let Err(error) = note_returned_unmarked(account, &back) {
                        eprintln!("magpie: snooze return not noted: {error}");
                    }
                    vec!["INBOX".to_owned(), "UNREAD".to_owned()]
                }
            }
        };
        gmail.modify(account, &back, &add, &remove).await?;
    }
    for (slot, ids) in asleep {
        let others: Vec<String> = remove.iter().filter(|label| *label != slot).cloned().collect();
        gmail.modify(account, &ids, &[slot.to_owned()], &others).await?;
        look_again(account, slot)?;
    }
    if !clear.is_empty() {
        gmail.modify(account, &clear, &[], &remove).await?;
    }
    Ok(if back.is_empty() { Woke::Gone } else { Woke::Done })
}

fn unmarked_key(account: &str) -> String {
    super::store::key(&["returned-unmarked", account])
}

/// Mail this device returned without its mark, which bundling must still never hide.
pub(super) fn returned_unmarked(account: &str) -> Result<HashSet<String>> {
    let saved = super::store::read(&unmarked_key(account))?.unwrap_or(Value::Null);
    Ok(saved.as_object().map(|ids| ids.keys().cloned().collect()).unwrap_or_default())
}

fn note_returned_unmarked(account: &str, ids: &[String]) -> Result<()> {
    let at = now();
    super::store::update(&unmarked_key(account), |saved| {
        if !saved.is_object() {
            *saved = json!({});
        }
        let known = saved.as_object_mut().ok_or("inbox_storage_invalid")?;
        for id in ids {
            known.insert(id.clone(), json!(at));
        }
        if known.len() > UNMARKED_LIMIT {
            let mut oldest: Vec<(i64, String)> = known.iter().map(|(id, when)| (when.as_i64().unwrap_or(0), id.clone())).collect();
            oldest.sort();
            for (_, id) in oldest.into_iter().take(known.len() - UNMARKED_LIMIT) {
                known.remove(&id);
            }
        }
        Ok(())
    })
}

/// Gives a snooze with no slot label its label, so every Magpie on the account sees it: one saved
/// by an older Magpie, or one whose label was deleted before its time. Only messages still out of
/// the Inbox are labelled; when none are, Dave already has the thread back and the snooze ends.
async fn upgrade(gmail: &impl Mail, account: &str, key: &str, row: &Value, known: &[Slot]) -> Result<()> {
    let wanted = wanted_ids(row)?;
    let thread = thread_of(row)?;
    let messages = match gmail.thread(account, thread).await {
        Err("gmail_not_found") => return forget(key),
        other => other?,
    };
    if let Some(latest) = known
        .iter()
        .filter(|slot| messages.iter().any(|message| has(message, &slot.id)))
        .next_back()
    {
        let generation = advance(account, thread)?;
        readopt(key, latest, &generation)?;
        return Ok(());
    }
    let back: Vec<String> = messages
        .iter()
        .filter(|message| !binned(message) && !has(message, "INBOX"))
        .filter_map(id_of)
        .filter(|id| wanted.contains(id))
        .map(str::to_owned)
        .collect();
    if back.is_empty() {
        advance(account, thread)?;
        forget(key)?;
        return Ok(());
    }
    let (_, name) = slot(row["until"].as_i64().ok_or("inbox_storage_invalid")?)?;
    let label = ensure(gmail, account, &name, known).await?;
    gmail.modify(account, &back, &[label.clone()], &[]).await?;
    change(|rows| {
        if let Some(row) = rows.get_mut(key) {
            row["label"] = json!(name);
            row["labelId"] = json!(label);
            settled(row);
        }
        Ok(())
    })
}

/// The row a chosen wake names: by its key, or by any message it holds, since a snooze found on
/// another device is kept under the first message Gmail listed.
fn row_for(account: &str, id: &str) -> Result<(String, Value)> {
    let mut saved = rows()?;
    let key = store::key(&[account, id]);
    if let Some(row) = saved.remove(&key) {
        return Ok((key, row));
    }
    saved
        .into_iter()
        .find(|(_, row)| {
            row["accountId"] == account
                && row["ids"]
                    .as_array()
                    .is_some_and(|ids| ids.iter().any(|saved| saved == id))
        })
        .ok_or("snooze_missing")
}

async fn wake_chosen(gmail: &impl Mail, p: &Value) -> Result<Value> {
    fields(p, &["accountId", "id", "restore"])?;
    let account = account(p)?;
    let id = p["id"].as_str().ok_or("invalid_params")?;
    crate::mail::action::validate_message_id(crate::mail::Provider::Gmail, id)?;
    let restore = match p.get("restore") {
        None => false,
        Some(value) => value.as_bool().ok_or("invalid_params")?,
    };
    let (key, row) = row_for(&account, id)?;
    // Invariant: Undo puts back what its snooze saw, so a snooze with no such record stays asleep
    // and returns at its time.
    if restore && !row["before"].is_object() && !wanted_ids(&row)?.is_empty() {
        return Err("snooze_undo_unavailable");
    }
    advance(&account, row["threadId"].as_str().ok_or("inbox_storage_invalid")?)?;
    // An unresolved snooze ends here without Gmail, so it can be cancelled offline.
    let known = if wanted_ids(&row)?.is_empty() {
        Vec::new()
    } else {
        listing(gmail.labels(&account).await)?
    };
    wake(gmail, &account, &row, true, restore, &known).await?;
    forget(&key)?;
    Ok(json!({"ok":true}))
}

/// Brings this device's mirror up to date with the account's slot labels in Gmail, at most once
/// a minute: snoozes made elsewhere are added, ended ones dropped, and due empty labels deleted.
async fn discover(
    gmail: &impl Mail,
    account: &str,
    reads: &mut usize,
    out_of_time: &impl Fn() -> bool,
) -> Result<()> {
    let marks_key = store::key(&["snooze-labels", account]);
    let mut marks = bookkeeping(&marks_key)?;
    let at = now();
    if marks["checked"]
        .as_i64()
        .is_some_and(|checked| checked > at - DISCOVER_EVERY && checked <= at)
    {
        return Ok(());
    }
    let known = listing(gmail.labels(account).await)?;
    marks["checked"] = json!(at);
    note(account)?;
    store::write(&marks_key, &marks)?;
    let ended: Vec<(String, i64, String)> = rows()?
        .into_iter()
        .filter(|(_, row)| {
            row["accountId"] == account
                && row["state"] == "sleeping"
                && row["labelId"]
                    .as_str()
                    .is_some_and(|id| !known.iter().any(|slot| slot.id == id))
        })
        .map(|(key, row)| {
            let until = row["until"].as_i64().unwrap_or(i64::MIN);
            (key, until, row["threadId"].as_str().unwrap_or("").to_owned())
        })
        .collect();
    for (key, until, thread) in ended {
        if until <= at - KEEP_DUE {
            // Magpie deletes a due label once it has kept it long enough after its thread came
            // back, so another Magpie returned it.
            advance(account, &thread)?;
            forget(&key)?;
        } else if until <= at {
            // A due label deleted sooner was deleted in Gmail; the wake returns the mail.
        } else {
            // A label deleted before its time does not end the snooze: the row returns by its
            // messages, and the next tick labels them again.
            change(|rows| {
                if let Some(fields) = rows.get_mut(&key).and_then(Value::as_object_mut) {
                    fields.remove("label");
                    fields.remove("labelId");
                }
                Ok(())
            })?;
        }
    }
    let listed = marks["listed"].as_object().cloned().unwrap_or_default();
    let empty = marks["empty"].as_object().cloned().unwrap_or_default();
    let last = |slot: &Slot| listed.get(&slot.id).and_then(Value::as_i64).unwrap_or(0);
    // An emptied due label is listed again only once it may be deleted, so labels kept after their
    // time never use up the listings that find snoozes made elsewhere.
    let mut chosen: Vec<&Slot> = known
        .iter()
        .filter(|slot| slot.until <= at)
        .filter(|slot| !empty.contains_key(&slot.id) || slot.until <= at - KEEP_DUE)
        .take(LISTS_PER_RUN)
        .collect();
    let mut stale: Vec<&Slot> = known
        .iter()
        .filter(|slot| slot.until > at)
        .take(LABELS)
        .filter(|slot| last(slot) <= at - RELIST_AFTER)
        .collect();
    stale.sort_by_key(|slot| last(slot));
    chosen.extend(
        stale
            .into_iter()
            .take(LISTS_PER_RUN.saturating_sub(chosen.len())),
    );
    let still = |id: &String| known.iter().any(|slot| &slot.id == id);
    let mut fresh: Map<String, Value> = listed.into_iter().filter(|(id, _)| still(id)).collect();
    let mut emptied: Map<String, Value> = empty.into_iter().filter(|(id, _)| still(id)).collect();
    let mut lists = LISTS_PER_RUN;
    for slot in chosen {
        if out_of_time() || lists == 0 {
            break;
        }
        let mut members: BTreeMap<String, Vec<String>> = BTreeMap::new();
        let (mut count, mut page) = (0, String::new());
        let complete = loop {
            lists -= 1;
            let answer = gmail.list(account, &slot.id, &page).await?;
            let ids = answer["ids"].as_array().ok_or("gmail_invalid_response")?;
            let threads = answer["threadIds"]
                .as_array()
                .ok_or("gmail_invalid_response")?;
            count += ids.len();
            for (id, thread) in ids.iter().zip(threads) {
                if let (Some(id), Some(thread)) = (id.as_str(), thread.as_str())
                    && message_id(id)
                    && safe_id(thread)
                {
                    members
                        .entry(thread.to_owned())
                        .or_default()
                        .push(id.to_owned());
                }
            }
            page = answer["nextPageToken"].as_str().unwrap_or("").to_owned();
            if page.is_empty() {
                break true;
            }
            if lists == 0 || out_of_time() || page.len() > 512 {
                break false;
            }
        };
        if count == 0 && complete && slot.until <= at {
            // Invariant: A due label is deleted only KEEP_DUE after its time, when it was empty on
            // two listings at least a minute apart and no snooze on this device still names it.
            // A label Gmail has not indexed yet is never taken off a sleeping thread, and a Magpie
            // that was off can tell a label Magpie removed from one deleted in Gmail.
            let named = rows()?
                .values()
                .any(|row| row["accountId"] == account && row["labelId"] == slot.id.as_str());
            match emptied.get(&slot.id).and_then(Value::as_i64) {
                Some(first)
                    if first <= at - DISCOVER_EVERY && slot.until <= at - KEEP_DUE && !named =>
                {
                    gmail.delete_label(account, &slot.id).await?;
                    fresh.remove(&slot.id);
                    emptied.remove(&slot.id);
                }
                Some(_) => {}
                None => {
                    emptied.insert(slot.id.clone(), json!(at));
                }
            }
        } else {
            emptied.remove(&slot.id);
            fresh.insert(slot.id.clone(), json!(at));
        }
        reconcile(gmail, account, slot, &members, complete, reads, out_of_time).await?;
    }
    marks["listed"] = Value::Object(fresh);
    marks["empty"] = Value::Object(emptied);
    store::write(&marks_key, &marks)
}

async fn reconcile(
    gmail: &impl Mail,
    account: &str,
    slot: &Slot,
    members: &BTreeMap<String, Vec<String>>,
    complete: bool,
    reads: &mut usize,
    out_of_time: &impl Fn() -> bool,
) -> Result<()> {
    let saved = rows()?;
    let mine = |row: &Value| row["accountId"] == account;
    if complete {
        // A thread missing from its slot's listing was returned or snoozed again elsewhere. The
        // thread itself is read first, so a listing that lags a new label never ends a snooze.
        for (key, row) in &saved {
            let thread = row["threadId"].as_str().unwrap_or("");
            if !mine(row)
                || row["state"] != "sleeping"
                || row["labelId"] != slot.id.as_str()
                || members.contains_key(thread)
            {
                continue;
            }
            if *reads == 0 || out_of_time() || !safe_id(thread) {
                break;
            }
            *reads -= 1;
            // Mail in Trash or Spam keeps no snooze, so a thread Dave binned leaves the list.
            let carried = match gmail.thread(account, thread).await {
                Ok(messages) => messages
                    .iter()
                    .any(|message| !binned(message) && has(message, &slot.id)),
                Err("gmail_not_found") => false,
                Err(_) => continue,
            };
            if !carried {
                advance(account, thread)?;
                forget(key)?;
            }
        }
    }
    for (thread, ids) in members {
        let existing = saved
            .iter()
            .find(|(_, row)| mine(row) && row["threadId"] == thread.as_str());
        match existing {
            Some((key, row)) => {
                // A pending row is settled by retry, which checks this slot against what Dave
                // saw when he chose it.
                if row["state"] == "sleeping" && row["labelId"] != slot.id.as_str() {
                    let generation = advance(account, thread)?;
                    readopt(key, slot, &generation)?;
                }
            }
            None if *reads > 0 && !out_of_time() => {
                *reads -= 1;
                let first = &ids[0];
                let subject = match gmail.read(account, first).await {
                    Ok(resource) => {
                        crate::message::content::summarize(&resource, now())?["subject"].clone()
                    }
                    Err(error) if transient(error) => return Err(error),
                    Err(_) => json!(""),
                };
                let generation = advance(account, thread)?;
                record(
                    &store::key(&[account, first]),
                    json!({"generation":generation,"accountId":account,"id":first,"ids":ids,"until":slot.until,"state":"sleeping","subject":subject,"threadId":thread,"label":slot.name,"labelId":slot.id}),
                )?;
            }
            None => {}
        }
    }
    Ok(())
}

/// Forgets the snoozes of accounts no longer signed in, with their bookkeeping; their labels stay
/// in Gmail for any other Magpie still signed in to them.
fn drop_accounts(accounts: &[String]) -> Result<()> {
    let signed_in = |id: &str| accounts.iter().any(|account| account == id);
    let registry = store::key(&["snooze-accounts"]);
    let noted: Vec<String> = store::read(&registry)
        .ok()
        .flatten()
        .unwrap_or_default()["accounts"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(Value::as_str)
        .map(str::to_owned)
        .collect();
    let mut gone: HashSet<String> = rows()?
        .values()
        .filter_map(|row| row["accountId"].as_str())
        .filter(|id| !signed_in(id))
        .map(str::to_owned)
        .collect();
    gone.extend(noted.iter().filter(|id| !signed_in(id)).cloned());
    if gone.is_empty() {
        return Ok(());
    }
    change(|rows| {
        rows.retain(|_, row| row["accountId"].as_str().is_some_and(signed_in));
        Ok(())
    })?;
    // Bookkeeping that cannot be removed now is tried again on the next tick; it never holds up
    // due mail.
    let mut cleared = true;
    for account in &gone {
        // Engines that still served paired phones also kept per-thread revisions for them.
        for kind in ["snooze-labels", "snooze-revisions"] {
            cleared &= store::remove(&store::key(&[kind, account])).is_ok();
        }
    }
    if cleared {
        let kept: Vec<String> = noted.into_iter().filter(|id| signed_in(id)).collect();
        let _ = store::replace(&registry, &json!({"accounts":kept}));
    }
    Ok(())
}

enum Work {
    Wake,
    Retry,
    Upgrade,
}

async fn tick(gmail: &impl Mail, seconds: u64) -> Result<Value> {
    let started = Instant::now();
    let budget = Duration::from_secs(seconds);
    let out_of_time = || started.elapsed() >= budget;
    let accounts = gmail.accounts().await?;
    drop_accounts(&accounts)?;
    let is_due = |row: &Value| row["until"].as_i64().is_none_or(|until| until <= now());
    // Invariant: An unresolved snooze whose time passed never reached Gmail, so it ends here.
    change(|rows| {
        rows.retain(|_, row| !(is_due(row) && row["ids"].as_array().is_some_and(Vec::is_empty)));
        Ok(())
    })?;
    let mut waiting: Vec<(String, Value)> = rows()?
        .into_iter()
        .filter(|(_, row)| !row["retryAt"].as_i64().is_some_and(|at| at > now()))
        .collect();
    waiting.sort_by_key(|(_, row)| row["until"].as_i64().unwrap_or(i64::MAX));
    let mut known: BTreeMap<String, Vec<Slot>> = BTreeMap::new();
    let (mut woke, mut work) = (0, 0);
    // Due mail comes back first; discovery uses the time left, so a short tick still returns it.
    for (key, row) in waiting {
        if work >= WORK_PER_RUN || out_of_time() {
            break;
        }
        let account = row["accountId"].as_str().ok_or("inbox_storage_invalid")?;
        let thread = row["threadId"].as_str().ok_or("inbox_storage_invalid")?;
        let due = row["until"].as_i64().ok_or("inbox_storage_invalid")? <= now();
        let job = if due {
            Work::Wake
        } else if row["state"] == "pending" {
            Work::Retry
        } else if row["label"].is_null() {
            Work::Upgrade
        } else {
            continue;
        };
        work += 1;
        if !known.contains_key(account) {
            match listing(gmail.labels(account).await) {
                Ok(slots) => {
                    known.insert(account.to_owned(), slots);
                }
                Err(error) => {
                    defer(&key, error)?;
                    continue;
                }
            }
        }
        let slots = &known[account];
        let outcome = match job {
            Work::Wake => match wake(gmail, account, &row, false, false, slots).await {
                Ok(Woke::Moved(slot)) => advance(account, thread)
                    .and_then(|generation| readopt(&key, &slot, &generation)),
                Ok(outcome) => {
                    woke += matches!(outcome, Woke::Done) as u64;
                    advance(account, thread).and_then(|_| forget(&key))
                }
                Err(error) => Err(error),
            },
            Work::Retry => retry(gmail, account, &key, &row, slots).await,
            Work::Upgrade => upgrade(gmail, account, &key, &row, slots).await,
        };
        if !matches!(job, Work::Wake) {
            // Either may have made a label, so the next row lists them again.
            known.remove(account);
        }
        if let Err(error) = outcome {
            defer(&key, error)?;
        }
    }
    let mut reads = READS_PER_RUN;
    for account in accounts.iter().take(32) {
        if out_of_time() {
            break;
        }
        // Discovery is retried on the next tick; a failure here never blocks due wakes.
        let _ = discover(gmail, account, &mut reads, &out_of_time).await;
    }
    // Invariant: `failures` counts due snoozes still held back after a failed attempt, including
    // those waiting out a pause, so "could not return yet" stays shown until their mail is back.
    let behind = rows()?
        .values()
        .filter(|row| is_due(row) && row["attempts"].as_u64().is_some_and(|n| n > 0))
        .count();
    Ok(json!({"woke":woke,"failures":behind}))
}

pub(super) async fn call(method: &str, p: &Value, gmail: &impl Mail) -> Result<Value> {
    match method {
        "inbox.tick" => {
            fields(p, &["seconds"])?;
            let seconds = match p.get("seconds") {
                None => MAX_SECONDS,
                Some(value) => value
                    .as_u64()
                    .filter(|seconds| (1..=MAX_SECONDS).contains(seconds))
                    .ok_or("invalid_params")?,
            };
            tick(gmail, seconds).await
        }
        "inbox.wake" => wake_chosen(gmail, p).await,
        _ => snooze(gmail, p).await,
    }
}

#[cfg(test)]
#[path = "snooze_tests.rs"]
mod tests;
