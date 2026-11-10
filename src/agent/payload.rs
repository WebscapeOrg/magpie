//! Validation of assistant requests and their mail context, shared by the desktop's job workers and the
//! phone's own assistant. Pure: no processes, files or network.
use serde_json::{Value, json};
use std::time::{SystemTime, UNIX_EPOCH};
type Result<T> = std::result::Result<T, &'static str>;
pub const INPUT_LIMIT: usize = 1024 * 1024;
/// A job id: 32 lowercase hexadecimal characters.
pub fn check_id(id: &str) -> Result<()> {
    if id.len() == 32
        && id
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
    {
        Ok(())
    } else {
        Err("agent_invalid_id")
    }
}
pub fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}
pub fn text(value: &Value) -> Result<&str> {
    let text = value.as_str().ok_or("agent_invalid_text")?;
    if text.chars().any(|character| {
        (character < ' ' && !matches!(character, '\t' | '\r' | '\n'))
            || ('\u{7f}'..='\u{9f}').contains(&character)
    }) {
        return Err("agent_invalid_text");
    }
    Ok(text)
}
pub fn session(session: &str) -> bool {
    let bytes = session.as_bytes();
    bytes.len() == 36
        && bytes.iter().enumerate().all(|(index, byte)| {
            if [8, 13, 18, 23].contains(&index) {
                *byte == b'-'
            } else {
                byte.is_ascii_hexdigit()
            }
        })
}

pub fn validate_draft(value: &Value) -> Result<()> {
    let draft = value.as_object().ok_or("agent_invalid_draft")?;
    for (key, value) in draft {
        if !["to", "cc", "bcc", "subject", "body", "from"].contains(&key.as_str()) {
            return Err("agent_invalid_draft");
        }
        text(value)?;
    }
    Ok(())
}

pub fn validate_messages(value: &Value, limit: usize) -> Result<()> {
    let entries = value
        .as_array()
        .filter(|entries| !entries.is_empty() && entries.len() <= limit)
        .ok_or("agent_invalid_messages")?;
    for entry in entries {
        let entry = entry
            .as_object()
            .filter(|entry| {
                entry.len() == 2 && entry.contains_key("messageId") && entry.contains_key("message")
            })
            .ok_or("agent_invalid_messages")?;
        for value in entry.values() {
            text(value)?;
        }
    }
    Ok(())
}

pub fn validate_mail_update(value: &Value) -> Result<()> {
    let update = value.as_object().ok_or("agent_invalid_context")?;
    if ["accountId", "messageId", "message"]
        .iter()
        .any(|key| !update.contains_key(*key))
    {
        return Err("agent_invalid_context");
    }
    for (key, value) in update {
        match key.as_str() {
            "accountId" | "messageId" => {
                if text(value)?.chars().count() > 4096 {
                    return Err("agent_identifier_too_large");
                }
            }
            "message" | "threadContext" => {
                text(value)?;
            }
            "threadMessages" => validate_messages(value, 100)?,
            _ => return Err("agent_invalid_context"),
        }
    }
    Ok(())
}

pub fn validate_payload(value: &Value) -> Result<Value> {
    let o = value.as_object().ok_or("agent_invalid_context")?;
    if serde_json::to_vec(value)
        .map_err(|_| "agent_invalid_context")?
        .len()
        > INPUT_LIMIT
    {
        return Err("agent_context_too_large");
    }
    if o.contains_key("parent")
        && (!o.contains_key("prompt")
            || o.keys()
                .any(|k| !["parent", "prompt", "draftUpdate", "mailUpdate"].contains(&k.as_str())))
    {
        return Err("agent_continuation_override");
    }
    for (k, v) in o {
        match k.as_str() {
            "mailUpdate" => {
                if !o.contains_key("parent") {
                    return Err("agent_continuation_override");
                }
                validate_mail_update(v)?;
            }
            "draftUpdate" => {
                if !o.contains_key("parent") {
                    return Err("agent_invalid_draft");
                }
                let update = v.as_object().ok_or("agent_invalid_draft")?;
                if update.keys().any(|k| {
                    !["accountId", "draftKey", "draft", "messageId", "envelope"]
                        .contains(&k.as_str())
                }) || !update.contains_key("draft")
                {
                    return Err("agent_invalid_draft");
                }
                for key in ["accountId", "draftKey"] {
                    let id = text(&v[key])?;
                    if id.is_empty() || id.len() > 4096 {
                        return Err("agent_invalid_draft");
                    }
                }
                if let Some(message) = update.get("messageId") {
                    if text(message)?.is_empty() {
                        return Err("agent_invalid_draft");
                    }
                }
                let draft = v["draft"].as_object().ok_or("agent_invalid_draft")?;
                if draft.len() != 6
                    || ["from", "to", "cc", "bcc", "subject", "body"]
                        .iter()
                        .any(|key| !draft.contains_key(*key))
                {
                    return Err("agent_invalid_draft");
                }
                validate_draft(&v["draft"])?;
                if let Some(envelope) = v.get("envelope") {
                    super::proposals::envelope(envelope, &v["accountId"], &v["draftKey"])?;
                }
            }
            "envelope" => super::proposals::envelope(v, &value["accountId"], &value["draftKey"])?,
            "messages" => validate_messages(v, 20)?,
            "threadMessages" => validate_messages(v, 100)?,
            "draft" => validate_draft(v)?,
            // Invariant: A look for calendar events: one message, the fixed ask, no draft
            // and no continuation — a look answers once and is not talked to.
            "events" => {
                if v != true
                    || o.contains_key("messages")
                    || o.contains_key("draft")
                    || o.contains_key("parent")
                    || o["messageId"].as_str().unwrap_or("").is_empty()
                {
                    return Err("agent_invalid_events");
                }
            }
            "accountId" | "account" | "messageId" | "subject" | "prompt" | "message"
            | "threadContext" | "draftKey" | "draftFingerprint" | "parent" | "folder" => {
                let s = text(v)?;
                if [
                    "accountId",
                    "messageId",
                    "subject",
                    "draftKey",
                    "draftFingerprint",
                ]
                .contains(&k.as_str())
                    && s.chars().count() > 4096
                {
                    return Err("agent_identifier_too_large");
                }
                if k == "parent" {
                    check_id(s)?;
                }
            }
            _ => return Err("agent_unsupported_context"),
        }
    }
    if value["prompt"].as_str().unwrap_or("").trim().is_empty() {
        return Err("agent_prompt_required");
    }
    Ok(value.clone())
}
pub fn draft_payload(value: &Value) -> Result<Value> {
    let object = value.as_object().ok_or("agent_invalid_draft")?;
    if object
        .keys()
        .any(|k| !["draftFields", "ask", "account", "accountId"].contains(&k.as_str()))
    {
        return Err("agent_invalid_draft");
    }
    let fields = value["draftFields"]
        .as_object()
        .ok_or("agent_invalid_draft")?;
    let get = |key: &str| -> Result<String> {
        fields
            .get(key)
            .map(text)
            .transpose()
            .map(|s| s.unwrap_or("").to_owned())
    };
    let from = get("from")?;
    let to = get("to")?;
    let subject = get("subject")?;
    let body = get("body")?;
    let hash = draft_fingerprint(&json!({"from":from,"to":to,"subject":subject,"body":body}))?;
    let account = text(&value["account"])?;
    let owner = text(&value["accountId"])?;
    let title = subject.trim();
    let mut payload = validate_payload(
        &json!({"messageId":"","accountId":owner,"draftKey":get("draftKey")?,"draftFingerprint":hash,"draft":{"from":if from.is_empty(){account}else{&from},"to":to,"cc":get("cc")?,"bcc":get("bcc")?,"subject":subject,"body":body},"account":account,"subject":if title.is_empty(){"Draft".to_owned()}else{format!("Draft: {title}")},"prompt":text(&value["ask"])?.trim(),"message":""}),
    )?;
    if let Some(envelope) = fields.get("envelope") {
        payload["envelope"] = envelope.clone();
    }
    validate_payload(&payload)
}

