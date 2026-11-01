mod avatars;
#[cfg(test)]
include!("readiness_tests.rs");
#[cfg(any(all(feature = "agent", unix, not(target_os = "ios")), feature = "mobile"))]
mod context;
#[cfg(any(all(feature = "agent", unix, not(target_os = "ios")), feature = "mobile"))]
pub(crate) mod describe;
#[cfg(any(feature = "mobile", test))]
pub(crate) mod claude;
#[cfg(all(test, feature = "agent", unix, not(target_os = "ios")))]
mod overview_tests;
#[cfg(target_os = "linux")]
mod phone;
mod snooze;
mod store;
use serde_json::{Value, json};
use std::sync::Arc;
use tokio::sync::{Mutex, Semaphore};

/// Desktop writes descriptions through the local AI agent; the iPhone through its own Claude API key.
#[cfg(all(feature = "agent", unix, not(target_os = "ios")))]
mod writer {
    pub(super) async fn ready() -> Result<(), &'static str> {
        Ok(())
    }
    pub(super) async fn generate(messages: &serde_json::Value) -> Result<serde_json::Value, &'static str> {
        crate::agent::overview::generate(messages).await
    }
}
#[cfg(all(feature = "mobile", not(all(feature = "agent", unix, not(target_os = "ios")))))]
mod writer {
    pub(super) use super::claude::{generate, ready};
}

