//! Invariant: Durable editor recovery. Stored attachment metadata never authorizes file IO.
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    io::Read,
    path::{Path, PathBuf},
};
const MAX_BYTES: usize = 16 * 1024 * 1024;
#[cfg(test)]
use std::sync::atomic::{AtomicU64, Ordering};
#[cfg(all(test, unix))]
use std::{fs::File, os::fd::AsRawFd};
#[cfg(test)]
static SERIAL: AtomicU64 = AtomicU64::new(0);
type Result<T> = std::result::Result<T, &'static str>;

fn text(value: &Value) -> String {
    match value {
        Value::Null | Value::Bool(false) => String::new(),
        Value::String(s) => s.clone(),
        Value::Number(n) if n.as_f64() == Some(0.0) => String::new(),
        Value::Bool(true) => "true".into(),
        Value::Number(n) => n.to_string(),
        Value::Object(_) => "[object Object]".into(),
        Value::Array(v) => v
            .iter()
            .map(|x| {
                if x.is_null() {
                    String::new()
                } else if x == false {
                    "false".into()
                } else if let Value::Number(n) = x {
                    n.to_string()
                } else {
                    text(x)
                }
            })
            .collect::<Vec<_>>()
            .join(","),
    }
}
fn empty() -> Value {
    json!({"active":false,"returnView":"","draft":null,"parked":[]})
}
fn draft(value: &Value) -> Result<Value> {
    let mut out = json!({});
    for key in [
        "to",
        "cc",
        "bcc",
        "replyTo",
        "subject",
        "body",
        "placedBody",
        "accountId",
        "sourceDraftId",
        "threadId",
        "inReplyTo",
        "fromEmail",
    ] {
        out[key] = json!(text(&value[key]));
    }
    // Invariant: Optional for legacy records. This is app-owned metadata, not text to coerce from
    // another JSON shape; the editor still checks the exact suffix.
    if let Some(quote) = value.get("bodyQuote") {
        let quote = quote.as_str().ok_or("recovery_invalid")?;
        if quote.len() > MAX_BYTES {
            return Err("recovery_too_large");
        }
        out["bodyQuote"] = json!(quote);
    }
    if let Some(id) = value.get("pendingSendId") {
        let id = id.as_str().ok_or("recovery_invalid_send_id")?;
        if id.len() > 1024 || id.chars().any(char::is_control) {
            return Err("recovery_invalid_send_id");
        }
        if !id.is_empty() {
            out["pendingSendId"] = json!(id);
        }
    }
    for key in ["draftKey", "replyMessageId", "agentParentJobId"] {
        if let Some(id) = value.get(key) {
            let id = id
                .as_str()
                .filter(|s| s.len() <= 4096 && !s.chars().any(char::is_control))
                .ok_or("recovery_invalid_send_id")?;
            out[key] = json!(id);
        }
    }
    if value["deliveryUnknown"] == true {
        out["deliveryUnknown"] = json!(true);
    }
    // Invariant: Absence belongs to legacy snapshots: the UI then derives whether the draft was
    // edited from its contents. Preserve explicit false separately.
    if let Some(modified) = value.get("userModified") {
        out["userModified"] = json!(modified.as_bool().ok_or("recovery_invalid_user_modified")?);
    }
    let mode = text(&value["mode"]);
    out["mode"] = json!(if mode.is_empty() {
        "new".to_owned()
    } else {
        mode
    });
    for key in [
        "bodyWasEdited",
        "ccVisible",
        "bccVisible",
        "replyToVisible",
        "fromWasChosen",
    ] {
        out[key] = json!(value[key] == true);
    }
    let people = value["replyRecipients"]
        .as_array()
        .cloned()
        .unwrap_or_default();
    if people.len() > 1024 {
        return Err("recovery_too_large");
    }
    out["replyRecipients"] = json!(
        people
            .iter()
            .map(|v| json!({"email":text(&v["email"]),"display":text(&v["display"])}))
            .collect::<Vec<_>>()
    );
    for key in [
        "originalAttachments",
        "forwardedAttachments",
        "draftAttachments",
    ] {
        let rows = value[key].as_array().cloned().unwrap_or_default();
        if rows.len() > 1000 {
            return Err("recovery_too_large");
        }
        let mut attachments = Vec::new();
        for row in rows {
            let path = text(&row["path"]);
            // Invariant: Recovery stores descriptions only. Relative/control-bearing paths cannot
            // be handed to a later attachment reader or cleanup action.
            if !path.is_empty()
                && (!Path::new(&path).is_absolute()
                    || path.chars().any(char::is_control)
                    || path.split('/').any(|part| part == "." || part == ".."))
            {
                return Err("recovery_attachment_path_invalid");
            }
            let size = row["size"]
                .as_f64()
                .or_else(|| row["size"].as_str().and_then(|s| s.parse().ok()))
                .unwrap_or(0.0)
                .floor()
                .max(0.0);
            let size = if size <= u64::MAX as f64 {
                json!(size as u64)
            } else {
                json!(size)
            };
            attachments.push(json!({"filename":text(&row["filename"]),"mimeType":text(&row["mimeType"]),"size":size,"data":if path.is_empty(){text(&row["data"])}else{String::new()},"path":path,"owned":row["owned"]==true,"attachmentId":text(&row["attachmentId"]),"partId":text(&row["partId"])}));
            if let Some(handle) = row
                .get("handle")
                .and_then(Value::as_str)
                .filter(|h| !h.is_empty())
            {
                if handle.len() != 64 || !handle.bytes().all(|b| b.is_ascii_hexdigit()) {
                    return Err("invalid_params");
                }
                attachments.last_mut().unwrap()["handle"] = json!(handle);
            }
        }
        out[key] = json!(attachments);
    }
    attachment_state(value, &mut out)?;
    Ok(out)
}
struct Owner<'a> {
    draft: &'a str,
    account: &'a str,
}

