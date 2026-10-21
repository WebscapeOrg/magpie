use crate::platform::{dirs::AppDirs, private_fs};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{fs::File, io::Read};
type Result<T> = std::result::Result<T, &'static str>;
const LIMIT: u64 = 29 * 1024 * 1024;

fn text<'a>(params: &'a Value, key: &str) -> Result<&'a str> {
    params[key]
        .as_str()
        .filter(|v| !v.is_empty() && v.len() <= 4096 && !v.chars().any(char::is_control))
        .ok_or("invalid_params")
}
fn hash(value: &str) -> String {
    format!("{:x}", Sha256::digest(value.as_bytes()))
}
fn directory(account: &str, scope: &str, create: bool) -> Result<Option<File>> {
    let root = AppDirs::discover()?.state;
    let Some(root) = private_fs::directories(&root, &["omamail", "attachments"], create)? else {
        return Ok(None);
    };
    scoped_directory(&root, account, scope, create)
}
fn scoped_directory(root: &File, account: &str, scope: &str, create: bool) -> Result<Option<File>> {
    let Some(account) = private_fs::open_dir(root, hash(account).as_ref(), create, true)? else {
        return Ok(None);
    };
    private_fs::open_dir(&account, hash(scope).as_ref(), create, true)
}
fn save(directory: &File, name: &str, value: &Value) -> Result<()> {
    let bytes = serde_json::to_vec(value).map_err(|_| "attachment_data_invalid")?;
    if private_fs::available_bytes(directory)? < 1024 * 1024 * 1024 + bytes.len() as u64 {
        return Err("local_disk_low");
    }
    private_fs::atomic_replace(directory, name, &bytes)
}
fn load(directory: &File, name: &str) -> Result<Option<Value>> {
    let Some(file) = private_fs::regular(directory, name, false)? else {
        return Ok(None);
    };
    let mut bytes = Vec::new();
    file.take(LIMIT + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| "attachment_unreadable")?;
    if bytes.len() as u64 > LIMIT {
        return Err("attachment_too_large");
    }
    let record: Value = serde_json::from_slice(&bytes).map_err(|_| "attachment_unreadable")?;
    super::decode(record["data"].as_str().ok_or("attachment_unreadable")?)?;
    Ok(Some(record))
}
pub(crate) fn cached(account: &str, id: &str, part: &str) -> Result<Option<Value>> {
    let Some(dir) = directory(account, "received", false)? else {
        return Ok(None);
    };
    load(&dir, &hash(&json!([id, part]).to_string()))
}
pub(crate) fn cache(account: &str, id: &str, part: &str, value: &Value) -> Result<()> {
    super::decode(value["data"].as_str().ok_or("attachment_data_invalid")?)?;
    let dir = directory(account, "received", true)?.ok_or("attachment_unreadable")?;
    save(&dir, &hash(&json!([id, part]).to_string()), value)
}
pub(crate) fn import(params: &Value) -> Result<Value> {
    let account = text(params, "accountId")?;
    let draft = text(params, "draftKey")?;
    let value = super::read(&json!({"path":text(params,"path")?}))?;
    retain(account, draft, &value)
}
pub(crate) fn retain(account: &str, draft: &str, value: &Value) -> Result<Value> {
    let dir = directory(account, draft, true)?.ok_or("attachment_unreadable")?;
    retain_at(&dir, value)
}
fn retain_at(dir: &File, value: &Value) -> Result<Value> {
    let bytes = super::decode(value["data"].as_str().ok_or("attachment_data_invalid")?)?;
    let mut random = [0; 32];
    rustls::crypto::ring::default_provider()
        .secure_random
        .fill(&mut random)
        .map_err(|_| "random_unavailable")?;
    let handle = format!("{:x}", Sha256::digest(random));
    let record = json!({"filename":super::safe_filename(value["filename"].as_str().unwrap_or("attachment")),
        "mimeType":value["mimeType"].as_str().unwrap_or("application/octet-stream"),
        "size":bytes.len(),"data":value["data"]});
    save(dir, &handle, &record)?;
    Ok(
        json!({"ok":true,"filename":record["filename"],"mimeType":record["mimeType"],"size":record["size"],"handle":handle}),
    )
}
pub(crate) fn hydrate(account: &str, fields: &mut Value) -> Result<()> {
    hydrate_with(account, fields, |account, draft| {
        directory(account, draft, false)
    })
}
fn hydrate_with(
    account: &str,
    fields: &mut Value,
    directory: impl Fn(&str, &str) -> Result<Option<File>>,
) -> Result<()> {
    let draft = fields["draftKey"].as_str().unwrap_or("").to_owned();
    let Some(files) = fields["attachments"].as_array_mut() else {
        return Ok(());
    };
    for file in files {
        let Some(handle) = file
            .get("handle")
            .and_then(Value::as_str)
            .filter(|s| !s.is_empty())
        else {
            continue;
        };
        if draft.is_empty() || handle.len() != 64 || !handle.bytes().all(|b| b.is_ascii_hexdigit())
        {
            return Err("attachment_handle_invalid");
        }
        let dir = directory(account, &draft)?.ok_or("attachment_handle_unavailable")?;
        *file = load(&dir, handle)?.ok_or("attachment_handle_unavailable")?;
    }
    Ok(())
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use std::os::unix::fs::{PermissionsExt, symlink};

    #[test]
    fn handles_are_scoped_to_account_and_draft_and_links_never_load_content() {
        let path = std::env::temp_dir().join(format!(
            "magpie-vault-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir(&path).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o700)).unwrap();
        let root = File::open(&path).unwrap();
        let draft = scoped_directory(&root, "owner@example.test", "draft-a", true)
            .unwrap()
            .unwrap();
        let saved = retain_at(
            &draft,
            &json!({"filename":"example.txt","mimeType":"text/plain","data":"c2VjcmV0"}),
        )
        .unwrap();
        assert!(saved.get("data").is_none());
        let fields = json!({"draftKey":"draft-a","attachments":[saved.clone()]});
        let resolve = |account: &str, scope: &str| scoped_directory(&root, account, scope, false);
        let mut owner = fields.clone();
        hydrate_with("owner@example.test", &mut owner, resolve).unwrap();
        assert_eq!(owner["attachments"][0]["data"], "c2VjcmV0");
        let mut foreign = fields.clone();
        assert_eq!(
            hydrate_with("other@example.test", &mut foreign, resolve),
            Err("attachment_handle_unavailable")
        );
        assert!(foreign["attachments"][0].get("data").is_none());
        foreign["draftKey"] = json!("draft-b");
        assert_eq!(
            hydrate_with("owner@example.test", &mut foreign, resolve),
            Err("attachment_handle_unavailable")
        );
        assert!(foreign["attachments"][0].get("data").is_none());
        let outside = path.join("outside");
        let sentinel = br#"{"data":"c2VudGluZWw="}"#;
        std::fs::write(&outside, sentinel).unwrap();
        let handle = saved["handle"].as_str().unwrap();
        let target = path
            .join(hash("owner@example.test"))
            .join(hash("draft-a"))
            .join(handle);
        std::fs::remove_file(&target).unwrap();
        symlink(&outside, &target).unwrap();
        let mut linked = fields.clone();
        assert!(hydrate_with("owner@example.test", &mut linked, resolve).is_err());
        assert!(linked["attachments"][0].get("data").is_none());
        assert_eq!(std::fs::read(&outside).unwrap(), sentinel);
        std::fs::remove_file(&target).unwrap();
        std::fs::hard_link(&outside, &target).unwrap();
        assert!(hydrate_with("owner@example.test", &mut linked, resolve).is_err());
        assert!(linked["attachments"][0].get("data").is_none());
        assert_eq!(std::fs::read(&outside).unwrap(), sentinel);
        std::fs::remove_dir_all(path).unwrap();
    }
}
