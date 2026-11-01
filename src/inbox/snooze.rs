//! Snooze keeps its schedule in Gmail. A snoozed thread carries a hidden label named for its
//! five-minute wake slot, such as `Magpie-snooze-2026-11-02-0500-UTC`, so every Magpie signed in
//! to the account (desktop, iPhone, iPad) can list and wake it, whichever runs first.
//! `snoozes.json` mirrors those labels on this device: it answers snapshots offline and holds
//! snoozes Gmail has not confirmed yet. Per-thread revisions keep paired phone requests ordered.
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
    fn list(&self, account: &str, label: &str) -> impl Future<Output = Result<Value>> + Send;
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
        self.call("gmail.labels", &json!({"accountId":account}))
            .await
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
        self.call_settled(
            "gmail.batchModify",
            &json!({"accountId":account,"ids":ids,"addLabelIds":add,"removeLabelIds":remove}),
        )
        .await
        .map(|_| ())
    }
    async fn list(&self, account: &str, label: &str) -> Result<Value> {
        self.call(
            "gmail.list",
            &json!({"accountId":account,"query":"","pageSize":100,"labelId":label}),
        )
        .await
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
            .take(32)
            .map(str::to_owned)
            .collect())
    }
}

pub(super) fn revisions(account: &str) -> Result<Value> {
    Ok(store::read(&store::key(&["snooze-revisions", account]))?.unwrap_or(json!({})))
}
#[cfg(test)]
pub(super) fn advance(account: &str, thread: &str) -> Result<String> {
    advance_operation(account, thread, None)
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
fn advance_operation(account: &str, thread: &str, operation: Option<&str>) -> Result<String> {
    if thread.is_empty() {
        return random();
    }
    if let Some(operation) = operation {
        let versions = revisions(account)?;
        if versions[thread]["operationId"] == operation {
            return versions[thread]["revision"]
                .as_str()
                .map(str::to_owned)
                .ok_or("inbox_storage_invalid");
        }
    }
    let generation = random()?;
    store::update(&store::key(&["snooze-revisions", account]), |saved| {
        let records = saved.as_object_mut().ok_or("inbox_storage_invalid")?;
        records.retain(|_, v| {
            v["updated"]
                .as_i64()
                .is_some_and(|t| t > now() - 31 * 86_400_000)
        });
        records.insert(
            thread.to_owned(),
            json!({"revision":generation,"updated":now(),"operationId":operation}),
        );
        Ok(())
    })?;
    Ok(generation)
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
fn confirm(key: &str, name: &str, label: &str) -> Result<()> {
    change(|rows| {
        if let Some(row) = rows.get_mut(key).filter(|row| row["label"] == name) {
            row["state"] = json!("sleeping");
            row["labelId"] = json!(label);
        }
        Ok(())
    })
}
fn readopt(key: &str, slot: &Slot) -> Result<()> {
    change(|rows| {
        if let Some(row) = rows.get_mut(key) {
            row["label"] = json!(slot.name);
            row["labelId"] = json!(slot.id);
            row["until"] = json!(slot.until);
            row["state"] = json!("sleeping");
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
            | "session_failed"
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

struct Thread {
    id: String,
    ids: Vec<String>,
    labels: HashSet<String>,
    subject: Value,
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
    let ids: Vec<String> = messages
        .iter()
        .filter(|message| !binned(message))
        .filter_map(|message| message["id"].as_str())
        .filter(|id| message_id(id))
        .map(str::to_owned)
        .collect();
    if ids.is_empty() || ids.len() > 1000 {
        return Err("snooze_invalid_thread");
    }
    let labels = messages
        .iter()
        .flat_map(|message| message["labelIds"].as_array().into_iter().flatten())
        .filter_map(Value::as_str)
        .map(str::to_owned)
        .collect();
    Ok(Thread {
        id: thread.to_owned(),
        ids,
        labels,
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
    if known.len() >= LABELS {
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

/// Labels the thread for its slot and takes it out of the Inbox in one change, so Gmail never
/// holds it half snoozed. An earlier Magpie slot on the thread is removed in the same change.
async fn settle(gmail: &impl Mail, account: &str, thread: &Thread, name: &str) -> Result<String> {
    let known = slots(&gmail.labels(account).await?);
    let label = ensure(gmail, account, name, &known).await?;
    let mut remove = vec!["INBOX".to_owned()];
    remove.extend(
        known
            .iter()
            .filter(|slot| slot.id != label && thread.labels.contains(&slot.id))
            .map(|slot| slot.id.clone())
            .take(99),
    );
    gmail
        .modify(account, &thread.ids, &[label.clone()], &remove)
        .await?;
    Ok(label)
}

async fn snooze(gmail: &impl Mail, p: &Value, operation: Option<&str>) -> Result<Value> {
    fields(p, &["accountId", "id", "until", "subject"])?;
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
    let thread = match resolve(gmail, &account, id).await {
        Ok(thread) => thread,
        Err(error) if transient(error) => {
            // Invariant: An offline snooze is saved unresolved, with no thread or message ids,
            // until tick reads its thread from Gmail. The caller's subject is only displayed.
            record(
                &key,
                json!({"generation":random()?,"operationId":operation,"accountId":account,"id":id,"ids":[],"until":until,"state":"pending","subject":shown,"threadId":"","label":name}),
            )?;
            return Err("snooze_pending_retry");
        }
        Err(error) => return Err(error),
    };
    let generation = advance_operation(&account, &thread.id, operation)?;
    record(
        &key,
        json!({"generation":generation,"operationId":operation,"accountId":account,"id":id,"ids":thread.ids,"until":until,"state":"pending","subject":thread.subject,"threadId":thread.id,"label":name}),
    )?;
    match settle(gmail, &account, &thread, &name).await {
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

/// Applies a saved snooze Gmail has not confirmed, reading its thread again first.
async fn retry(gmail: &impl Mail, account: &str, key: &str, row: &Value) -> Result<()> {
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
        Err(error) if transient(error) => return Err(error),
        Err(error) => {
            forget(key)?;
            return Err(error);
        }
    };
    let mut fresh = row.clone();
    fresh["generation"] = json!(advance_operation(
        account,
        &thread.id,
        row["operationId"].as_str()
    )?);
    fresh["ids"] = json!(thread.ids);
    fresh["threadId"] = json!(thread.id);
    fresh["subject"] = thread.subject.clone();
    fresh["label"] = json!(name);
    fresh["state"] = json!("pending");
    record(key, fresh)?;
    match settle(gmail, account, &thread, &name).await {
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
/// Returns a snoozed thread to the Inbox. A due wake leaves alone a thread Gmail shows already
/// returned, or snoozed again elsewhere; a chosen wake returns it from any Magpie slot.
async fn wake(gmail: &impl Mail, account: &str, row: &Value, chosen: bool) -> Result<Woke> {
    let ids = row["ids"].as_array().ok_or("inbox_storage_invalid")?;
    // Invariant: An unresolved snooze never reached Gmail, so there is nothing to return.
    if ids.is_empty() {
        return Ok(Woke::Gone);
    }
    if ids.len() > 1000 {
        return Err("inbox_storage_invalid");
    }
    let mut wanted = HashSet::new();
    for id in ids {
        let id = id.as_str().ok_or("inbox_storage_invalid")?;
        crate::mail::action::validate_message_id(crate::mail::Provider::Gmail, id)?;
        wanted.insert(id);
    }
    let thread = row["threadId"]
        .as_str()
        .filter(|thread| safe_id(thread))
        .ok_or("inbox_storage_invalid")?;
    let messages = gmail.thread(account, thread).await?;
    fn id_of<'a>(message: &&'a Value) -> Option<&'a str> {
        message["id"].as_str().filter(|id| message_id(id))
    }
    let Some(name) = row["label"].as_str() else {
        // A snooze saved before labels, or by an older Magpie, returns by its message ids.
        let back: Vec<String> = messages
            .iter()
            .filter(|message| !binned(message))
            .filter_map(|message| id_of(&message))
            .filter(|id| wanted.contains(id))
            .map(str::to_owned)
            .collect();
        if !back.is_empty() {
            gmail
                .modify(account, &back, &["INBOX".into(), "UNREAD".into()], &[])
                .await?;
        }
        return Ok(Woke::Done);
    };
    let known = slots(&gmail.labels(account).await?);
    let on_thread: Vec<&Slot> = known
        .iter()
        .filter(|slot| messages.iter().any(|message| has(message, &slot.id)))
        .collect();
    let Some(latest) = on_thread.last() else {
        return Ok(Woke::Gone);
    };
    if !chosen
        && !on_thread
            .iter()
            .any(|slot| slot.name.eq_ignore_ascii_case(name))
    {
        return Ok(Woke::Moved((*latest).clone()));
    }
    let remove: Vec<String> = on_thread
        .iter()
        .map(|slot| slot.id.clone())
        .take(100)
        .collect();
    let snoozed = |message: &Value| on_thread.iter().any(|slot| has(message, &slot.id));
    let (back, rest): (Vec<&Value>, Vec<&Value>) = messages
        .iter()
        .filter(|message| snoozed(message) || id_of(message).is_some_and(|id| wanted.contains(id)))
        .partition(|message| !binned(message));
    let back: Vec<String> = back.iter().filter_map(id_of).map(str::to_owned).collect();
    let rest: Vec<String> = rest.iter().filter_map(id_of).map(str::to_owned).collect();
    if !back.is_empty() {
        gmail
            .modify(account, &back, &["INBOX".into(), "UNREAD".into()], &remove)
            .await?;
    }
    // Invariant: Mail in Trash or Spam loses the slot label but never returns to the Inbox.
    if !rest.is_empty() {
        gmail.modify(account, &rest, &[], &remove).await?;
    }
    Ok(Woke::Done)
}

async fn wake_chosen(gmail: &impl Mail, p: &Value, operation: Option<&str>) -> Result<Value> {
    fields(p, &["accountId", "id"])?;
    let account = account(p)?;
    let id = p["id"].as_str().ok_or("invalid_params")?;
    crate::mail::action::validate_message_id(crate::mail::Provider::Gmail, id)?;
    let key = store::key(&[&account, id]);
    let row = rows()?.remove(&key).ok_or("snooze_missing")?;
    advance_operation(
        &account,
        row["threadId"].as_str().ok_or("inbox_storage_invalid")?,
        operation,
    )?;
    wake(gmail, &account, &row, true).await?;
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
    let mut marks = store::read(&marks_key)?
        .filter(Value::is_object)
        .unwrap_or(json!({}));
    let at = now();
    if marks["checked"]
        .as_i64()
        .is_some_and(|checked| checked > at - DISCOVER_EVERY && checked <= at)
    {
        return Ok(());
    }
    let known = slots(&gmail.labels(account).await?);
    marks["checked"] = json!(at);
    store::write(&marks_key, &marks)?;
    let ended: Vec<(String, String)> = rows()?
        .into_iter()
        .filter(|(_, row)| {
            row["accountId"] == account
                && row["state"] == "sleeping"
                && row["labelId"]
                    .as_str()
                    .is_some_and(|id| !known.iter().any(|slot| slot.id == id))
        })
        .map(|(key, row)| (key, row["threadId"].as_str().unwrap_or("").to_owned()))
        .collect();
    for (key, thread) in ended {
        forget(&key)?;
        advance_operation(account, &thread, None)?;
    }
    let listed = marks["listed"].as_object().cloned().unwrap_or_default();
    let last = |slot: &Slot| listed.get(&slot.id).and_then(Value::as_i64).unwrap_or(0);
    let mut chosen: Vec<&Slot> = known
        .iter()
        .filter(|slot| slot.until <= at)
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
    let mut fresh: Map<String, Value> = listed
        .iter()
        .filter(|(id, _)| known.iter().any(|slot| &slot.id == *id))
        .map(|(id, time)| (id.clone(), time.clone()))
        .collect();
    for slot in chosen {
        if out_of_time() {
            break;
        }
        let page = gmail.list(account, &slot.id).await?;
        let ids = page["ids"].as_array().ok_or("gmail_invalid_response")?;
        let threads = page["threadIds"]
            .as_array()
            .ok_or("gmail_invalid_response")?;
        let complete = page["nextPageToken"].as_str().is_none_or(str::is_empty);
        let mut members: BTreeMap<String, Vec<String>> = BTreeMap::new();
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
        if ids.is_empty() && slot.until <= at {
            gmail.delete_label(account, &slot.id).await?;
            fresh.remove(&slot.id);
        } else {
            fresh.insert(slot.id.clone(), json!(at));
        }
        reconcile(gmail, account, slot, &members, complete, reads).await?;
    }
    marks["listed"] = Value::Object(fresh);
    store::write(&marks_key, &marks)
}

async fn reconcile(
    gmail: &impl Mail,
    account: &str,
    slot: &Slot,
    members: &BTreeMap<String, Vec<String>>,
    complete: bool,
    reads: &mut usize,
) -> Result<()> {
    let saved = rows()?;
    let mine = |row: &Value| row["accountId"] == account;
    if complete {
        // A thread that no longer carries its slot was returned or snoozed again elsewhere.
        for (key, row) in &saved {
            let thread = row["threadId"].as_str().unwrap_or("");
            if mine(row)
                && row["state"] == "sleeping"
                && row["labelId"] == slot.id.as_str()
                && !members.contains_key(thread)
            {
                forget(key)?;
                advance_operation(account, thread, None)?;
            }
        }
    }
    for (thread, ids) in members {
        let existing = saved
            .iter()
            .find(|(_, row)| mine(row) && row["threadId"] == thread.as_str());
        match existing {
            Some((key, row)) => {
                // A pending row is this device's newer choice and wins when it lands.
                if row["state"] == "sleeping" && row["labelId"] != slot.id.as_str() {
                    readopt(key, slot)?;
                    advance_operation(account, thread, None)?;
                }
            }
            None if *reads > 0 => {
                *reads -= 1;
                let first = &ids[0];
                let subject = match gmail.read(account, first).await {
                    Ok(resource) => {
                        crate::message::content::summarize(&resource, now())?["subject"].clone()
                    }
                    Err(error) if transient(error) => return Err(error),
                    Err(_) => json!(""),
                };
                let generation = advance_operation(account, thread, None)?;
                record(
                    &store::key(&[account, first]),
                    json!({"generation":generation,"operationId":null,"accountId":account,"id":first,"ids":ids,"until":slot.until,"state":"sleeping","subject":subject,"threadId":thread,"label":slot.name,"labelId":slot.id}),
                )?;
            }
            None => {}
        }
    }
    Ok(())
}

async fn tick(gmail: &impl Mail, seconds: u64) -> Result<Value> {
    let started = Instant::now();
    let budget = Duration::from_secs(seconds);
    let out_of_time = || started.elapsed() >= budget;
    let accounts = gmail.accounts().await?;
    // Snoozes of accounts no longer signed in are forgotten here; their labels stay in Gmail.
    if rows()?.values().any(|row| {
        !accounts
            .iter()
            .any(|account| row["accountId"] == account.as_str())
    }) {
        change(|rows| {
            rows.retain(|_, row| {
                accounts
                    .iter()
                    .any(|account| row["accountId"] == account.as_str())
            });
            Ok(())
        })?;
    }
    let mut reads = READS_PER_RUN;
    for account in &accounts {
        if out_of_time() {
            break;
        }
        // Discovery is retried on the next tick; a failure here never blocks due wakes.
        let _ = discover(gmail, account, &mut reads, &out_of_time).await;
    }
    let mut waiting: Vec<(String, Value)> = rows()?.into_iter().collect();
    waiting.sort_by_key(|(_, row)| row["until"].as_i64().unwrap_or(i64::MAX));
    let (mut woke, mut failures, mut work) = (0, 0, 0);
    for (key, row) in waiting {
        if work >= WORK_PER_RUN || out_of_time() {
            break;
        }
        let account = row["accountId"].as_str().ok_or("inbox_storage_invalid")?;
        let thread = row["threadId"].as_str().ok_or("inbox_storage_invalid")?;
        if row["until"].as_i64().ok_or("inbox_storage_invalid")? <= now() {
            work += 1;
            match wake(gmail, account, &row, false).await {
                Ok(Woke::Moved(slot)) => readopt(&key, &slot)?,
                Ok(outcome) => {
                    forget(&key)?;
                    woke += matches!(outcome, Woke::Done) as u64;
                }
                Err(_) => {
                    failures += 1;
                    continue;
                }
            }
            advance_operation(account, thread, None)?;
        } else if row["state"] == "pending" {
            work += 1;
            // A failed retry stays pending for the next tick, or is dropped when Gmail shows
            // the message can no longer be snoozed.
            let _ = retry(gmail, account, &key, &row).await;
        }
    }
    Ok(json!({"woke":woke,"failures":failures}))
}

pub(super) async fn call(method: &str, p: &Value, gmail: &impl Mail) -> Result<Value> {
    call_with_operation(method, p, gmail, None).await
}
pub(super) async fn call_with_operation(
    method: &str,
    p: &Value,
    gmail: &impl Mail,
    operation: Option<&str>,
) -> Result<Value> {
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
        "inbox.wake" => wake_chosen(gmail, p, operation).await,
        _ => snooze(gmail, p, operation).await,
    }
}

#[cfg(test)]
#[path = "snooze_tests.rs"]
mod tests;