pub struct Inbox {
    overview_slots: Arc<Semaphore>,
    avatar_slots: Arc<Semaphore>,
    snooze_lock: Mutex<()>,
}
impl Default for Inbox {
    fn default() -> Self {
        Self {
            overview_slots: Arc::new(Semaphore::new(1)),
            avatar_slots: Arc::new(Semaphore::new(3)),
            snooze_lock: Mutex::new(()),
        }
    }
}
pub fn now() -> i64 {
    chrono::Utc::now().timestamp_millis()
}
fn account(params: &Value) -> Result<String, &'static str> {
    let value = params["accountId"]
        .as_str()
        .filter(|s| !s.is_empty())
        .ok_or("invalid_params")?;
    Ok(crate::mail::resolve_account(value)?.id)
}
fn ids(params: &Value) -> Result<Vec<String>, &'static str> {
    let values = params["ids"]
        .as_array()
        .filter(|v| !v.is_empty() && v.len() <= 4)
        .ok_or("invalid_params")?;
    let mut result = Vec::new();
    for value in values {
        let id = value.as_str().ok_or("invalid_params")?;
        crate::mail::action::validate_message_id(crate::mail::Provider::Gmail, id)?;
        if result.iter().any(|v| v == id) {
            return Err("invalid_params");
        }
        result.push(id.to_owned());
    }
    Ok(result)
}
fn fields(params: &Value, allowed: &[&str]) -> Result<(), &'static str> {
    if !params
        .as_object()
        .is_some_and(|p| p.keys().all(|k| allowed.contains(&k.as_str())))
    {
        return Err("invalid_params");
    }
    Ok(())
}
impl Inbox {
    #[cfg(all(feature = "agent", unix, not(target_os = "ios")))]
    pub(crate) async fn prepare(
        &self,
        account: &str,
        gmail: Arc<crate::providers::gmail::Session>,
        local_mail: Arc<crate::local_mail::LocalMail>,
    ) -> Result<(), &'static str> {
        if self.overview_slots.available_permits() == 0 {
            return Ok(());
        }
        let prefs = preferences(account)?;
        if prefs["paused"] == true {
            return Ok(());
        }
        let candidates = local_mail.overview_candidates(account).await?;
        let saved = store::read(&store::key(&["overviews", account]))?.unwrap_or(json!({}));
        let ids: Vec<_> = candidates
            .into_iter()
            .filter(|id| overview_due(&saved[id], false, now()))
            .take(4)
            .collect();
        if ids.is_empty() {
            return Ok(());
        }
        self.call("inbox.overviews", &json!({"accountId":account,"ids":ids,"allowRemoteImages":prefs["allowRemoteImages"] == true}), gmail, local_mail).await?;
        Ok(())
    }
    /// Claims the requested messages and writes their descriptions in a background task.
    /// With a limit the caller waits up to that long, as the iPhone's background refresh must.
    #[cfg(any(all(feature = "agent", unix, not(target_os = "ios")), feature = "mobile"))]
    #[allow(clippy::too_many_arguments)]
    async fn request_overviews(
        &self,
        account: String,
        ids: Vec<String>,
        retry: bool,
        remote: bool,
        gmail: Arc<crate::providers::gmail::Session>,
        local_mail: Arc<crate::local_mail::LocalMail>,
        limit: Option<std::time::Duration>,
    ) -> Result<Value, &'static str> {
        // Invariant: a writer that cannot take requests now refuses before any mail is claimed, and says why.
        if let Err(problem) = writer::ready().await {
            return Ok(json!({"accepted":false,"problem":problem}));
        }
        let Ok(permit) = self.overview_slots.clone().try_acquire_owned() else {
            return Ok(json!({"accepted":false}));
        };
        let name = store::key(&["overviews", &account]);
        let settings = preferences(&account)?;
        let remote = remote
            && (settings["configured"] != true
                || settings["allowRemoteImages"] == true);
        if settings["paused"] == true {
            return Ok(json!({"accepted":false}));
        }
        let claimed_at = now();
        let (incarnation, chosen) = crate::account::with_incarnation(None, |token| {
            crate::mail::resolve_account(&account)?;
            let chosen = store::update(&name, |saved| {
                claim_overviews(saved, &ids, retry, claimed_at)
            })?;
            Ok((token, chosen))
        })?;
        if chosen.is_empty() {
            return Ok(json!({"accepted":true}));
        }
        let task = tokio::spawn(async move {
            let _permit = permit;
            let result =
                overview_batch(&account, &chosen, &gmail, &local_mail, remote).await;
            let Ok(protected) = local_mail.overview_candidates(&account).await else {
                return;
            };
            let protected: std::collections::HashSet<_> =
                protected.into_iter().collect();
            let completed =
                crate::account::with_incarnation(Some(&incarnation), |_| {
                    crate::mail::resolve_account(&account)?;
                    store::update(&name, |saved| {
                        let current: Vec<_> = chosen
                            .into_iter()
                            .filter(|id| {
                                overview_claimed(&saved[id], claimed_at)
                            })
                            .collect();
                        finish_overviews_protected(saved, &current, &result, &protected)
                    })
                });
            if completed == Err("overview_account_changed") {
                let _ = crate::account::with_incarnation(None, |_| {
                    crate::mail::resolve_account(&account)?;
                    if store::read(&name)?.is_none() {
                        return Ok(());
                    }
                    store::update(&name, |saved| {
                        for id in &ids {
                            if overview_claimed(&saved[id], claimed_at) {
                                if overview_current(&saved[id], now()) {
                                    saved[id]["rewriteState"] = json!("failed");
                                    saved[id]["rewriteAt"] = json!(0);
                                } else {
                                    saved[id] = json!({"state":"failed","version":2,"updated":0,"reason":"Account settings changed; preparation will retry"});
                                }
                            }
                        }
                        Ok(())
                    })
                });
            }
        });
        if let Some(limit) = limit {
            let finished = tokio::time::timeout(limit, task).await.is_ok();
            return Ok(json!({"accepted":true,"finished":finished}));
        }
        Ok(json!({"accepted":true}))
    }
    /// Retry on the phone: every failed message in the account may be asked about again, so ones
    /// not asked in this batch are asked by the following ones instead of waiting for another Retry.
    #[cfg(feature = "mobile")]
    pub(crate) fn forgive_failed(&self, account: &str) -> Result<(), &'static str> {
        crate::account::with_incarnation(None, |_| {
            let account = crate::mail::resolve_account(account)?.id;
            store::update(&store::key(&["overviews", &account]), forgive_attempts)
        })
    }
    /// The saved descriptions for one page of the app's mail.
    #[cfg(feature = "mobile")]
    pub(crate) fn overview_page(&self, account: &str, ids: &[&str]) -> Result<Value, &'static str> {
        let account = crate::mail::resolve_account(account)?.id;
        let saved = store::read(&store::key(&["overviews", &account]))?.unwrap_or(json!({}));
        let saved = saved.as_object().ok_or("inbox_storage_invalid")?;
        let mut page = serde_json::Map::new();
        for id in ids {
            if let Some(row) = saved.get(*id) {
                page.insert((*id).to_owned(), row.clone());
            }
        }
        Ok(json!({"overviews":overview_snapshot(Value::Object(page), now())?,"preferences":preferences(&account)?}))
    }
    /// The iPhone's background refresh: describe the app's chosen Inbox mail still waiting, within a time limit.
    #[cfg(feature = "mobile")]
    pub(crate) async fn describe_waiting(
        &self,
        account: &str,
        ids: &[String],
        gmail: Arc<crate::providers::gmail::Session>,
        local_mail: Arc<crate::local_mail::LocalMail>,
        limit: std::time::Duration,
    ) -> Result<Value, &'static str> {
        let saved = store::read(&store::key(&["overviews", account]))?.unwrap_or(json!({}));
        // Invariant: the app names more messages than are described, so messages that failed or are
        // still running never hold back the ones behind them.
        let due: Vec<String> = ids.iter().filter(|id| overview_due(&saved[id.as_str()], false, now())).take(4).cloned().collect();
        let mut finished = json!(true);
        if !due.is_empty() {
            let prefs = preferences(account)?;
            let outcome = self
                .request_overviews(account.to_owned(), due, false, prefs["allowRemoteImages"] == true, gmail, local_mail, Some(limit))
                .await?;
            finished = outcome["finished"].clone();
        }
        let saved = overview_snapshot(store::read(&store::key(&["overviews", account]))?.unwrap_or(json!({})), now())?;
        let rows: serde_json::Map<String, Value> = ids
            .iter()
            .filter_map(|id| saved.get(id).map(|row| (id.clone(), row.clone())))
            .collect();
        Ok(json!({"accountId":account,"finished":finished,"overviews":rows}))
    }
    pub async fn call(
        &self,
        method: &str,
        params: &Value,
        gmail: Arc<crate::providers::gmail::Session>,
        local_mail: Arc<crate::local_mail::LocalMail>,
    ) -> Result<Value, &'static str> {
        match method {
            "inbox.snapshot" => {
                fields(params, &["accountId"])?;
                let account = account(params)?;
                Ok(
                    json!({"overviews":overview_snapshot(store::read(&store::key(&["overviews",&account]))?.unwrap_or(json!({})), now())?,"snoozes":snooze::snapshot(&account)?,"preferences":preferences(&account)?}),
                )
            }
            "inbox.preferences" => {
                fields(params, &["accountId", "paused", "allowRemoteImages"])?;
                for field in ["paused", "allowRemoteImages"] {
                    if params.get(field).is_some_and(|value| !value.is_boolean()) {
                        return Err("invalid_params");
                    }
                }
                account(params)?;
                let change = || {
                    let account = account(params)?;
                    if params.get("paused").is_none() && params.get("allowRemoteImages").is_none() {
                        return preferences(&account);
                    }
                    store::update(&store::key(&["preferences", &account]), |saved| {
                        validate_preferences(saved)?;
                        for field in ["paused", "allowRemoteImages"] {
                            if let Some(value) = params.get(field) {
                                saved[field] = value.clone();
                            }
                        }
                        Ok(())
                    })?;
                    preferences(&account)
                };
                #[cfg(any(all(feature = "agent", unix, not(target_os = "ios")), feature = "mobile"))]
                {
                    crate::account::with_incarnation(None, |_| change())
                }
                #[cfg(not(any(all(feature = "agent", unix, not(target_os = "ios")), feature = "mobile")))]
                {
                    change()
                }
            }
            "inbox.overviews" => {
                fields(params, &["accountId", "ids", "retry", "allowRemoteImages"])?;
                for field in ["retry", "allowRemoteImages"] {
                    if params.get(field).is_some_and(|value| !value.is_boolean()) {
                        return Err("invalid_params");
                    }
                }
                let remote = params["allowRemoteImages"] == true;
                let account = account(params)?;
                let ids = ids(params)?;
                #[cfg(any(all(feature = "agent", unix, not(target_os = "ios")), feature = "mobile"))]
                {
                    self.request_overviews(account, ids, params["retry"] == true, remote, gmail, local_mail, None)
                        .await
                }
                #[cfg(not(any(all(feature = "agent", unix, not(target_os = "ios")), feature = "mobile")))]
                {
                    let _ = (account, ids, local_mail, remote);
                    Err("overview_ai_unavailable")
                }
            }
            "inbox.avatar" => {
                fields(params, &["accountId", "email", "refreshId"])?;
                let refresh_id = params
                    .get("refreshId")
                    .map(|v| v.as_str().ok_or("invalid_params"))
                    .transpose()?
                    .unwrap_or("");
                if refresh_id.len() > 64
                    || !refresh_id
                        .bytes()
                        .all(|b| b.is_ascii_alphanumeric() || b == b'-')
                {
                    return Err("invalid_params");
                }
                let account = account(params)?;
                let email = avatars::email(params["email"].as_str().ok_or("invalid_params")?)?;
                let permit = self
                    .avatar_slots
                    .clone()
                    .acquire_owned()
                    .await
                    .map_err(|_| "inbox_unavailable")?;
                let result = avatars::get(&gmail, &account, &email, refresh_id).await;
                drop(permit);
                result
            }
            "inbox.snooze" | "inbox.wake" | "inbox.tick" => {
                let _guard = self.snooze_lock.lock().await;
                tokio::time::timeout(
                    std::time::Duration::from_secs(55),
                    snooze::call(method, params, gmail.as_ref()),
                )
                .await
                .map_err(|_| "snooze_pending_retry")?
            }
            _ => Err("unknown_method"),
        }
    }
}
#[cfg(any(all(feature = "agent", unix, not(target_os = "ios")), feature = "mobile"))]
fn claim_overviews(
    saved: &mut Value,
    ids: &[String],
    retry: bool,
    at: i64,
) -> Result<Vec<String>, &'static str> {
    let mut chosen = Vec::new();
    if !saved.is_object() {
        return Err("inbox_storage_invalid");
    }
    for id in ids {
        let old = &saved[id];
        if !overview_due(old, retry, at) {
            continue;
        }
        if overview_current(old, at) {
            saved[id]["rewriteState"] = json!("running");
            saved[id]["rewriteAt"] = json!(at);
            chosen.push(id.clone());
            continue;
        }
        let pending_since = old["pendingSince"]
            .as_i64()
            .filter(|value| *value > 0 && *value <= at)
            .unwrap_or(at);
        let attempts = old["attempts"].as_u64().unwrap_or(0);
        saved[id] =
            json!({"state":"running","updated":at,"pendingSince":pending_since,"version":2,"attempts":attempts});
        chosen.push(id.clone());
    }
    Ok(chosen)
}

