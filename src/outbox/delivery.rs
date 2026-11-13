//! Invariant: Execute only the registered account's native provider send, exactly once.
use serde_json::{Value, json};

pub async fn send(
    job: &Value,
    gmail: &crate::providers::gmail::Session,
) -> Result<Value, &'static str> {
    let account = super::text(job, "accountId")?.to_owned();
    let provider = super::text(job, "provider")?;
    if provider != "gmail" {
        return Err("outbox_invalid_provider");
    }
    let registry = tokio::task::spawn_blocking(crate::account::list)
        .await
        .map_err(|_| "outbox_account_unavailable")?
        .map_err(|_| "outbox_account_unavailable")?;
    if !registry["accounts"].as_array().is_some_and(|accounts| {
        accounts.iter().any(|entry| {
            entry["id"] == account && entry["provider"] == provider && entry["pending"] != true
        })
    }) {
        return Err("outbox_account_unavailable");
    }
    let payload = job["payload"].as_object().ok_or("outbox_invalid_payload")?;
    if payload
        .keys()
        .any(|key| !["raw", "threadId", "draftId", "attachments", "sendId"].contains(&key.as_str()))
    {
        return Err("outbox_invalid_payload");
    }
    let raw = payload
        .get("raw")
        .and_then(Value::as_str)
        .filter(|raw| !raw.is_empty())
        .ok_or("outbox_invalid_payload")?;
    let mut params = json!({"accountId":account,"raw":raw});
    if let Some(thread) = payload.get("threadId") {
        params["threadId"] = thread.clone();
    }
    let draft = payload.get("draftId").and_then(Value::as_str).unwrap_or("");
    if draft.len() > 1024 || draft.chars().any(char::is_control) {
        return Err("outbox_invalid_payload");
    }
    if draft.is_empty() {
        return gmail.call("gmail.send", &params).await;
    }
    params["id"] = json!(draft);
    let mut answer = gmail.call("gmail.sendDraft", &params).await?;
    if !answer.is_object() {
        return Err("gmail_invalid_response");
    }
    answer["draftRemoved"] = json!(true);
    Ok(answer)
}