pub fn draft_fingerprint(draft: &Value) -> Result<String> {
    let fields: Vec<&str> = ["from", "to", "subject", "body"]
        .iter()
        .map(|key| draft[key].as_str().unwrap_or(""))
        .collect();
    let serialized = serde_json::to_string(&fields).map_err(|_| "agent_invalid_draft")?;
    // Algorithm: Match the existing UI-only change indicator, including JavaScript f64 multiplication.
    let mut hash = 2166136261u32;
    for code in serialized.encode_utf16() {
        let signed = (hash ^ code as u32) as i32;
        hash = ((signed as f64 * 16777619f64).rem_euclid(4294967296f64)) as u32;
    }
    Ok(hash.to_string())
}
pub fn context_kind(context: &Value) -> &'static str {
    if context["draft"].is_object() {
        "draft"
    } else if super::events::is_look(context) {
        "events"
    } else {
        "message"
    }
}
pub fn context_message_ids(context: &Value) -> Value {
    if let Some(messages) = context["messages"].as_array() {
        json!(
            messages
                .iter()
                .map(|message| message["messageId"].clone())
                .collect::<Vec<_>>()
        )
    } else if !context["messageId"].as_str().unwrap_or("").is_empty() {
        json!([context["messageId"]])
    } else {
        json!([])
    }
}

/// The context a follow-up turn runs with: the previous turn's context refreshed by the follow-up's
/// mail or draft update, with the follow-up's prompt.
pub fn continue_context(mut previous: Value, continuation: &Value, parent: &str) -> Result<Value> {
    previous
        .as_object_mut()
        .ok_or("agent_invalid_context")?
        .remove("parent");
    if let Some(update) = continuation.get("mailUpdate") {
        if previous["accountId"] != update["accountId"]
            || previous["messageId"] != update["messageId"]
            || previous.get("messages").is_some()
        {
            return Err("agent_continuation_override");
        }
        for key in ["message", "threadMessages", "threadContext"] {
            previous
                .as_object_mut()
                .ok_or("agent_invalid_context")?
                .remove(key);
            if let Some(value) = update.get(key) {
                previous[key] = value.clone();
            }
        }
    }
    if let Some(update) = continuation.get("draftUpdate") {
        // Invariant: A follow-up can refresh content, never redirect its ownership.
        let attaching = previous["messageId"]
            .as_str()
            .is_some_and(|s| !s.is_empty())
            && update["messageId"] == previous["messageId"]
            && previous.get("messages").is_none()
            && !previous["draft"].is_object()
            && previous["draftKey"].as_str().unwrap_or("").is_empty();
        if update["accountId"] != previous["accountId"]
            || (!attaching
                && (update["draftKey"] != previous["draftKey"] || !previous["draft"].is_object()))
        {
            return Err("agent_continuation_override");
        }
        if attaching {
            previous["draftKey"] = update["draftKey"].clone();
        }
        previous["draft"] = update["draft"].clone();
        previous
            .as_object_mut()
            .ok_or("agent_invalid_context")?
            .remove("envelope");
        if let Some(envelope) = update.get("envelope") {
            previous["envelope"] = envelope.clone();
        }
        previous["draftFingerprint"] = draft_fingerprint(&previous["draft"])?.into();
    }
    previous["parent"] = json!(parent);
    previous["prompt"] = continuation["prompt"].clone();
    Ok(previous)
}