#[cfg(any(all(feature = "agent", unix, not(target_os = "ios")), feature = "mobile"))]
fn finish_overviews_protected(
    saved: &mut Value,
    chosen: &[String],
    result: &Result<Value, &'static str>,
    protected: &std::collections::HashSet<String>,
) -> Result<(), &'static str> {
    if !saved.is_object() {
        return Err("inbox_storage_invalid");
    }
    for id in chosen {
        let pending_since = saved[id]["pendingSince"]
            .as_i64()
            .filter(|value| *value > 0 && *value <= now())
            .unwrap_or_else(now);
        let row = result
            .as_ref()
            .ok()
            .and_then(Value::as_array)
            .and_then(|rows| rows.iter().find(|v| v["id"] == *id));
        let error = row.and_then(|row| row["error"].as_str()).or(result.as_ref().err().copied());
        // Invariant: an attempt counts only when the writer answered for this message and the failure
        // was its own; a batch-wide failure (tagged "batch" or the whole result) or one met while
        // preparing the mail ("prepare") never counts.
        let own = result.is_ok() && row.is_none_or(|row| row.get("stage").is_none()) && !error.is_some_and(service_failure);
        let attempts = saved[id]["attempts"].as_u64().unwrap_or(0) + u64::from(own);
        saved[id] = match row.filter(|row| row["text"].as_str().is_some_and(valid_description)) {
            Some(row) => {
                json!({"state":"ready","text":row["text"],"version":2,"promptRevision":1,"updated":now(),"expiresAt":if row["timeSensitive"] == false && !relative_words(row["text"].as_str().unwrap_or("")) { 0 } else { row["expiresAt"].as_i64().filter(|value| *value > 0).unwrap_or_else(|| next_day(now())) }})
            }
            None if overview_current(&saved[id], now()) => {
                let mut previous = saved[id].clone();
                previous["rewriteState"] = json!("failed");
                previous["rewriteAt"] = json!(now());
                previous
            }
            None => {
                json!({"state":"failed","reason":overview_failure(error),"updated":now(),"pendingSince":pending_since,"version":2,"attempts":attempts})
            }
        };
    }
    if saved.as_object().unwrap().len() > 5000 {
        let mut keys: Vec<_> = saved
            .as_object()
            .unwrap()
            .iter()
            .filter(|(k, _)| !protected.contains(*k))
            .map(|(k, v)| (v["updated"].as_i64().unwrap_or(0), k.clone()))
            .collect();
        keys.sort();
        for (_, key) in keys.into_iter().take(1000) {
            saved.as_object_mut().unwrap().remove(&key);
        }
    }
    Ok(())
}

