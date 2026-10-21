use serde_json::Value;
use sha2::{Digest, Sha256};
use std::{
    collections::VecDeque,
    future::Future,
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};
struct Entry {
    key: [u8; 32],
    value: tokio::sync::Mutex<Option<Snapshot>>,
}
struct Snapshot {
    created: Instant,
    value: Value,
}
pub(crate) struct Reads {
    entries: Mutex<VecDeque<Arc<Entry>>>,
    slots: tokio::sync::Semaphore,
}
impl Default for Reads {
    fn default() -> Self {
        Self {
            entries: Mutex::new(VecDeque::new()),
            slots: tokio::sync::Semaphore::new(2),
        }
    }
}
impl Reads {
    pub(crate) fn invalidate(&self) {
        if let Ok(mut entries) = self.entries.lock() {
            entries.clear();
        }
    }
    pub(crate) async fn get<F, Fut>(&self, params: &Value, fetch: F) -> Result<Value, &'static str>
    where
        F: FnOnce() -> Fut,
        Fut: Future<Output = Result<Value, &'static str>>,
    {
        let key: [u8; 32] =
            Sha256::digest(serde_json::to_vec(params).map_err(|_| "invalid_params")?).into();
        let entry = {
            let mut entries = self.entries.lock().map_err(|_| "session_failed")?;
            if let Some(index) = entries.iter().position(|entry| entry.key == key) {
                let entry = entries.remove(index).unwrap();
                entries.push_back(entry.clone());
                entry
            } else {
                while entries.len() >= 16 {
                    let index = entries
                        .iter()
                        .position(|entry| Arc::strong_count(entry) == 1)
                        .ok_or("calendar_busy")?;
                    entries.remove(index);
                }
                let entry = Arc::new(Entry {
                    key,
                    value: tokio::sync::Mutex::new(None),
                });
                entries.push_back(entry.clone());
                entry
            }
        };
        let mut saved = entry.value.lock().await;
        if let Some(snapshot) = saved.as_ref()
            && snapshot.created.elapsed() < Duration::from_secs(5)
        {
            return Ok(snapshot.value.clone());
        }
        let _permit = self.slots.acquire().await.map_err(|_| "session_failed")?;
        let value = fetch().await?;
        let bytes = serde_json::to_vec(&value)
            .map_err(|_| "calendar_invalid_response")?
            .len();
        if bytes <= 4 * 1024 * 1024 {
            *saved = Some(Snapshot {
                created: Instant::now(),
                value: value.clone(),
            });
        }
        Ok(value)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[tokio::test]
    async fn identical_reads_share_work_and_writes_invalidate() {
        use std::sync::atomic::{AtomicUsize, Ordering};
        let reads = Reads::default();
        let calls = AtomicUsize::new(0);
        let params = serde_json::json!({"source":"one","range":[1,2]});
        let fetch = || async {
            calls.fetch_add(1, Ordering::Relaxed);
            tokio::task::yield_now().await;
            Ok(serde_json::json!({"events":[]}))
        };
        let (first, second) = tokio::join!(reads.get(&params, fetch), reads.get(&params, fetch));
        assert_eq!(first, second);
        assert_eq!(calls.load(Ordering::Relaxed), 1);
        reads.invalidate();
        reads.get(&params, fetch).await.unwrap();
        assert_eq!(calls.load(Ordering::Relaxed), 2);
    }
}