fn attachment_owner(value: &Value) -> Result<Owner<'_>> {
    let identity = |key| {
        value[key]
            .as_str()
            .filter(|text| {
                !text.is_empty() && text.len() <= 4096 && !text.chars().any(char::is_control)
            })
            .ok_or("recovery_invalid")
    };
    Ok(Owner {
        draft: identity("draftKey")?,
        account: identity("accountId")?,
    })
}

fn attachment_job(value: &Value, owner: Owner<'_>) -> Result<Option<Value>> {
    let object = value.as_object().ok_or("recovery_invalid")?;
    if object
        .keys()
        .any(|key| !["mode", "path", "owner", "accountId"].contains(&key.as_str()))
        || value["owner"] != owner.draft
        || value["accountId"] != owner.account
    {
        return Err("recovery_invalid");
    }
    let mode = value["mode"].as_str().ok_or("recovery_invalid")?;
    let path = value["path"].as_str().ok_or("recovery_invalid")?;
    if matches!(mode, "pick" | "clipboard") {
        if !path.is_empty() {
            return Err("recovery_invalid");
        }
        return Ok(None);
    }
    if !matches!(mode, "read" | "recover" | "recover-owned") {
        return Err("recovery_invalid");
    }
    if path.len() > 4096 {
        return Err("recovery_too_large");
    }
    if !Path::new(path).is_absolute()
        || path.chars().any(char::is_control)
        || path.split('/').any(|part| matches!(part, "." | ".."))
    {
        return Err("recovery_attachment_path_invalid");
    }
    Ok(Some(
        json!({"mode":mode,"path":path,"owner":owner.draft,"accountId":owner.account}),
    ))
}

fn attachment_state(value: &Value, out: &mut Value) -> Result<()> {
    for key in [
        "attachmentSourceMessageId",
        "forwardAttachmentError",
        "attachmentRecoveryError",
    ] {
        let Some(field) = value.get(key) else {
            continue;
        };
        let field = field.as_str().ok_or("recovery_invalid")?;
        if field.len() > 4096 {
            return Err("recovery_too_large");
        }
        if key == "attachmentSourceMessageId" && field.chars().any(char::is_control) {
            return Err("recovery_invalid");
        }
        out[key] = json!(field);
    }
    if let Some(loading) = value.get("forwardAttachmentsLoading") {
        out["forwardAttachmentsLoading"] = json!(loading.as_bool().ok_or("recovery_invalid")?);
    }
    if let Some(serial) = value.get("forwardLoadSerial") {
        out["forwardLoadSerial"] = json!(
            serial
                .as_u64()
                .filter(|serial| *serial <= i32::MAX as u64)
                .ok_or("recovery_invalid")?
        );
    }
    let source = out["attachmentSourceMessageId"].as_str().unwrap_or("");
    if out["forwardAttachmentsLoading"] == true && source.is_empty() {
        return Err("recovery_invalid");
    }
    if !source.is_empty() {
        attachment_owner(value)?;
    }
    let mut interrupted = false;
    if let Some(jobs) = value.get("attachJobs") {
        let jobs = jobs.as_array().ok_or("recovery_invalid")?;
        if jobs.len() > 1000 {
            return Err("recovery_too_large");
        }
        let mut kept = Vec::new();
        for job in jobs {
            match attachment_job(job, attachment_owner(value)?)? {
                Some(job) => kept.push(job),
                None => interrupted = true,
            }
        }
        out["attachJobs"] = json!(kept);
    }
    if let Some(pending) = value.get("pendingAttachment") {
        out["pendingAttachment"] = Value::Null;
        if !pending.is_null() {
            match attachment_job(pending, attachment_owner(value)?)? {
                Some(job) => out["pendingAttachment"] = job,
                None => interrupted = true,
            }
        }
    }
    if interrupted {
        // Invariant: A restarted process cannot replay the old picker or clipboard contents.
        out["attachmentRecoveryError"] = json!(
            "Attachment selection was interrupted. Choose the files or paste the image again."
        );
    }
    Ok(())
}