#[cfg(all(test, feature = "agent", unix, not(target_os = "ios")))]
fn finish_overviews(
    saved: &mut Value,
    chosen: &[String],
    result: &Result<Value, &'static str>,
) -> Result<(), &'static str> {
    finish_overviews_protected(saved, chosen, result, &std::collections::HashSet::new())
}

#[cfg(any(all(feature = "agent", unix, not(target_os = "ios")), feature = "mobile"))]
async fn overview_batch(
    account: &str,
    ids: &[String],
    gmail: &crate::providers::gmail::Session,
    local_mail: &crate::local_mail::LocalMail,
    remote: bool,
) -> Result<Value, &'static str> {
    overview_batch_with(account, ids, gmail, local_mail, |messages| async move {
        let mut prepared = Vec::new();
        let mut failed = Vec::new();
        for mut message in messages.as_array().cloned().ok_or("overview_input_invalid")? {
            let id = message["id"]
                .as_str()
                .ok_or("overview_input_invalid")?
                .to_owned();
            let enriched = async {
                let raw = local_mail.read(account, &id, gmail).await?;
                context::enrich(account, &id, &raw, &mut message, gmail, remote).await
            }
            .await;
            match enriched {
                Ok(()) => prepared.push(message),
                Err(error) if account_failure(error) => return Err(error),
                Err(error) => failed.push(json!({"id":id,"error":error,"stage":"prepare"})),
            }
        }
        if prepared.is_empty() {
            return Ok(json!(failed));
        }
        let prepared = json!(prepared);
        let generated = writer::generate(&prepared).await;
        merge_rows(generated, &prepared, failed)
    })
    .await
}

/// Failures that concern the whole account, so the batch stops rather than marking each message.
#[cfg(any(all(feature = "agent", unix, not(target_os = "ios")), feature = "mobile"))]
fn account_failure(error: &str) -> bool {
    error.starts_with("accounts_")
        || matches!(error, "local_account_unknown" | "gmail_account_unknown" | "gmail_auth_required" | "overview_account_changed")
}

/// Joins the writer's rows for the messages it was given with the rows of messages that could not be prepared.
/// Invariant: a message that could not be prepared fails alone and never reaches the writer.
#[cfg(any(all(feature = "agent", unix, not(target_os = "ios")), feature = "mobile"))]
fn merge_rows(generated: Result<Value, &'static str>, prepared: &Value, mut failed: Vec<Value>) -> Result<Value, &'static str> {
    if failed.is_empty() {
        return generated;
    }
    match generated {
        Ok(Value::Array(rows)) => failed.extend(rows),
        Ok(_) => {}
        Err(error) => failed.extend(
            prepared.as_array().into_iter().flatten().map(|message| json!({"id":message["id"],"error":error,"stage":"batch"})),
        ),
    }
    Ok(json!(failed))
}

#[cfg(any(all(feature = "agent", unix, not(target_os = "ios")), feature = "mobile"))]
async fn overview_batch_with<F, Fut>(
    account: &str,
    ids: &[String],
    gmail: &crate::providers::gmail::Session,
    local_mail: &crate::local_mail::LocalMail,
    generate: F,
) -> Result<Value, &'static str>
where
    F: FnOnce(Value) -> Fut,
    Fut: std::future::Future<Output = Result<Value, &'static str>>,
{
    let mut messages = Vec::new();
    let mut failed = Vec::new();
    for id in ids {
        let prepared = async {
            let raw = local_mail.read(account, id, gmail).await?;
            overview_message(id, &raw)
        }
        .await;
        match prepared {
            Ok(mut message) => {
                message["owner"] = json!(account);
                messages.push(message);
            }
            Err(error) if account_failure(error) => return Err(error),
            Err(error) => failed.push(json!({"id":id,"error":error,"stage":"prepare"})),
        }
    }
    if messages.is_empty() {
        return Ok(json!(failed));
    }
    let messages = json!(messages);
    let generated = generate(messages.clone()).await;
    merge_rows(generated, &messages, failed)
}

#[cfg(any(all(feature = "agent", unix, not(target_os = "ios")), feature = "mobile"))]
fn overview_message(id: &str, raw: &Value) -> Result<Value, &'static str> {
    let prepared = crate::message::content::prepare(raw, now())?;
    let summary = &prepared["summary"];
    let body = prepared["body"]["text"].as_str().unwrap_or("");
    let current = chrono::Local::now();
    let valid_until = next_day(current.timestamp_millis());
    // Invariant: recipient and attachment lists are bounded like the body, so no header can make a request unbounded.
    let first = |list: &Value| json!(list.as_array().map(|items| &items[..items.len().min(50)]).unwrap_or_default());
    Ok(
        json!({"id":id,"from":summary["from"],"to":first(&summary["to"]),"cc":first(&summary["cc"]),"bcc":first(&summary["bcc"]),"subject":summary["subject"],"date":summary["date"],"currentDate":current.format("%Y-%m-%d").to_string(),"currentTime":current.to_rfc3339(),"validUntil":valid_until,"sentByOwner":summary["isSent"],"body":context::bounded(body,48000),"attachments":first(&prepared["attachments"])}),
    )
}

