use serde::{Deserialize, Serialize};
use std::{io::Read, path::Path};

const LIMIT: usize = 65536;
const RECORDS: usize = 200;
static OPERATIONS: std::sync::Mutex<()> = std::sync::Mutex::new(());
static WRITER: std::sync::OnceLock<std::sync::mpsc::SyncSender<Command>> =
    std::sync::OnceLock::new();
static DROPPED: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);

enum Command {
    Event(Event),
    Flush(std::sync::mpsc::SyncSender<()>),
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct Event {
    pub time: String,
    pub process: u32,
    pub session: u64,
    pub request: u64,
    #[serde(default)]
    pub rpc: u64,
    pub operation: String,
    pub lane: String,
    pub cost: u32,
    pub attempt: usize,
    pub status: Option<u16>,
    pub reason: String,
    pub retry_after_ms: Option<u64>,
    pub wait_ms: u64,
    pub elapsed_ms: u64,
    pub outcome: String,
}

impl Event {
    fn valid(&self) -> bool {
        self.time.len() == 20
            && chrono::NaiveDateTime::parse_from_str(&self.time, "%Y-%m-%dT%H:%M:%SZ").is_ok()
            && matches!(
                self.operation.as_str(),
                "getProfile"
                    | "history.list"
                    | "labels.list"
                    | "labels.get"
                    | "settings.sendAs.list"
                    | "messages.list"
                    | "messages.get.full"
                    | "messages.get.metadata"
                    | "messages.attachments.get"
                    | "threads.get.full"
                    | "threads.get.metadata"
                    | "drafts.list"
                    | "messages.send"
                    | "messages.batchModify"
                    | "messages.modify"
                    | "messages.trash"
                    | "messages.untrash"
                    | "labels.create"
                    | "labels.update"
                    | "labels.delete"
                    | "drafts.create"
                    | "drafts.update"
                    | "drafts.delete"
                    | "oauth.refresh"
                    | "gmail.request"
            )
            && matches!(
                self.lane.as_str(),
                "interactive" | "background" | "poll" | "queue" | "auth"
            )
            && matches!(
                self.reason.as_str(),
                "unknown"
                    | "localBudget"
                    | "serverCooldown"
                    | "rateLimitExceeded"
                    | "userRateLimitExceeded"
                    | "dailyLimitExceeded"
                    | "insufficientPermissions"
                    | "domainPolicy"
                    | "authError"
                    | "sessionInvalidated"
            )
            && matches!(
                self.outcome.as_str(),
                "ok" | "gmail_rate_limited"
                    | "gmail_request_deferred"
                    | "gmail_server_rate_limited"
                    | "gmail_not_found"
                    | "gmail_unauthorized"
                    | "gmail_forbidden"
                    | "gmail_length_required"
                    | "gmail_http_failed"
                    | "gmail_timeout"
                    | "gmail_response_too_large"
                    | "gmail_invalid_response"
                    | "gmail_session_invalidated"
            )
            && self.status.is_none_or(|s| (100..=599).contains(&s))
            && self.cost <= 120
            && (1..=4).contains(&self.attempt)
            && self.retry_after_ms.is_none_or(|ms| ms <= 86400000)
    }
}

pub(super) async fn record(event: Event) {
    #[cfg(test)]
    if !ENABLED.try_with(|_| ()).is_ok() {
        return;
    }
    if !event.valid() {
        return;
    }
    let writer = WRITER.get_or_init(|| {
        let (sender, receiver) = std::sync::mpsc::sync_channel(512);
        let _ = std::thread::Builder::new()
            .name("gmail-diagnostics".into())
            .spawn(move || consume(receiver));
        sender
    });
    if writer.try_send(Command::Event(event)).is_err() {
        DROPPED.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    }
}

fn consume(receiver: std::sync::mpsc::Receiver<Command>) {
    let mut batch = Vec::new();
    let mut deadline = std::time::Instant::now() + std::time::Duration::from_secs(2);
    loop {
        match receiver.recv_timeout(deadline.saturating_duration_since(std::time::Instant::now())) {
            Ok(Command::Event(event)) => batch.push(event),
            Ok(Command::Flush(done)) => {
                persist(&mut batch);
                let _ = done.send(());
            }
            Err(std::sync::mpsc::RecvTimeoutError::Timeout) => persist(&mut batch),
            Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => {
                persist(&mut batch);
                break;
            }
        }
        if batch.len() >= 64 || std::time::Instant::now() >= deadline {
            persist(&mut batch);
            deadline = std::time::Instant::now() + std::time::Duration::from_secs(2);
        }
    }
}

fn persist(batch: &mut Vec<Event>) {
    if batch.is_empty() {
        return;
    }
    let count = batch.len() as u64;
    let events = std::mem::take(batch);
    if crate::platform::dirs::AppDirs::discover()
        .and_then(|dirs| write_batch(&dirs.state, events))
        .is_err()
    {
        DROPPED.fetch_add(count, std::sync::atomic::Ordering::Relaxed);
    }
}

pub(super) async fn flush() {
    let Some(writer) = WRITER.get() else { return };
    let writer = writer.clone();
    let _ = tokio::time::timeout(
        std::time::Duration::from_secs(3),
        tokio::task::spawn_blocking(move || {
            let (sender, receiver) = std::sync::mpsc::sync_channel(1);
            if writer.try_send(Command::Flush(sender)).is_ok() {
                let _ = receiver.recv_timeout(std::time::Duration::from_secs(2));
            }
        }),
    )
    .await;
}

#[cfg(test)]
fn write(root: &Path, event: Event) -> Result<(), &'static str> {
    write_batch(root, vec![event])
}