fn meaningful(d: &Value) -> bool {
    if d["forwardAttachmentsLoading"] == true
        || [
            "attachmentSourceMessageId",
            "forwardAttachmentError",
            "attachmentRecoveryError",
        ]
        .iter()
        .any(|key| d[key].as_str().is_some_and(|text| !text.is_empty()))
        || d["attachJobs"]
            .as_array()
            .is_some_and(|jobs| !jobs.is_empty())
        || d["pendingAttachment"].is_object()
    {
        return true;
    }
    if d["userModified"] == true {
        return true;
    }
    for key in ["to", "cc", "bcc", "subject"] {
        if !text(&d[key]).trim().is_empty() {
            return true;
        }
    }
    if (d["bodyWasEdited"] == true || d["body"] != d["placedBody"])
        && !text(&d["body"]).trim().is_empty()
    {
        return true;
    }
    ["forwardedAttachments", "draftAttachments"]
        .iter()
        .any(|k| d[k].as_array().is_some_and(|a| !a.is_empty()))
}
pub fn normalize(value: &Value) -> Result<Value> {
    if value["version"] != 1 || value["active"] != true {
        return Ok(empty());
    }
    let saved = draft(&value["draft"])?;
    if !meaningful(&saved) {
        return Ok(empty());
    }
    let parked = value["parked"].as_array().cloned().unwrap_or_default();
    if parked.len() > 64 {
        return Err("recovery_too_large");
    }
    let mut others = Vec::new();
    for row in parked {
        let row = draft(&row)?;
        if meaningful(&row) {
            others.push(row);
        }
    }
    let view = text(&value["returnView"]);
    Ok(
        json!({"active":true,"returnView":if ["reader","calendar"].contains(&view.as_str()){view}else{"list".into()},"draft":saved,"parked":others}),
    )
}
fn home() -> Result<PathBuf> {
    Ok(crate::platform::dirs::AppDirs::discover()?.config)
}
fn revision(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}
fn record(bytes: &[u8]) -> Result<Value> {
    match serde_json::from_slice::<Value>(bytes) {
        Ok(v) => normalize(&v),
        Err(_) => Ok(empty()),
    }
}
pub fn call(method: &str, params: &Value) -> Result<Value> {
    call_at(&home()?, method, params)
}
fn call_at(root: &Path, method: &str, params: &Value) -> Result<Value> {
    if !matches!(method, "compose.recoveryRead" | "compose.recoverySave") {
        return Err("unknown_method");
    }
    let writing = method == "compose.recoverySave";
    let bytes = if writing {
        if !params["record"].is_object()
            || params["record"]["version"] != 1
            || !params["record"]["active"].is_boolean()
        {
            return Err("recovery_invalid");
        }
        let value = normalize(&params["record"])?;
        let mut stored = value.clone();
        stored["version"] = json!(1);
        let bytes = serde_json::to_vec(&stored).map_err(|_| "recovery_invalid")?;
        if bytes.len() > MAX_BYTES {
            return Err("recovery_too_large");
        }
        if params["expectedRevision"].as_str().is_none() {
            return Err("invalid_params");
        }
        bytes
    } else {
        Vec::new()
    };
    let Some(dir) = crate::cache::directories(root, &["omamail"], writing)? else {
        return Ok(json!({"record":empty(),"revision":revision(&[])}));
    };
    let _lock = if writing {
        Some(
            crate::platform::private_fs::lock_exclusive(&dir, ".compose.lock").map_err(
                |error| {
                    if error == "private_fs_busy" {
                        "recovery_busy"
                    } else {
                        error
                    }
                },
            )?,
        )
    } else {
        None
    };
    let mut old = Vec::new();
    if let Some(file) = crate::cache::regular(&dir, "compose.json", false)? {
        file.take(MAX_BYTES as u64 + 1)
            .read_to_end(&mut old)
            .map_err(|_| "recovery_unavailable")?;
    }
    if old.len() > MAX_BYTES {
        return Err("recovery_too_large");
    }
    if !writing {
        return Ok(json!({"record":record(&old)?,"revision":revision(&old)}));
    }
    if params["expectedRevision"] != revision(&old) {
        return Err("recovery_conflict");
    }
    crate::platform::private_fs::atomic_replace(&dir, "compose.json", &bytes).map_err(|error| {
        if error == "cache_unavailable" {
            "recovery_unavailable"
        } else {
            error
        }
    })?;
    Ok(json!({"record":record(&bytes)?,"revision":revision(&bytes)}))
}

#[cfg(test)]
mod tests;