#[cfg(target_os = "linux")]
pub(crate) fn ready_ids(account: &str, ids: &[Value]) -> Result<Vec<Value>, &'static str> {
    let saved = store::read(&store::key(&["overviews", account]))?.unwrap_or(json!({}));
    if !saved.is_object() {
        return Err("inbox_storage_invalid");
    }
    Ok(ids
        .iter()
        .filter(|id| {
            id.as_str()
                .is_some_and(|id| overview_current(&saved[id], now()))
        })
        .cloned()
        .collect())
}

#[cfg(target_os = "linux")]
pub(crate) fn background_revision(account: &str, ids: &[Value]) -> Result<String, &'static str> {
    let saved = store::read(&store::key(&["overviews", account]))?.unwrap_or(json!({}));
    if !saved.is_object() {
        return Err("inbox_storage_invalid");
    }
    let ready: Vec<_> = ids
        .iter()
        .filter_map(|id| {
            let id = id.as_str()?;
            overview_current(&saved[id], now())
                .then(|| json!([id, saved[id]["text"], saved[id]["expiresAt"]]))
        })
        .collect();
    use sha2::{Digest, Sha256};
    Ok(format!(
        "{:x}",
        Sha256::digest(serde_json::to_vec(&ready).map_err(|_| "inbox_storage_invalid")?)
    ))
}

fn preferences(account: &str) -> Result<Value, &'static str> {
    let saved = store::read(&store::key(&["preferences", account]))?;
    let configured = saved.is_some();
    let saved = match saved {
        Some(saved) => saved,
        None => legacy_preferences()?,
    };
    validate_preferences(&saved)?;
    Ok(
        json!({"paused":saved["paused"] == true,"allowRemoteImages":saved["allowRemoteImages"] == true,"configured":configured}),
    )
}

#[cfg(not(all(feature = "agent", unix, not(target_os = "ios"))))]
fn legacy_preferences() -> Result<Value, &'static str> {
    Ok(json!({}))
}

#[cfg(all(feature = "agent", unix, not(target_os = "ios")))]
fn legacy_preferences() -> Result<Value, &'static str> {
    use crate::platform::{dirs::AppDirs, private_fs};
    use std::io::Read;
    let Some(dir) = private_fs::directories_readonly(&AppDirs::discover()?.config, &["omamail"])?
    else {
        return Ok(json!({}));
    };
    let Some(file) = private_fs::regular_readonly(&dir, "window.json")? else {
        return Ok(json!({}));
    };
    let mut bytes = Vec::new();
    file.take(128 * 1024 + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| "inbox_storage_invalid")?;
    if bytes.len() > 128 * 1024 {
        return Err("inbox_storage_invalid");
    }
    let saved: Value = serde_json::from_slice(&bytes).map_err(|_| "inbox_storage_invalid")?;
    if !saved.is_object()
        || ["overviewPaused", "alwaysShowImages"]
            .iter()
            .any(|field| saved.get(field).is_some_and(|value| !value.is_boolean()))
    {
        return Err("inbox_storage_invalid");
    }
    Ok(
        json!({"paused":saved["overviewPaused"] == true,"allowRemoteImages":saved["alwaysShowImages"] == true}),
    )
}

fn validate_preferences(saved: &Value) -> Result<(), &'static str> {
    if !saved.is_object()
        || ["paused", "allowRemoteImages"]
            .iter()
            .any(|field| saved.get(field).is_some_and(|value| !value.is_boolean()))
    {
        return Err("inbox_storage_invalid");
    }
    Ok(())
}

fn valid_description(text: &str) -> bool {
    !text.trim().is_empty()
        && text.chars().count() <= 140
        && !text.chars().any(|c| {
            c.is_control()
                || matches!(c as u32, 0x200b..=0x200f | 0x202a..=0x202e | 0x2060..=0x206f | 0xfeff)
                || c == '<'
                || c == '>'
        })
}

#[cfg(any(all(feature = "agent", unix, not(target_os = "ios")), feature = "mobile"))]
fn overview_due(value: &Value, retry: bool, at: i64) -> bool {
    if overview_current(value, at) {
        if value["promptRevision"] == 1 { return false; }
        let age = at.saturating_sub(value["rewriteAt"].as_i64().unwrap_or(0));
        return !(age >= 0 && age < 900_000 && (value["rewriteState"] == "running" || (!retry && value["rewriteState"] == "failed")));
    }
    // Invariant: the phone pays for each attempt, so a message that failed three times for its own
    // content waits for Retry instead of being asked again every 15 minutes.
    if cfg!(feature = "mobile") && !retry && value["state"] == "failed" && value["attempts"].as_u64().unwrap_or(0) >= RETRY_LIMIT {
        return false;
    }
    let age = at.saturating_sub(value["updated"].as_i64().unwrap_or(0));
    !(age >= 0
        && age < 900_000
        && (value["state"] == "running" || (!retry && value["state"] == "failed")))
}

