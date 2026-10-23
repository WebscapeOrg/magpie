mod avatars;
#[cfg(all(test, feature = "agent", unix))]
mod overview_tests;
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
                    json!({"overviews":store::read(&store::key(&["overviews",&account]))?.unwrap_or(json!({})),"snoozes":snooze::snapshot(&account)?}),
                )
            }
            "inbox.overviews" => {
                fields(params, &["accountId", "ids", "retry"])?;
                let account = account(params)?;
                let ids = ids(params)?;
                #[cfg(all(feature = "agent", unix))]
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
                        let result = overview_batch(&account, &chosen, &gmail, &local_mail).await;
                        let _ =
                            store::update(&name, |saved| finish_overviews(saved, &chosen, &result));
                    });
                    Ok(json!({"accepted":true}))
                }
                #[cfg(not(all(feature = "agent", unix)))]
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
#[cfg(all(feature = "agent", unix))]
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
        if old["text"].as_str().is_some_and(|s| !s.is_empty()) && old["version"] == 1 {
            continue;
        }
        if !retry
            && old["state"] == "failed"
            && at.saturating_sub(old["updated"].as_i64().unwrap_or(0)) < 900_000
        {
            continue;
        }
        saved[id] = json!({"state":"running","updated":at,"version":1});
        chosen.push(id.clone());
    }
    Ok(chosen)
}

#[cfg(all(feature = "agent", unix))]
fn finish_overviews(
    saved: &mut Value,
    chosen: &[String],
    result: &Result<Value, &'static str>,
) -> Result<(), &'static str> {
    if !saved.is_object() {
        return Err("inbox_storage_invalid");
    }
    for id in chosen {
        let text = result
            .as_ref()
            .ok()
            .and_then(|rows| rows.as_array())
            .and_then(|rows| rows.iter().find(|v| v["id"] == *id))
            .and_then(|v| v["text"].as_str());
        saved[id] = match text {
            Some(text) => {
                json!({"state":"ready","text":text,"version":1,"updated":now()})
            }
            None => {
                json!({"state":"failed","reason":overview_failure(result.as_ref().err().copied()),"updated":now(),"version":1})
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

#[cfg(all(feature = "agent", unix))]
async fn overview_batch(
    account: &str,
    ids: &[String],
    gmail: &crate::providers::gmail::Session,
    local_mail: &crate::local_mail::LocalMail,
) -> Result<Value, &'static str> {
    overview_batch_with(account, ids, gmail, local_mail, |messages| async move {
        crate::agent::overview::generate(&messages).await
    })
    .await
}

#[cfg(all(feature = "agent", unix))]
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
        messages.push(overview_message(id, &raw)?);
    }
    generate(json!(messages)).await
}

#[cfg(all(feature = "agent", unix))]
fn overview_message(id: &str, raw: &Value) -> Result<Value, &'static str> {
    let prepared = crate::message::content::prepare(raw, now())?;
    let summary = &prepared["summary"];
    let body = prepared["body"]["text"].as_str().unwrap_or("");
    // Algorithm: Preserve the opening request and the end (often where the real ask lives).
    let body = if body.chars().count() > 48000 {
        let start: String = body.chars().take(36000).collect();
        let end: String = body
            .chars()
            .rev()
            .take(12000)
            .collect::<String>()
            .chars()
            .rev()
            .collect();
        format!("{start}\n[Middle omitted]\n{end}")
    } else {
        body.to_owned()
    };
    Ok(
        json!({"id":id,"from":summary["from"],"subject":summary["subject"],"date":summary["fullTime"],"body":body,"attachments":prepared["attachments"]}),
    )
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

#[cfg(all(test, feature = "agent", unix))]
mod overview_storage_tests {
    use super::{claim_overviews, finish_overviews};
    use serde_json::{Value, json};

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
            "ready": {"text":"saved summary", "version":1},
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
