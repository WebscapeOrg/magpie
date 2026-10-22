mod avatars;
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
    let account = crate::mail::resolve_account(value)?;
    if account.provider != crate::mail::Provider::Gmail {
        return Err("inbox_gmail_required");
    }
    Ok(account.id)
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
                    let mut chosen = Vec::new();
                    store::update(&name, |saved| {
                        if !saved.is_object() {
                            return Err("inbox_storage_invalid");
                        }
                        for id in ids {
                            let old = &saved[&id];
                            if old["text"].as_str().is_some_and(|s| !s.is_empty())
                                && old["version"] == 1
                            {
                                continue;
                            }
                            if params["retry"] != true
                                && old["state"] == "failed"
                                && now() - old["updated"].as_i64().unwrap_or(0) < 900_000
                            {
                                continue;
                            }
                            saved[&id] = json!({"state":"running","updated":now(),"version":1});
                            chosen.push(id);
                        }
                        Ok(())
                    })?;
                    if chosen.is_empty() {
                        return Ok(json!({"accepted":true}));
                    }
                    tokio::spawn(async move {
                        let _permit = permit;
                        let result = overview_batch(&account, &chosen, &gmail).await;
                        let _ = store::update(&name, |saved| {
                            for id in &chosen {
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
                        });
                    });
                    Ok(json!({"accepted":true}))
                }
                #[cfg(not(all(feature = "agent", unix)))]
                {
                    let _ = (account, ids);
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
async fn overview_batch(
    account: &str,
    ids: &[String],
    gmail: &crate::providers::gmail::Session,
) -> Result<Value, &'static str> {
    let mut messages = Vec::new();
    for id in ids {
        let raw = gmail
            .call(
                "gmail.read",
                &json!({"accountId":account,"id":id,"full":true}),
            )
            .await?;
        let prepared = crate::message::content::prepare(&raw, now())?;
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
        messages.push(json!({"id":id,"from":summary["from"],"subject":summary["subject"],"date":summary["fullTime"],"body":body,"attachments":prepared["attachments"]}));
    }
    crate::agent::overview::generate(&json!(messages)).await
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