#[cfg(any(all(feature = "agent", unix, not(target_os = "ios")), feature = "mobile"))]
const RETRY_LIMIT: u64 = 3;

#[cfg(feature = "mobile")]
fn forgive_attempts(saved: &mut Value) -> Result<(), &'static str> {
    for row in saved.as_object_mut().ok_or("inbox_storage_invalid")?.values_mut() {
        if row["state"] == "failed" && row.get("attempts").is_some() {
            row["attempts"] = json!(0);
        }
    }
    Ok(())
}

/// Failures that say nothing about the message itself, so they never count as one of its attempts.
#[cfg(any(all(feature = "agent", unix, not(target_os = "ios")), feature = "mobile"))]
fn service_failure(error: &str) -> bool {
    ["ai_", "gmail_", "local_", "private_fs_", "inbox_storage_"].iter().any(|prefix| error.starts_with(prefix))
        && error != "gmail_not_found"
        || matches!(error, "overview_start_failed" | "overview_ai_unavailable" | "overview_account_changed")
}

#[cfg(any(all(feature = "agent", unix, not(target_os = "ios")), feature = "mobile"))]
fn overview_claimed(value: &Value, at: i64) -> bool {
    (value["state"] == "running" && value["updated"] == at)
        || (value["rewriteState"] == "running" && value["rewriteAt"] == at)
}

fn overview_current(value: &Value, at: i64) -> bool {
    value["version"] == 2
        && value["state"] == "ready"
        && value["text"].as_str().is_some_and(valid_description)
        && value["expiresAt"].as_i64().is_some_and(|expires| {
            expires <= 9_007_199_254_740_991 && (expires == 0 || expires > at)
        })
}

fn overview_snapshot(mut saved: Value, at: i64) -> Result<Value, &'static str> {
    for value in saved
        .as_object_mut()
        .ok_or("inbox_storage_invalid")?
        .values_mut()
    {
        if !overview_current(value, at) && value["state"] == "ready" {
            value["state"] = json!("stale");
            value.as_object_mut().map(|fields| fields.remove("text"));
        }
    }
    Ok(saved)
}

fn relative_words(text: &str) -> bool {
    text.to_lowercase()
        .split(|c: char| !c.is_alphabetic())
        .any(|word| {
            matches!(
                word,
                "today"
                    | "yesterday"
                    | "tomorrow"
                    | "tonight"
                    | "ago"
                    | "overdue"
                    | "due"
                    | "expires"
                    | "expired"
                    | "monday"
                    | "tuesday"
                    | "wednesday"
                    | "thursday"
                    | "friday"
                    | "saturday"
                    | "sunday"
            )
        })
}

fn next_day(at: i64) -> i64 {
    use chrono::{Local, TimeZone};
    let Some(current) = Local.timestamp_millis_opt(at).single() else {
        return at.saturating_add(86_400_000);
    };
    let Some(date) = current
        .date_naive()
        .succ_opt()
        .and_then(|date| date.and_hms_opt(0, 0, 0))
    else {
        return at.saturating_add(86_400_000);
    };
    Local
        .from_local_datetime(&date)
        .earliest()
        .map_or(at.saturating_add(86_400_000), |date| {
            date.timestamp_millis()
        })
}

fn overview_failure(error: Option<&str>) -> &'static str {
    match error {
        Some("overview_start_failed") => "AI worker could not start; retry from Menu",
        Some("overview_ai_unavailable") => "AI service did not respond; retry from Menu",
        Some("overview_invalid_response") => {
            "AI response failed format or length checks; retry from Menu"
        }
        Some("overview_unsupported_claim") => {
            "AI response could not be verified against the mail; retry from Menu"
        }
        Some("ai_key_invalid" | "ai_key_refused") => {
            "Claude refused the API key; add a new key in Settings"
        }
        Some("ai_billing") => "Claude API billing needs attention in the Claude Console",
        Some("ai_rate_limited" | "ai_unavailable" | "ai_unreachable" | "ai_daily_limit") => {
            "Claude could not take more requests just now; Magpie will retry"
        }
        Some("overview_ai_refused") => "Claude declined to describe this message",
        None => "AI response omitted this message; retry from Menu",
        _ => "Mail could not be prepared for AI; retry from Menu",
    }
}

#[cfg(all(test, any(all(feature = "agent", unix, not(target_os = "ios")), feature = "mobile")))]
mod overview_attempt_tests {
    use super::*;

    #[test]
    fn each_message_keeps_its_own_failure_and_only_its_own_faults_count_as_attempts() {
        let at = now();
        let mut saved = json!({});
        let ids: Vec<String> = ["a", "b", "c"].iter().map(|id| id.to_string()).collect();
        claim_overviews(&mut saved, &ids, false, at).unwrap();
        let result = Ok(json!([
            {"id":"a","text":"Your invoice INV-520 was paid","timeSensitive":false,"expiresAt":0},
            {"id":"b","error":"overview_ai_refused"},
            {"id":"c","error":"ai_rate_limited"}
        ]));
        finish_overviews_protected(&mut saved, &ids, &result, &Default::default()).unwrap();
        assert_eq!(saved["a"]["state"], "ready", "a neighbour's failure does not fail this message");
        assert_eq!(saved["b"]["state"], "failed");
        assert_eq!(saved["b"]["reason"], overview_failure(Some("overview_ai_refused")));
        assert_eq!(saved["b"]["attempts"], 1);
        assert_eq!(saved["c"]["reason"], overview_failure(Some("ai_rate_limited")));
        assert_eq!(saved["c"]["attempts"], 0, "a busy service is not the message's fault");
    }

