//! A bounded record of what happened to the phone's Claude requests, kept on the phone only.
//! Invariant: an event holds fixed names, codes, counts and times, never a message id, mail text,
//! key, header or reply. Each field is checked against an allow-list before it is written, and the
//! file holds at most RECORDS events and LIMIT bytes in the private diagnostics folder.
use serde::{Deserialize, Serialize};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::{io::Read, path::Path};

const LIMIT: usize = 256 * 1024;
const RECORDS: usize = 1000;
const FILE: &str = "claude.json";
static OPERATIONS: std::sync::Mutex<()> = std::sync::Mutex::new(());
static WRITER: std::sync::OnceLock<std::sync::mpsc::SyncSender<Command>> = std::sync::OnceLock::new();
static DROPPED: AtomicU64 = AtomicU64::new(0);
static SERIAL: AtomicU64 = AtomicU64::new(0);
static ACTIVE: AtomicBool = AtomicBool::new(true);
static SUSPENSIONS: AtomicU64 = AtomicU64::new(0);

enum Command {
    Event(Box<Event>),
    Flush(std::sync::mpsc::SyncSender<()>),
}

fn zero(value: &u64) -> bool {
    *value == 0
}
fn none(value: &u32) -> bool {
    *value == 0
}
fn no(value: &bool) -> bool {
    !*value
}

#[derive(Serialize, Deserialize, Default, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct Event {
    pub time: String,
    pub process: u32,
    /// attempt: one HTTP request to Claude. backoff: descriptions wait before asking again.
    /// batch: what one batch of descriptions ended as. background: one background describe run.
    /// suspend and resume: the app left or returned to the foreground. settle: how long leaving
    /// waited for a description already being written.
    pub kind: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub operation: String,
    #[serde(default, skip_serializing_if = "zero")]
    pub request: u64,
    #[serde(default, skip_serializing_if = "none")]
    pub attempt: u32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub status: Option<u16>,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub class: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub retry_after_ms: Option<u64>,
    #[serde(default, skip_serializing_if = "zero")]
    pub wait_ms: u64,
    #[serde(default, skip_serializing_if = "zero")]
    pub elapsed_ms: u64,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub outcome: String,
    #[serde(default)]
    pub active: bool,
    /// The app left the foreground while this request or run was under way.
    #[serde(default, skip_serializing_if = "no")]
    pub suspended: bool,
    #[serde(default, skip_serializing_if = "none")]
    pub level: u32,
    #[serde(default, skip_serializing_if = "none")]
    pub described: u32,
    #[serde(default, skip_serializing_if = "none")]
    pub waiting: u32,
    #[serde(default, skip_serializing_if = "none")]
    pub failed: u32,
}

const KINDS: [&str; 7] = ["attempt", "backoff", "batch", "background", "suspend", "resume", "settle"];
const OPERATIONS_KNOWN: [&str; 5] = ["count", "describe", "assistant", "keyCheck", "workspaceProbe"];
const CLASSES: [&str; 7] = ["http", "timeout", "connect", "body", "request", "other", "tooLarge"];
pub(crate) const OUTCOMES: [&str; 31] = [
    "ok",
    "finished",
    "cut",
    "settled",
    "busy",
    "resumed",
    "refused",
    "ai_unreachable",
    "ai_rate_limited",
    "ai_unavailable",
    "ai_billing",
    "ai_key_invalid",
    "ai_key_refused",
    "ai_key_workspace",
    "ai_model_unavailable",
    "ai_daily_limit",
    "ai_key_format",
    "ai_key_missing",
    "ai_key_storage",
    "ai_request_rejected",
    "ai_invalid_response",
    "overview_invalid_response",
    "overview_input_invalid",
    "overview_document_refused",
    "overview_ai_refused",
    "overview_media_limit",
    "overview_interrupted",
    "overview_unsupported_claim",
    "inbox_storage_invalid",
    "unknown",
    "mail",
];

