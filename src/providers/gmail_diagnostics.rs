use serde::{Deserialize, Serialize};
use std::{io::Read, path::Path};

const LIMIT: usize = 65536;
const RECORDS: usize = 200;
static OPERATIONS: std::sync::Mutex<()> = std::sync::Mutex::new(());

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct Event {
    pub time: String,
    pub process: u32,
    pub session: u64,
    pub request: u64,
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
    let _ = tokio::task::spawn_blocking(move || {
        let dirs = crate::platform::dirs::AppDirs::discover()?;
        write(&dirs.state, event)
    })
    .await;
}

fn write(root: &Path, event: Event) -> Result<(), &'static str> {
    use crate::platform::private_fs::{atomic_replace, directories, lock_exclusive, regular};
    if !event.valid() {
        return Ok(());
    }
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
    events.push(event);
    if events.len() > RECORDS {
        events.drain(..events.len() - RECORDS);
    }
    loop {
        let bytes = serde_json::to_vec(&events).map_err(|_| "cache_unavailable")?;
        if bytes.len() <= LIMIT {
            return atomic_replace(&dir, "gmail.json", &bytes);
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
        let root = std::env::temp_dir().join(format!("gmail-diagnostics-{}", std::process::id()));
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