    #[test]
    fn preparation_and_batch_failures_never_count_as_attempts() {
        let at = now();
        let ids: Vec<String> = ["a", "b", "c", "d"].iter().map(|id| id.to_string()).collect();
        let mut saved = json!({});
        claim_overviews(&mut saved, &ids, false, at).unwrap();
        finish_overviews_protected(&mut saved, &ids, &Err("overview_unsupported_claim"), &Default::default()).unwrap();
        assert!(ids.iter().all(|id| saved[id]["attempts"] == 0), "a batch-wide failure is no one message's fault");
        claim_overviews(&mut saved, &ids, true, at + 1).unwrap();
        let result = Ok(json!([
            {"id":"a","error":"gmail_not_found","stage":"prepare"},
            {"id":"b","error":"gmail_http_failed"},
            {"id":"c","error":"overview_unsupported_claim"},
            {"id":"d","error":"overview_unsupported_claim","stage":"batch"}
        ]));
        finish_overviews_protected(&mut saved, &ids, &result, &Default::default()).unwrap();
        assert_eq!(saved["d"]["attempts"], 0, "a writer failure spread over the batch is no one message's fault");
        assert_eq!(saved["a"]["attempts"], 0, "mail that could not be prepared cost nothing");
        assert_eq!(saved["b"]["attempts"], 0, "a network failure is not the message's fault");
        assert_eq!(saved["c"]["attempts"], 1);
        assert!(service_failure("local_disk_full") && service_failure("inbox_storage_invalid") && !service_failure("gmail_not_found"));
    }

    #[cfg(feature = "mobile")]
    #[test]
    fn retry_forgives_every_failed_message() {
        let later = now() + 3_600_000;
        let mut saved = json!({
            "capped": {"state":"failed","updated":now(),"version":2,"attempts":3},
            "ready": {"state":"ready","text":"Receipt","version":2,"expiresAt":0}
        });
        forgive_attempts(&mut saved).unwrap();
        assert_eq!(saved["capped"]["attempts"], 0);
        assert!(overview_due(&saved["capped"], false, later), "the next poll asks again without another Retry");
        assert!(saved["ready"].get("attempts").is_none());
    }

    #[test]
    fn a_message_that_fails_three_times_waits_for_retry_on_the_phone() {
        let later = now() + 3_600_000;
        let row = |attempts: u64| json!({"state":"failed","updated":now(),"version":2,"attempts":attempts});
        assert!(overview_due(&row(2), false, later));
        assert_eq!(overview_due(&row(3), false, later), !cfg!(feature = "mobile"));
        assert!(overview_due(&row(3), true, later), "Retry always asks again");
        let mut saved = json!({"m": row(3)});
        claim_overviews(&mut saved, &["m".to_string()], true, later).unwrap();
        assert_eq!(saved["m"]["attempts"], 3, "a claim carries the count forward");
        assert!(service_failure("ai_daily_limit") && !service_failure("overview_unsupported_claim"));
    }
}

#[cfg(test)]
mod overview_failure_tests {
    use super::overview_failure;
    #[test]
    fn failure_reasons_are_specific_and_never_echo_external_errors() {
        assert!(overview_failure(Some("overview_unsupported_claim")).contains("verified"));
        assert!(overview_failure(Some("overview_invalid_response")).contains("format or length"));
        assert!(overview_failure(Some("overview_start_failed")).contains("start"));
        assert!(overview_failure(Some("overview_ai_unavailable")).contains("respond"));
        assert!(!overview_failure(Some("secret mail or credential")).contains("secret"));
        assert!(overview_failure(None).contains("omitted"));
        assert!(overview_failure(Some("ai_key_invalid")).contains("API key"));
        assert!(overview_failure(Some("ai_billing")).contains("billing"));
        assert!(overview_failure(Some("ai_rate_limited")).contains("retry"));
    }
}

#[cfg(all(test, feature = "agent", unix, not(target_os = "ios")))]
mod overview_storage_tests {
    use super::{claim_overviews, finish_overviews};
    use serde_json::{Value, json};

    #[test]
    fn descriptions_expire_against_generation_date_even_when_completion_crosses_midnight() {
        let mut saved = json!({});
        finish_overviews(&mut saved, &["dated".into(),"static".into()], &Ok(json!([
            {"id":"dated","text":"Reminder — Your bill was due yesterday","timeSensitive":false,"expiresAt":1000},
            {"id":"static","text":"Receipt — R780 received for invoice INV-520","timeSensitive":false,"expiresAt":1000}
        ]))).unwrap();
        assert_eq!(saved["dated"]["expiresAt"], 1000);
        assert!(!super::overview_current(&saved["dated"], 1000));
        assert!(super::overview_current(&saved["static"], 2000));
        let snapshot = super::overview_snapshot(saved, 2000).unwrap();
        assert_eq!(snapshot["dated"]["state"], "stale");
        assert!(snapshot["dated"].get("text").is_none());
        assert!(snapshot["static"]["text"].is_string());
    }

