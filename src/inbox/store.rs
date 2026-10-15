use crate::platform::{dirs::AppDirs, private_fs as fs};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::{fs::File, io::Read};
pub fn key(parts: &[&str]) -> String {
    let mut hash = Sha256::new();
    for part in parts {
        hash.update((part.len() as u64).to_le_bytes());
        hash.update(part.as_bytes());
    }
    format!("{:x}.json", hash.finalize())
}
fn directory() -> Result<File, &'static str> {
    fs::directories(&AppDirs::discover()?.state, &["omamail", "inbox"], true)?
        .ok_or("inbox_storage_unavailable")
}
pub fn read(name: &str) -> Result<Option<Value>, &'static str> {
    let dir = directory()?;
    let Some(file) = fs::regular_readonly(&dir, name)? else {
        return Ok(None);
    };
    let mut bytes = Vec::new();
    file.take(8 * 1024 * 1024 + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| "inbox_storage_unavailable")?;
    if bytes.len() > 8 * 1024 * 1024 {
        return Err("inbox_storage_invalid");
    }
    serde_json::from_slice(&bytes)
        .map(Some)
        .map_err(|_| "inbox_storage_invalid")
}
pub fn write(name: &str, value: &Value) -> Result<(), &'static str> {
    let dir = directory()?;
    let bytes = serde_json::to_vec(value).map_err(|_| "inbox_storage_invalid")?;
    if bytes.len() > 8 * 1024 * 1024 {
        return Err("inbox_storage_invalid");
    }
    fs::atomic_replace(&dir, name, &bytes)?;
    fs::sync_dir(&dir)
}
pub fn update<T>(
    name: &str,
    run: impl FnOnce(&mut Value) -> Result<T, &'static str>,
) -> Result<T, &'static str> {
    let dir = directory()?;
    let _lock = fs::lock_exclusive(&dir, ".lock")?;
    let mut value = read(name)?.unwrap_or(serde_json::json!({}));
    let result = run(&mut value)?;
    write(name, &value)?;
    Ok(result)
}

pub fn cache(name: &str, value: &Value) -> Result<(), &'static str> {
    let dir = directory()?;
    let _lock = fs::lock_exclusive(&dir, ".cache-lock")?;
    let mut entries = Vec::new();
    let mut total = 0u64;
    for name in fs::names(&dir)? {
        if !name.starts_with("avatar-") {
            continue;
        }
        if let Some(file) = fs::regular_readonly(&dir, &name)? {
            let metadata = file.metadata().map_err(|_| "inbox_storage_unavailable")?;
            total += metadata.len();
            entries.push((
                metadata
                    .modified()
                    .map_err(|_| "inbox_storage_unavailable")?,
                name,
                metadata.len(),
            ));
        }
    }
    entries.sort_by_key(|entry| entry.0);
    let mut count = entries.len();
    for (_, name, bytes) in entries {
        if count < 1024 && total < 128 * 1024 * 1024 {
            break;
        }
        fs::remove_owned(&dir, &name)?;
        count -= 1;
        total = total.saturating_sub(bytes);
    }
    write(name, value)
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use std::os::unix::fs::{PermissionsExt, symlink};
    #[test]
    fn private_store_refuses_links_and_keeps_sender_bytes_out_of_paths() {
        if crate::mail::tests::isolated() {
            return;
        }
        let fixture = crate::mail::tests::account_fixture(
            serde_json::json!({"version":1,"activeId":"a@example.org","accounts":[{"email":"a@example.org"}]}),
        );
        let name = key(&["../hostile\n", "../../private"]);
        assert!(
            name.bytes()
                .all(|v| v.is_ascii_hexdigit() || b".json".contains(&v))
        );
        write(
            &name,
            &serde_json::json!({"text":"synthetic private overview"}),
        )
        .unwrap();
        let directory = fixture.state.join("omamail/inbox");
        assert_eq!(
            std::fs::metadata(&directory).unwrap().permissions().mode() & 0o777,
            0o700
        );
        assert_eq!(
            std::fs::metadata(directory.join(&name))
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o600
        );
        let target = fixture.root.join("do-not-change");
        std::fs::write(&target, b"untouched").unwrap();
        symlink(&target, directory.join("linked.json")).unwrap();
        assert!(read("linked.json").is_err());
        assert!(write("linked.json", &serde_json::json!({"text":"forbidden"})).is_err());
        assert_eq!(std::fs::read(&target).unwrap(), b"untouched");
    }
}