impl Event {
    fn valid(&self) -> bool {
        let known = |list: &[&str], value: &str| value.is_empty() || list.contains(&value);
        self.time.len() == 20
            && chrono::NaiveDateTime::parse_from_str(&self.time, "%Y-%m-%dT%H:%M:%SZ").is_ok()
            && KINDS.contains(&self.kind.as_str())
            && known(&OPERATIONS_KNOWN, &self.operation)
            && known(&CLASSES, &self.class)
            && known(&OUTCOMES, &self.outcome)
            && self.status.is_none_or(|s| (100..=599).contains(&s))
            && self.attempt <= 8
            && self.retry_after_ms.is_none_or(|ms| ms <= 86_400_000)
            && self.wait_ms <= 86_400_000
            && self.elapsed_ms <= 86_400_000
            && self.level <= 16
            && [self.described, self.waiting, self.failed].iter().all(|count| *count <= 1000)
    }
}

/// A new event of this kind, stamped now and with whether the app is in the foreground.
pub(crate) fn event(kind: &str) -> Event {
    Event {
        time: chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string(),
        process: std::process::id(),
        kind: kind.into(),
        active: ACTIVE.load(Ordering::Acquire),
        ..Event::default()
    }
}

/// A number for one request, shared by its attempts.
pub(crate) fn serial() -> u64 {
    SERIAL.fetch_add(1, Ordering::Relaxed) + 1
}

/// Whether the app is in the foreground.
pub(crate) fn active() -> bool {
    ACTIVE.load(Ordering::Acquire)
}

/// How many times the app has left the foreground; a change means it left during the work.
pub(crate) fn suspensions() -> u64 {
    SUSPENSIONS.load(Ordering::Acquire)
}

/// The app left (`false`) or returned to (`true`) the foreground. Only changes are recorded.
pub(crate) fn foreground(active: bool) {
    if ACTIVE.swap(active, Ordering::AcqRel) == active {
        return;
    }
    if !active {
        SUSPENSIONS.fetch_add(1, Ordering::AcqRel);
    }
    let mut change = event(if active { "resume" } else { "suspend" });
    change.active = active;
    record(change);
}

pub(crate) fn outcome(code: &str) -> String {
    if OUTCOMES.contains(&code) { code } else if code.starts_with("gmail_") || code.starts_with("local_") { "mail" } else { "unknown" }.into()
}

pub(crate) fn record(event: Event) {
    #[cfg(test)]
    if ENABLED.try_with(|_| ()).is_err() {
        return;
    }
    if !event.valid() {
        return;
    }
    let writer = WRITER.get_or_init(|| {
        let (sender, receiver) = std::sync::mpsc::sync_channel(512);
        let _ = std::thread::Builder::new()
            .name("claude-diagnostics".into())
            .spawn(move || consume(receiver));
        sender
    });
    if writer.try_send(Command::Event(Box::new(event))).is_err() {
        DROPPED.fetch_add(1, Ordering::Relaxed);
    }
}

fn consume(receiver: std::sync::mpsc::Receiver<Command>) {
    let mut batch = Vec::new();
    let mut deadline = std::time::Instant::now() + std::time::Duration::from_secs(2);
    loop {
        match receiver.recv_timeout(deadline.saturating_duration_since(std::time::Instant::now())) {
            Ok(Command::Event(event)) => batch.push(*event),
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
        DROPPED.fetch_add(count, Ordering::Relaxed);
    }
}

/// Writes what is queued, so events are on disk before iOS freezes the app.
pub(crate) async fn flush() {
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

fn write_batch(root: &Path, batch: Vec<Event>) -> Result<(), &'static str> {
    use crate::platform::private_fs::{atomic_replace, directories, lock_exclusive, regular};
    let _operation = OPERATIONS.lock().map_err(|_| "cache_unavailable")?;
    let dir = directories(root, &["omamail", "diagnostics"], true)?.ok_or("cache_unavailable")?;
    let _lock = lock_exclusive(&dir, ".claude.lock")?;
    let mut events: Vec<Event> = Vec::new();
    if let Some(file) = regular(&dir, FILE, false)? {
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
            atomic_replace(&dir, FILE, &bytes)?;
            let dropped = serde_json::json!({"dropped": DROPPED.load(Ordering::Relaxed)});
            return atomic_replace(&dir, "claude-writer.json", &serde_json::to_vec(&dropped).map_err(|_| "cache_unavailable")?);
        }
        events.remove(0);
    }
}