fn write_batch(root: &Path, batch: Vec<Event>) -> Result<(), &'static str> {
    use crate::platform::private_fs::{atomic_replace, directories, lock_exclusive, regular};
    let _operation = OPERATIONS.lock().map_err(|_| "cache_unavailable")?;
    let dir = directories(root, &["omamail", "diagnostics"], true)?.ok_or("cache_unavailable")?;
    let _lock = lock_exclusive(&dir, ".gmail.lock")?;
    let mut events: Vec<Event> = Vec::new();
    if let Some(file) = regular(&dir, "gmail.json", false)? {
        let mut bytes = Vec::new();
        file.take(LIMIT as u64 + 1)
            .read_to_end(&mut bytes)
            .map_err(|_| "cache_unavailable")?;
        if bytes.len() <= LIMIT {
            events = serde_json::from_slice(&bytes).unwrap_or_default();
        }
    }
    events.retain(Event::valid);
    events.extend(batch.into_iter().filter(Event::valid));
    if events.len() > RECORDS {
        events.drain(..events.len() - RECORDS);
    }
    loop {
        let bytes = serde_json::to_vec(&events).map_err(|_| "cache_unavailable")?;
        if bytes.len() <= LIMIT {
            atomic_replace(&dir, "gmail.json", &bytes)?;
            return atomic_replace(&dir, "gmail-writer.json", &serde_json::to_vec(
                &serde_json::json!({"dropped":DROPPED.load(std::sync::atomic::Ordering::Relaxed)})
            ).map_err(|_| "cache_unavailable")?);
        }
        events.remove(0);
    }
}

#[cfg(test)]
tokio::task_local! { pub(super) static ENABLED: (); }

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use std::os::unix::fs::{PermissionsExt, symlink};
    fn event() -> Event {
        Event {
            time: "2026-10-17T14:02:38Z".into(),
            process: 1,
            session: 1,
            request: 1,
            rpc: 1,
            operation: "messages.get.full".into(),
            lane: "interactive".into(),
            cost: 60,
            attempt: 1,
            status: Some(429),
            reason: "userRateLimitExceeded".into(),
            retry_after_ms: Some(60000),
            wait_ms: 10,
            elapsed_ms: 50,
            outcome: "gmail_rate_limited".into(),
        }
    }
    #[test]
    fn private_bounded_storage_refuses_links_without_touching_the_target() {
        let root = std::env::temp_dir()
            .canonicalize()
            .unwrap()
            .join(format!("gmail-diagnostics-{}", std::process::id()));
        std::fs::create_dir_all(&root).unwrap();
        for _ in 0..205 {
            write(&root, event()).unwrap();
        }
        let path = root.join("omamail/diagnostics/gmail.json");
        let bytes = std::fs::read(&path).unwrap();
        assert!(bytes.len() <= LIMIT);
        assert_eq!(
            serde_json::from_slice::<Vec<Event>>(&bytes).unwrap().len(),
            RECORDS
        );
        assert_eq!(
            std::fs::metadata(&path).unwrap().permissions().mode() & 0o777,
            0o600
        );
        assert_eq!(
            std::fs::metadata(path.parent().unwrap())
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o700
        );
        let target = root.join("untouched");
        std::fs::write(&target, b"synthetic-secret").unwrap();
        std::fs::remove_file(&path).unwrap();
        symlink(&target, &path).unwrap();
        assert!(write(&root, event()).is_err());
        assert_eq!(std::fs::read(&target).unwrap(), b"synthetic-secret");
        std::fs::remove_dir_all(root).unwrap();
    }
}
