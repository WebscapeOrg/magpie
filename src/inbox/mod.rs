mod avatars;
#[cfg(all(feature = "agent", unix, not(target_os = "ios")))]
mod context;
#[cfg(all(test, feature = "agent", unix, not(target_os = "ios")))]
mod overview_tests;
#[cfg(target_os = "linux")]
mod phone;
mod snooze;
mod store;
use serde_json::{Value, json};
use std::sync::Arc;
use tokio::sync::{Mutex, Semaphore};

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
                    json!({"overviews":overview_snapshot(store::read(&store::key(&["overviews",&account]))?.unwrap_or(json!({})), now())?,"snoozes":snooze::snapshot(&account)?}),
                )
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
                #[cfg(all(feature = "agent", unix, not(target_os = "ios")))]
                {
                    let Ok(permit) = self.overview_slots.clone().try_acquire_owned() else {
                        return Ok(json!({"accepted":false}));
                    };
                    let name = store::key(&["overviews", &account]);
                    let chosen = store::update(&name, |saved| {
                        claim_overviews(saved, &ids, params["retry"] == true, now())
                    })?;
                    if chosen.is_empty() {
                        return Ok(json!({"accepted":true}));
                    }
                    tokio::spawn(async move {
                        let _permit = permit;
                        let result =
                            overview_batch(&account, &chosen, &gmail, &local_mail, remote).await;
                        let _ =
                            store::update(&name, |saved| finish_overviews(saved, &chosen, &result));
                    });
                    Ok(json!({"accepted":true}))
                }
                #[cfg(not(all(feature = "agent", unix, not(target_os = "ios"))))]
                {
                    let _ = (account, ids, local_mail);
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
                    snooze::call(method, params, &gmail),
                )
                .await
                .map_err(|_| "snooze_pending_retry")?
            }
            _ => Err("unknown_method"),
        }
    }
}
#[cfg(all(feature = "agent", unix, not(target_os = "ios")))]
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
        if overview_current(old, at) {
            continue;
        }
        if old["state"] == "running"
            && at.saturating_sub(old["updated"].as_i64().unwrap_or(0)) < 900_000
        {
            continue;
        }
        if !retry
            && old["state"] == "failed"
            && at.saturating_sub(old["updated"].as_i64().unwrap_or(0)) < 900_000
        {
            continue;
        }
        saved[id] = json!({"state":"running","updated":at,"version":2});
        chosen.push(id.clone());
    }
    Ok(chosen)
}

#[cfg(all(feature = "agent", unix, not(target_os = "ios")))]
fn finish_overviews(
    saved: &mut Value,
    chosen: &[String],
    result: &Result<Value, &'static str>,
) -> Result<(), &'static str> {
    if !saved.is_object() {
        return Err("inbox_storage_invalid");
    }
    for id in chosen {
        let row = result
            .as_ref()
            .ok()
            .and_then(Value::as_array)
            .and_then(|rows| rows.iter().find(|v| v["id"] == *id));
        saved[id] = match row
            .filter(|row| row["text"].as_str().is_some_and(|text| !text.is_empty()))
        {
            Some(row) => {
                json!({"state":"ready","text":row["text"],"version":2,"updated":now(),"expiresAt":if row["timeSensitive"] == false && !relative_words(row["text"].as_str().unwrap_or("")) { 0 } else { row["expiresAt"].as_i64().filter(|value| *value > 0).unwrap_or_else(|| next_day(now())) }})
            }
            None => {
                json!({"state":"failed","reason":overview_failure(result.as_ref().err().copied()),"updated":now(),"version":2})
            }
        };
    }
    // Performance: Overviews are replaceable; keep a bounded recent working
    // set.
    if saved.as_object().unwrap().len() > 5000 {
        let mut keys: Vec<_> = saved
            .as_object()
            .unwrap()
            .iter()
            .map(|(k, v)| (v["updated"].as_i64().unwrap_or(0), k.clone()))
            .collect();
        keys.sort();
        for (_, key) in keys.into_iter().take(1000) {
            saved.as_object_mut().unwrap().remove(&key);
        }
    }
    Ok(())
}

#[cfg(all(feature = "agent", unix, not(target_os = "ios")))]
async fn overview_batch(
    account: &str,
    ids: &[String],
    gmail: &crate::providers::gmail::Session,
    local_mail: &crate::local_mail::LocalMail,
    remote: bool,
) -> Result<Value, &'static str> {
    overview_batch_with(account, ids, gmail, local_mail, |mut messages| async move {
        for message in messages.as_array_mut().ok_or("overview_input_invalid")? {
            let id = message["id"]
                .as_str()
                .ok_or("overview_input_invalid")?
                .to_owned();
            let raw = local_mail.read(account, &id, gmail).await?;
            context::enrich(account, &id, &raw, message, gmail, remote).await?;
        }
        crate::agent::overview::generate(&messages).await
    })
    .await
}

#[cfg(all(feature = "agent", unix, not(target_os = "ios")))]
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
    for id in ids {
        let raw = local_mail.read(account, id, gmail).await?;
        let mut message = overview_message(id, &raw)?;
        message["owner"] = json!(account);
        messages.push(message);
    }
    generate(json!(messages)).await
}

#[cfg(all(feature = "agent", unix, not(target_os = "ios")))]
fn overview_message(id: &str, raw: &Value) -> Result<Value, &'static str> {
    let prepared = crate::message::content::prepare(raw, now())?;
    let summary = &prepared["summary"];
    let body = prepared["body"]["text"].as_str().unwrap_or("");
    let current = chrono::Local::now();
    let valid_until = next_day(current.timestamp_millis());
    Ok(
        json!({"id":id,"from":summary["from"],"to":summary["to"],"cc":summary["cc"],"bcc":summary["bcc"],"subject":summary["subject"],"date":summary["date"],"currentDate":current.format("%Y-%m-%d").to_string(),"currentTime":current.to_rfc3339(),"validUntil":valid_until,"sentByOwner":summary["isSent"],"body":context::bounded(body,48000),"attachments":prepared["attachments"]}),
    )
}

fn overview_current(value: &Value, at: i64) -> bool {
    value["version"] == 2
        && value["state"] == "ready"
        && value["text"].as_str().is_some_and(|text| !text.is_empty())
        && value["expiresAt"]
            .as_i64()
            .is_some_and(|expires| expires == 0 || expires > at)
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
        None => "AI response omitted this message; retry from Menu",
        _ => "Mail could not be prepared for AI; retry from Menu",
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
            "ready": {"text":"saved summary", "version":2,"state":"ready","expiresAt":0},
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
