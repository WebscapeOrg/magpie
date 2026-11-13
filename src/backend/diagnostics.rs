use serde::{Deserialize, Serialize};
use std::{
    collections::VecDeque,
    io::Read,
    sync::{
        OnceLock,
        atomic::{AtomicU64, Ordering},
        mpsc,
    },
    time::{Duration, Instant},
};

const CAPACITY: usize = 512;
static WRITER: OnceLock<mpsc::SyncSender<Command>> = OnceLock::new();
static SERIAL: AtomicU64 = AtomicU64::new(1);
static DROPPED: AtomicU64 = AtomicU64::new(0);
tokio::task_local! {pub(crate) static CORRELATION:u64;}
pub(crate) fn next() -> u64 {
    SERIAL.fetch_add(1, Ordering::Relaxed)
}
pub(crate) fn current() -> u64 {
    CORRELATION.try_with(|value| *value).unwrap_or(0)
}
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
struct Event {
    #[serde(default)]
    time_ms: u64,
    process: u32,
    request: u64,
    method: String,
    queue_us: u64,
    elapsed_us: u64,
    request_bytes: usize,
    success: bool,
    #[serde(default)]
    error: Option<String>,
}

fn error_code(error: &str) -> &str {
    match error {
        "invalid_params"
        | "unknown_method"
        | "request_timed_out"
        | "local_account_unknown"
        | "local_disk_full"
        | "local_disk_low"
        | "local_storage_corrupt"
        | "local_storage_unavailable"
        | "local_schema_newer"
        | "local_sqlite_update_required"
        | "local_owner_unavailable"
        | "local_edit_id_conflict"
        | "local_edit_already_started"
        | "local_search_unsupported"
        | "local_search_invalid"
        | "local_search_too_long"
        | "cache_unsafe_path"
        | "cache_unavailable"
        | "private_fs_busy"
        | "auth_signed_out"
        | "gmail_rate_limited"
        | "gmail_request_deferred"
        | "gmail_server_rate_limited"
        | "gmail_timeout" => error,
        _ => "unknown_error",
    }
}
enum Command {
    Event(Event),
    Flush(mpsc::SyncSender<()>),
}
fn valid(event: &Event) -> bool {
    super::methods::ALL.contains(&event.method.as_str())
        && event
            .error
            .as_deref()
            .is_none_or(|error| error_code(error) == error)
}
pub(super) fn record(
    request: u64,
    method: &str,
    queue_us: u64,
    elapsed: Duration,
    request_bytes: usize,
    error: Option<&str>,
) {
    let event = Event {
        time_ms: std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis()
            .min(u64::MAX as u128) as u64,
        process: std::process::id(),
        request,
        method: method.into(),
        queue_us,
        elapsed_us: elapsed.as_micros().min(u64::MAX as u128) as u64,
        request_bytes,
        success: error.is_none(),
        error: error.map(|error| error_code(error).to_owned()),
    };
    if !valid(&event) {
        return;
    }
    #[cfg(test)]
    return;
    #[allow(unreachable_code)]
    let writer = WRITER.get_or_init(|| {
        let (sender, receiver) = mpsc::sync_channel(CAPACITY);
        let _ = std::thread::Builder::new()
            .name("rpc-diagnostics".into())
            .spawn(move || {
                let mut pending = Vec::new();
                let mut deadline = Instant::now() + Duration::from_secs(2);
                loop {
                    match receiver.recv_timeout(deadline.saturating_duration_since(Instant::now()))
                    {
                        Ok(Command::Event(event)) => pending.push(event),
                        Ok(Command::Flush(done)) => {
                            persist(&mut pending);
                            let _ = done.send(());
                        }
                        Err(mpsc::RecvTimeoutError::Timeout) => (),
                        Err(mpsc::RecvTimeoutError::Disconnected) => {
                            persist(&mut pending);
                            break;
                        }
                    }
                    if pending.len() >= 64 || Instant::now() >= deadline {
                        persist(&mut pending);
                        deadline = Instant::now() + Duration::from_secs(2);
                    }
                }
            });
        sender
    });
    if writer.try_send(Command::Event(event)).is_err() {
        DROPPED.fetch_add(1, Ordering::Relaxed);
    }
}
fn persist(batch: &mut Vec<Event>) {
    use crate::platform::{dirs::AppDirs, private_fs as fs};
    if batch.is_empty() {
        return;
    }
    let pending = std::mem::take(batch);
    let count = pending.len() as u64;
    let write = || -> Result<(), &'static str> {
        let dirs = AppDirs::discover()?;
        let dir = fs::directories(&dirs.state, &["omamail", "diagnostics"], true)?
            .ok_or("cache_unavailable")?;
        let _lock = fs::lock_exclusive(&dir, ".rpc.lock")?;
        let mut events = VecDeque::new();
        if let Some(file) = fs::regular(&dir, "rpc.json", false)? {
            let mut bytes = Vec::new();
            file.take(131073)
                .read_to_end(&mut bytes)
                .map_err(|_| "cache_unavailable")?;
            if bytes.len() <= 131072 {
                events = serde_json::from_slice(&bytes).unwrap_or_default();
            }
        }
        events.retain(valid);
        events.extend(pending);
        while events.len() > 256 {
            events.pop_front();
        }
        let bytes = serde_json::to_vec(&events).map_err(|_| "cache_unavailable")?;
        fs::atomic_replace(&dir, "rpc.json", &bytes)?;
        fs::atomic_replace(
            &dir,
            "rpc-writer.json",
            serde_json::json!({"dropped":DROPPED.load(Ordering::Relaxed)})
                .to_string()
                .as_bytes(),
        )
    };
    if write().is_err() {
        DROPPED.fetch_add(count, Ordering::Relaxed);
    }
}
pub(super) async fn flush() {
    let Some(writer) = WRITER.get() else { return };
    let writer = writer.clone();
    let _ = tokio::time::timeout(
        Duration::from_secs(3),
        tokio::task::spawn_blocking(move || {
            let (sender, receiver) = mpsc::sync_channel(1);
            if writer.try_send(Command::Flush(sender)).is_ok() {
                let _ = receiver.recv_timeout(Duration::from_secs(2));
            }
        }),
    )
    .await;
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn records_have_no_caller_supplied_content_and_a_full_queue_never_waits() {
        let event = Event {
            time_ms: 1,
            process: 1,
            request: 1,
            method: "reader.open".into(),
            queue_us: 0,
            elapsed_us: 1,
            request_bytes: 1,
            success: true,
            error: None,
        };
        let value = serde_json::to_value(&event).unwrap();
        assert_eq!(value.as_object().unwrap().len(), 9);
        assert_eq!(error_code("local_disk_full"), "local_disk_full");
        for code in [
            "local_search_unsupported",
            "local_search_invalid",
            "local_search_too_long",
        ] {
            assert_eq!(error_code(code), code);
            assert_eq!(
                error_code(&format!("{code}: from:private@example.org")),
                "unknown_error"
            );
        }
        assert_eq!(
            error_code("secret@example.org\nBearer private"),
            "unknown_error"
        );
        assert!(valid(&event));
        assert!(!valid(&Event {
            method: "secret@example.org".into(),
            ..event
        }));
        let (sender, _receiver) = mpsc::sync_channel(1);
        sender.try_send(1).unwrap();
        assert!(matches!(
            sender.try_send(2),
            Err(mpsc::TrySendError::Full(2))
        ));
    }
}
