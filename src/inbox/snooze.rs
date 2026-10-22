use super::{account, fields, now, store};
use serde_json::{Value, json};
const FILE: &str = "snoozes.json";
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
    let entry = json!({"accountId":account,"id":id,"ids":ids,"until":until,"state":"pending","subject":crate::message::content::summarize(&resource,now())?["subject"],"threadId":thread});
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
