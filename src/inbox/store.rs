use crate::platform::{dirs::AppDirs, private_fs as fs};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::{fs::File, io::Read};
#[cfg(any(feature = "mobile", all(feature = "agent", unix, not(target_os = "ios"))))]
use std::time::{Duration, Instant};
/// How long a change under a waiting lock waits for another holder before reporting it busy.
#[cfg(any(feature = "mobile", all(feature = "agent", unix, not(target_os = "ios"))))]
const LOCK_WAIT: Duration = Duration::from_secs(2);
pub fn key(parts: &[&str]) -> String {
    let mut hash = Sha256::new();
    for part in parts {
        hash.update((part.len() as u64).to_le_bytes());
        hash.update(part.as_bytes());
    }
    format!("{:x}.json", hash.finalize())
}
/// Takes the lock `name`, waiting for another holder up to `LOCK_WAIT`; one still held then is
/// reported as `private_fs_busy`. The wait blocks the calling thread, so callers run it on a
/// blocking thread, never on the engine's request thread.
#[cfg(any(feature = "mobile", all(feature = "agent", unix, not(target_os = "ios"))))]
fn wait_for(dir: &File, name: &str) -> Result<impl Sized, &'static str> {
    let deadline = Instant::now() + LOCK_WAIT;
    loop {
        match fs::lock_exclusive(dir, name) {
            Err("private_fs_busy") if Instant::now() < deadline => {
                std::thread::sleep(Duration::from_millis(5));
            }
            other => return other,
        }
    }
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
fn encode(value: &Value) -> Result<Vec<u8>, &'static str> {
    let bytes = serde_json::to_vec(value).map_err(|_| "inbox_storage_invalid")?;
    if bytes.len() > 8 * 1024 * 1024 {
        return Err("inbox_storage_invalid");
    }
    Ok(bytes)
}
/// Makes every write fail, for tests of a write that is refused. Each test runs in its own process.
#[cfg(test)]
pub(crate) static REFUSE_WRITES: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

pub fn write(name: &str, value: &Value) -> Result<(), &'static str> {
    #[cfg(test)]
    if REFUSE_WRITES.load(std::sync::atomic::Ordering::SeqCst) {
        return Err("inbox_storage_unavailable");
    }
    let bytes = encode(value)?;
    let dir = directory()?;
    fs::atomic_replace(&dir, name, &bytes)?;
    fs::sync_dir(&dir)
}
/// Writes `value` under the lock `update` takes, for a file `update` cannot read.
pub fn replace(name: &str, value: &Value) -> Result<(), &'static str> {
    let dir = directory()?;
    let _lock = fs::lock_exclusive(&dir, ".lock")?;
    write(name, value)
}
pub fn remove(name: &str) -> Result<(), &'static str> {
    let dir = directory()?;
    fs::remove_owned(&dir, name)?;
    fs::sync_dir(&dir)
}
pub fn update<T>(
    name: &str,
    run: impl FnOnce(&mut Value) -> Result<T, &'static str>,
) -> Result<T, &'static str> {
    let dir = directory()?;
    let _lock = fs::lock_exclusive(&dir, ".lock")?;
    change(name, run)
}

/// Changes `name` under its own lock `lock` instead of `.lock`, waiting briefly for another
/// holder. Invariant: only files changed under `lock` alone use it, so a long write there never
/// holds up the changes made under `.lock`, and those never wait.
#[cfg(any(feature = "mobile", all(feature = "agent", unix, not(target_os = "ios"))))]
pub(crate) fn update_waiting<T>(
    lock: &str,
    name: &str,
    run: impl FnOnce(&mut Value) -> Result<T, &'static str>,
) -> Result<T, &'static str> {
    let dir = directory()?;
    let _lock = wait_for(&dir, lock)?;
    change(name, run)
}

fn change<T>(
    name: &str,
    run: impl FnOnce(&mut Value) -> Result<T, &'static str>,
) -> Result<T, &'static str> {
    let mut value = read(name)?.unwrap_or(serde_json::json!({}));
    let result = run(&mut value)?;
    write(name, &value)?;
    Ok(result)
}

pub fn cache(name: &str, value: &Value) -> Result<(), &'static str> {
    let bytes = encode(value)?;
    let dir = directory()?;
    let _lock = fs::lock_exclusive(&dir, ".cache-lock")?;
    fs::regular_readonly(&dir, name)?;
    let mut entries = Vec::new();
    let mut total = bytes.len() as u64;
    for entry_name in fs::names(&dir)? {
        if entry_name == name {
            continue;
        }
        let name = entry_name;
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
    let mut count = entries.len() + 1;
    for (_, name, bytes) in entries {
        if count <= 1024 && total <= 128 * 1024 * 1024 {
            break;
        }
        fs::remove_owned(&dir, &name)?;
        count -= 1;
        total = total.saturating_sub(bytes);
    }
    fs::atomic_replace(&dir, name, &bytes)?;
    fs::sync_dir(&dir)
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use std::os::unix::fs::{PermissionsExt, symlink};
    #[test]
    fn avatar_cache_reserves_incoming_bytes_before_writing() {
        if crate::mail::tests::isolated() {
            return;
        }
        let fixture =
            crate::mail::tests::account_fixture(serde_json::json!({"version":1,"accounts":[]}));
        let dir = directory().unwrap();
        drop(dir);
        let path = fixture.state.join("omamail/inbox/avatar-old.json");
        File::create(&path)
            .unwrap()
            .set_len(128 * 1024 * 1024 - 1)
            .unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).unwrap();
        cache("avatar-new.json", &serde_json::json!({"image":"new"})).unwrap();
        assert!(!path.exists());
        assert_eq!(read("avatar-new.json").unwrap().unwrap()["image"], "new");
    }
    #[test]
    fn avatar_cache_rejects_oversized_writes_without_eviction() {
        if crate::mail::tests::isolated() {
            return;
        }
        let fixture =
            crate::mail::tests::account_fixture(serde_json::json!({"version":1,"accounts":[]}));
        let dir = directory().unwrap();
        drop(dir);
        let path = fixture.state.join("omamail/inbox/avatar-old.json");
        File::create(&path)
            .unwrap()
            .set_len(128 * 1024 * 1024)
            .unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).unwrap();
        assert_eq!(
            cache(
                "avatar-new.json",
                &Value::String("x".repeat(8 * 1024 * 1024))
            ),
            Err("inbox_storage_invalid")
        );
        assert!(path.exists());
        assert!(read("avatar-new.json").unwrap().is_none());
    }
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