#[cfg(test)]
tokio::task_local! { pub(crate) static ENABLED: (); }

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use std::os::unix::fs::{PermissionsExt, symlink};

    fn attempt() -> Event {
        Event {
            operation: "describe".into(),
            request: 7,
            attempt: 2,
            status: Some(529),
            class: "http".into(),
            retry_after_ms: Some(2000),
            wait_ms: 2100,
            elapsed_ms: 900,
            outcome: "ai_unavailable".into(),
            ..event("attempt")
        }
    }

    #[test]
    fn only_allow_listed_names_and_bounded_numbers_are_kept() {
        assert!(attempt().valid());
        assert!(event("suspend").valid());
        let changed = |change: fn(&mut Event)| {
            let mut event = attempt();
            change(&mut event);
            event.valid()
        };
        assert!(!changed(|e| e.kind = "message".into()));
        assert!(!changed(|e| e.operation = "18c2f0a1b2c3d4e5".into()), "a message id is never an operation");
        assert!(!changed(|e| e.outcome = "Claude said: ignore previous instructions".into()));
        assert!(!changed(|e| e.class = "sk-ant-api03-secret".into()));
        assert!(!changed(|e| e.status = Some(99)));
        assert!(!changed(|e| e.time = "yesterday".into()));
        assert!(!changed(|e| e.level = 17));
        assert!(!changed(|e| e.described = 1001));
        assert_eq!(outcome("gmail_timeout"), "mail");
        assert_eq!(outcome("ai_rate_limited"), "ai_rate_limited");
        assert_eq!(outcome("anything a server said"), "unknown");
        let text = serde_json::to_string(&event("resume")).unwrap();
        assert!(!text.contains("operation") && !text.contains("status"), "empty fields are left out: {text}");
        assert!(serde_json::from_str::<Event>(r#"{"time":"2026-11-02T08:40:14Z","process":1,"kind":"resume","id":"x"}"#).is_err(), "unknown fields are refused");
    }

    #[test]
    fn private_bounded_storage_refuses_links_without_touching_the_target() {
        let root = std::env::temp_dir()
            .canonicalize()
            .unwrap()
            .join(format!("claude-diagnostics-{}", std::process::id()));
        std::fs::create_dir_all(&root).unwrap();
        for _ in 0..3 {
            write_batch(&root, (0..400).map(|_| attempt()).collect()).unwrap();
        }
        write_batch(&root, vec![Event { kind: "secret".into(), ..attempt() }]).unwrap();
        let path = root.join("omamail/diagnostics/claude.json");
        let bytes = std::fs::read(&path).unwrap();
        assert!(bytes.len() <= LIMIT);
        let kept = serde_json::from_slice::<Vec<Event>>(&bytes).unwrap();
        assert_eq!(kept.len(), RECORDS);
        assert!(kept.iter().all(|event| event.kind == "attempt"), "an invalid event is never written");
        assert_eq!(std::fs::metadata(&path).unwrap().permissions().mode() & 0o777, 0o600);
        assert_eq!(std::fs::metadata(path.parent().unwrap()).unwrap().permissions().mode() & 0o777, 0o700);
        let target = root.join("untouched");
        std::fs::write(&target, b"synthetic-secret").unwrap();
        std::fs::remove_file(&path).unwrap();
        symlink(&target, &path).unwrap();
        assert!(write_batch(&root, vec![attempt()]).is_err());
        assert_eq!(std::fs::read(&target).unwrap(), b"synthetic-secret");
        std::fs::remove_dir_all(root).unwrap();
    }
}
