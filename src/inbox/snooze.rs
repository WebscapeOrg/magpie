use super::{account, fields, now, store};
use serde_json::{Value, json};
const FILE: &str = "snoozes.json";
pub(super) fn revisions(account: &str) -> Result<Value, &'static str> {
    Ok(store::read(&store::key(&["snooze-revisions", account]))?.unwrap_or(json!({})))
}
pub(super) fn advance(account: &str, thread: &str) -> Result<String, &'static str> {
    advance_operation(account, thread, None)
}
fn advance_operation(
    account: &str,
    thread: &str,
    operation: Option<&str>,
) -> Result<String, &'static str> {
    if let Some(operation) = operation {
        let versions = revisions(account)?;
        if versions[thread]["operationId"] == operation {
            return versions[thread]["revision"]
                .as_str()
                .map(str::to_owned)
                .ok_or("inbox_storage_invalid");
        }
    }
    let mut entropy = [0; 16];
    rustls::crypto::ring::default_provider()
        .secure_random
        .fill(&mut entropy)
        .map_err(|_| "snooze_storage_failed")?;
    use base64::Engine;
    let generation = base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(entropy);
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
pub fn snapshot(account: &str) -> Result<Value, &'static str> {
    let saved = store::read(FILE)?.unwrap_or(json!({}));
    Ok(json!(
        saved
            .as_object()
            .ok_or("inbox_storage_invalid")?
            .values()
            .filter(|v| v["accountId"] == account)
            .cloned()
            .collect::<Vec<_>>()
    ))
}
pub async fn call(
    method: &str,
    p: &Value,
    gmail: &crate::providers::gmail::Session,
) -> Result<Value, &'static str> {
    call_with_operation(method, p, gmail, None).await
}
pub(super) async fn call_with_operation(
    method: &str,
    p: &Value,
    gmail: &crate::providers::gmail::Session,
    operation: Option<&str>,
) -> Result<Value, &'static str> {
    fields(
        p,
        if method == "inbox.tick" {
            &[]
        } else if method == "inbox.wake" {
            &["accountId", "id"]
        } else {
            &["accountId", "id", "until"]
        },
    )?;
    if method == "inbox.tick" {
        return tick(gmail).await;
    }
    let account = account(p)?;
    let id = p["id"].as_str().ok_or("invalid_params")?;
    crate::mail::action::validate_message_id(crate::mail::Provider::Gmail, id)?;
    let key = store::key(&[&account, id]);
    if method == "inbox.wake" {
        let saved = store::read(FILE)?.unwrap_or(json!({}));
        let entry = saved.get(&key).ok_or("snooze_missing")?;
        advance_operation(
            &account,
            entry["threadId"].as_str().ok_or("inbox_storage_invalid")?,
            operation,
        )?;
        wake(gmail, entry).await?;
        store::update(FILE, |v| {
            v.as_object_mut()
                .ok_or("inbox_storage_invalid")?
                .remove(&key);
            Ok(())
        })?;
        return Ok(json!({"ok":true}));
    }
    let until = p["until"]
        .as_i64()
        .filter(|t| *t > now() + 1000 && *t < now() + 5 * 366 * 86_400_000)
        .ok_or("snooze_invalid_time")?;
    let resource = gmail
        .call(
            "gmail.read",
            &json!({"accountId":account,"id":id,"full":false}),
        )
        .await?;
    let labels = resource["labelIds"]
        .as_array()
        .ok_or("gmail_invalid_response")?;
    if labels
        .iter()
        .any(|v| v == "TRASH" || v == "SPAM" || v == "DRAFT")
    {
        return Err("snooze_invalid_folder");
    }
    // Invariant: Capture membership from the authoritative thread, not UI/model text.
    let thread = resource["threadId"]
        .as_str()
        .ok_or("gmail_invalid_response")?;
    let value = gmail.thread_resources(&account, thread).await?;
    let ids: Vec<_> = value
        .iter()
        .filter(|v| {
            !v["labelIds"]
                .as_array()
                .is_some_and(|a| a.iter().any(|l| l == "TRASH" || l == "SPAM"))
        })
        .filter_map(|v| v["id"].as_str())
        .map(str::to_owned)
        .collect();
    if ids.is_empty() || ids.len() > 1000 {
        return Err("snooze_invalid_thread");
    }
    let generation = advance_operation(&account, thread, operation)?;
    let entry = json!({"generation":generation,"operationId":operation,"accountId":account,"id":id,"ids":ids,"until":until,"state":"pending","subject":crate::message::content::summarize(&resource,now())?["subject"],"threadId":thread});
    store::update(FILE, |v| {
        if v.as_object().ok_or("inbox_storage_invalid")?.len() >= 1000 && v.get(&key).is_none() {
            return Err("snooze_limit");
        };
        let duplicates: Vec<String> = v
            .as_object()
            .unwrap()
            .iter()
            .filter(|(_, old)| old["accountId"] == account && old["threadId"] == thread)
            .map(|(key, _)| key.clone())
            .collect();
        for duplicate in duplicates {
            v.as_object_mut().unwrap().remove(&duplicate);
        }
        v[&key] = entry;
        Ok(())
    })?;
    let answer = gmail
        .call_settled(
            "gmail.batchModify",
            &json!({"accountId":account,"ids":ids,"addLabelIds":[],"removeLabelIds":["INBOX"]}),
        )
        .await;
    // Invariant: On unknown mutation outcome, retain the durable pending record for idempotent
    // retry.
    if answer.is_err() {
        return Err("snooze_pending_retry");
    }
    store::update(FILE, |v| {
        v[&key]["state"] = json!("sleeping");
        Ok(())
    })?;
    Ok(json!({"ok":true,"until":until}))
}
async fn wake(gmail: &crate::providers::gmail::Session, entry: &Value) -> Result<(), &'static str> {
    let account = account(entry)?;
    let ids = entry["ids"]
        .as_array()
        .filter(|v| !v.is_empty() && v.len() <= 1000)
        .ok_or("inbox_storage_invalid")?;
    let mut wanted = std::collections::HashSet::new();
    for id in ids {
        let id = id.as_str().ok_or("inbox_storage_invalid")?;
        crate::mail::action::validate_message_id(crate::mail::Provider::Gmail, id)?;
        wanted.insert(id);
    }
    let thread = entry["threadId"].as_str().ok_or("inbox_storage_invalid")?;
    let messages = gmail.thread_resources(&account, thread).await?;
    let wake_ids: Vec<&str> = messages
        .iter()
        .filter(|message| {
            wanted.contains(message["id"].as_str().unwrap_or(""))
                && !message["labelIds"]
                    .as_array()
                    .is_some_and(|labels| labels.iter().any(|v| v == "TRASH" || v == "SPAM"))
        })
        .filter_map(|message| message["id"].as_str())
        .collect();
    if !wake_ids.is_empty() {
        gmail.call_settled("gmail.batchModify",&json!({"accountId":account,"ids":wake_ids,"addLabelIds":["INBOX","UNREAD"],"removeLabelIds":[]})).await?;
    }
    Ok(())
}
async fn tick(gmail: &crate::providers::gmail::Session) -> Result<Value, &'static str> {
    let saved = store::read(FILE)?.unwrap_or(json!({}));
    let mut woke = 0;
    let mut failures = 0;
    let mut processed = 0;
    for (key, entry) in saved
        .as_object()
        .ok_or("inbox_storage_invalid")?
        .iter()
        .take(1000)
    {
        if entry["until"].as_i64().ok_or("inbox_storage_invalid")? > now() {
            if entry["state"] == "pending" {
                processed += 1;
                let account = account(entry)?;
                if gmail.call_settled("gmail.batchModify",&json!({"accountId":account,"ids":entry["ids"],"addLabelIds":[],"removeLabelIds":["INBOX"]})).await.is_ok(){store::update(FILE,|v|{v[key]["state"]=json!("sleeping");Ok(())})?;}
            }
            if processed >= 2 {
                break;
            }
            continue;
        }
        processed += 1;
        advance(
            entry["accountId"].as_str().ok_or("inbox_storage_invalid")?,
            entry["threadId"].as_str().ok_or("inbox_storage_invalid")?,
        )?;
        match wake(gmail, entry).await {
            Ok(()) => {
                store::update(FILE, |v| {
                    v.as_object_mut()
                        .ok_or("inbox_storage_invalid")?
                        .remove(key);
                    Ok(())
                })?;
                woke += 1;
            }
            Err(_) => {
                failures += 1;
            }
        }
        if processed >= 2 {
            break;
        }
    }
    Ok(json!({"woke":woke,"failures":failures}))
}