    #[test]
    fn old_descriptions_are_hidden_and_admitted_for_regeneration() {
        let mut saved = json!({"legacy":{"state":"ready","text":"Old overview","version":1},"missing":{"state":"ready","text":"Missing expiry","version":2}});
        let snapshot = super::overview_snapshot(saved.clone(), 1000).unwrap();
        assert!(
            snapshot
                .as_object()
                .unwrap()
                .values()
                .all(|value| value.get("text").is_none())
        );
        let ids = vec!["legacy".into(), "missing".into()];
        assert_eq!(claim_overviews(&mut saved, &ids, false, 1000).unwrap(), ids);
    }

    #[test]
    fn expired_overview_failure_accepts_the_full_persisted_timestamp_range() {
        let mut saved = json!({"message": {"state":"failed", "updated":i64::MIN}});
        let ids = vec!["message".to_owned()];
        assert_eq!(
            claim_overviews(&mut saved, &ids, false, 1_000_000).unwrap(),
            ids
        );
        assert_eq!(saved["message"]["state"], "running");
    }

    #[test]
    fn overview_completion_rejects_nonobject_storage_without_mutation() {
        for mut saved in [Value::Null, json!([]), json!("replaced"), json!(7)] {
            let before = saved.clone();
            assert_eq!(
                finish_overviews(&mut saved, &["message".into()], &Ok(json!([]))),
                Err("inbox_storage_invalid")
            );
            assert_eq!(saved, before);
        }
    }

    #[test]
    fn overview_claim_preserves_ready_results_and_observes_retry_cooldown() {
        let original = json!({
            "ready": {"text":"saved summary", "version":2,"promptRevision":1,"state":"ready","expiresAt":0},
            "recent": {"state":"failed", "updated":100_001},
            "expired": {"state":"failed", "updated":100_000}
        });
        let ids = vec!["ready".into(), "recent".into(), "expired".into()];
        let mut saved = original.clone();
        assert_eq!(
            claim_overviews(&mut saved, &ids, false, 1_000_000).unwrap(),
            vec!["expired"]
        );
        assert_eq!(saved["ready"], original["ready"]);
        assert_eq!(saved["recent"], original["recent"]);
        saved = original.clone();
        assert_eq!(
            claim_overviews(&mut saved, &ids, true, 1_000_000).unwrap(),
            vec!["recent", "expired"]
        );
        assert_eq!(saved["ready"], original["ready"]);
    }

    #[test]
    fn old_prompt_descriptions_are_rewritten_only_when_selected_for_preparation() {
        let old = json!({"version":2,"state":"ready","text":"Receipt — Your payment arrived","expiresAt":0});
        let mut saved = json!({"inbox":old,"archive":old});
        assert!(super::overview_current(&saved["archive"], 1000));
        assert_eq!(claim_overviews(&mut saved, &["inbox".into()], false, 1000).unwrap(), vec!["inbox"]);
        assert_eq!(saved["archive"], old, "unselected archived descriptions stay available");
        assert!(super::overview_current(&saved["inbox"], 1001), "rewriting must not hide an existing Inbox row");
        assert!(super::overview_claimed(&saved["inbox"], 1000));
        assert!(claim_overviews(&mut saved, &["inbox".into()], false, 1001).unwrap().is_empty());
        finish_overviews(&mut saved, &["inbox".into()], &Err("overview_ai_unavailable")).unwrap();
        assert_eq!(saved["inbox"]["text"], old["text"], "failed rewrite preserves valid text");
        assert!(super::overview_current(&saved["inbox"], 1001));
        finish_overviews(&mut saved, &["inbox".into()], &Ok(json!([{"id":"inbox","text":"Your payment of €20 has arrived","timeSensitive":false}]))).unwrap();
        assert_eq!(saved["inbox"]["promptRevision"], 1);
        assert!(claim_overviews(&mut saved, &["inbox".into()], false, 2000).unwrap().is_empty());
    }

    #[test]
    fn overview_completion_keeps_recent_results_when_pruning_old_records() {
        let mut saved = json!({});
        for index in 0..5001 {
            saved[index.to_string()] = json!({"updated":index});
        }
        finish_overviews(
            &mut saved,
            &["message".into()],
            &Ok(json!([{"id":"message", "text":"fresh summary"}])),
        )
        .unwrap();
        assert_eq!(saved.as_object().unwrap().len(), 4002);
        assert!(saved.get("0").is_none());
        assert!(saved.get("999").is_none());
        assert!(saved.get("1000").is_some());
        assert_eq!(saved["message"]["state"], "ready");
        assert_eq!(saved["message"]["text"], "fresh summary");
    }
}

#[cfg(feature = "mobile")]
pub(crate) fn forget_phone_account(account: &str) -> Result<(), &'static str> {
    use crate::platform::{dirs::AppDirs, private_fs};
    let Some(dir) =
        private_fs::directories(&AppDirs::discover()?.state, &["omamail", "inbox"], false)?
    else {
        return Ok(());
    };
    let _lock = private_fs::lock_exclusive(&dir, ".cache-lock")?;
    let contacts = store::key(&["contacts", account]);
    private_fs::remove_owned(&dir, &contacts)?;
    for name in private_fs::names(&dir)? {
        if !name.starts_with("avatar-") {
            continue;
        }
        if let Some(row) = store::read(&name)? {
            if row.get("owner").is_none() || row["owner"] == account {
                private_fs::remove_owned(&dir, &name)?;
            }
        }
    }
    private_fs::sync_dir(&dir)
}
