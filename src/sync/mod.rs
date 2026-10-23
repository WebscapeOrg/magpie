//! Invariant: Background mailbox reads. Each account has one cancellable check loop.
use futures_util::future::{BoxFuture, try_join_all};
use serde::Deserialize;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    collections::HashMap,
    sync::{Arc, Mutex},
    time::{Duration, SystemTime, UNIX_EPOCH},
};
use tokio::{
    sync::{Notify, broadcast},
    task::JoinHandle,
};

pub(crate) type Check = Arc<
    dyn Fn(String, String) -> BoxFuture<'static, Result<Value, &'static str>>
        + Send
        + std::marker::Sync,
>;

#[derive(Clone)]
pub(crate) struct Event {
    account: String,
    generation: u64,
    pub value: Value,
}

struct Watch {
    generation: u64,
    query: String,
    interval: u64,
    snapshot: Value,
    trigger: Arc<Notify>,
    checking: bool,
    task: Option<JoinHandle<()>>,
}

impl Watch {
    fn tasks(self) -> impl Iterator<Item = JoinHandle<()>> {
        self.task.into_iter()
    }
}

#[derive(Default)]
struct State {
    watches: HashMap<String, Watch>,
    sequence: u64,
    generation: u64,
}

struct Inner {
    state: Mutex<State>,
    operations: tokio::sync::Mutex<()>,
    events: broadcast::Sender<Event>,
    check: Check,
    registry_task: Mutex<Option<JoinHandle<()>>>,
}

pub struct Sync {
    inner: Arc<Inner>,
    watch_registry: bool,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
struct WatchParams {
    account_id: String,
    query: String,
    interval_sec: u64,
    #[serde(default = "default_page_size")]
    page_size: u64,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
struct AccountParams {
    account_id: String,
}

fn default_page_size() -> u64 {
    25
}

fn account_id(value: &str) -> Result<String, &'static str> {
    if value.trim().is_empty() || value.len() > 8192 || value.chars().any(char::is_control) {
        return Err("invalid_params");
    }
    Ok(value.to_lowercase())
}

/// Performance: Count listed IDs because Gmail can return a placeholder estimate on truncated
/// pages. Pages of 100 keep ordinary unread polls to one request.
const UNREAD_PAGE: u64 = 100;
/// Performance: Stop at 500 unread messages to bound background polling requests.
const UNREAD_CAP: u64 = 500;
const UNREAD_PREVIEW: usize = 3;

pub(crate) async fn count_listed<F, Fut>(list: F) -> Result<(u64, Vec<Value>), &'static str>
where
    F: Fn(String) -> Fut,
    Fut: std::future::Future<Output = Result<Value, &'static str>>,
{
    let mut token = String::new();
    let mut total = 0u64;
    let mut preview = Vec::new();
    let mut seen = std::collections::HashSet::new();
    loop {
        if !seen.insert(token.clone()) {
            return Ok((total, preview));
        }
        let page = list(token.clone()).await?;
        let ids = page["ids"].as_array().ok_or("gmail_invalid_response")?;
        if preview.is_empty() {
            preview = ids.iter().take(UNREAD_PREVIEW).cloned().collect();
        }
        total += ids.len() as u64;
        let next = page["nextPageToken"].as_str().unwrap_or("");
        // Invariant: An empty page or a repeated continuation must stop polling before another
        // request.
        if next.is_empty() || ids.is_empty() || total >= UNREAD_CAP {
            return Ok((total, preview));
        }
        token = next.to_owned();
    }
}

impl Sync {
    pub fn new(gmail: Arc<crate::providers::gmail::Session>) -> Self {
        let mut sync = Self::with_checker(Arc::new(move |account, query| {
            let gmail = gmail.clone();
            Box::pin(async move {
                let (estimate, ids) = count_listed(|token| {
                    let gmail = gmail.clone();
                    let account = account.clone();
                    let query = query.clone();
                    async move {
                        gmail
                            .poll_call(
                                "gmail.list",
                                &json!({
                                    "accountId":account,"query":query,
                                    "pageSize":UNREAD_PAGE,"pageToken":token
                                }),
                            )
                            .await
                    }
                })
                .await?;
                let messages = try_join_all(ids.iter().map(|id| {
                    let gmail = &gmail;
                    let account = &account;
                    async move {
                        gmail
                            .poll_message(account, id.as_str().ok_or("gmail_invalid_response")?)
                            .await
                    }
                }))
                .await?;
                Ok(json!({"estimate":estimate,"messages":messages}))
            })
        }));
        sync.watch_registry = true;
        sync
    }

    pub(crate) fn with_checker(check: Check) -> Self {
        let (events, _) = broadcast::channel(128);
        Self {
            inner: Arc::new(Inner {
                state: Mutex::new(State::default()),
                operations: tokio::sync::Mutex::new(()),
                events,
                check,
                registry_task: Mutex::new(None),
            }),
            watch_registry: false,
        }
    }

    #[cfg(test)]
    pub(crate) fn for_test(check: Check) -> Self {
        Self::with_checker(check)
    }

    #[cfg(test)]
    pub(crate) async fn watch_for_test(&self, account: &str) {
        self.watch(account.into(), "".into(), 30).await.unwrap();
    }

    pub(crate) fn subscribe(&self) -> broadcast::Receiver<Event> {
        let receiver = self.inner.events.subscribe();
        if self.watch_registry {
            let mut task = self
                .inner
                .registry_task
                .lock()
                .unwrap_or_else(|e| e.into_inner());
            if task.is_none() {
                let sender = self.inner.events.clone();
                *task = Some(tokio::spawn(registry_changes(
                    sender,
                    || async {
                        tokio::task::spawn_blocking(|| {
                            crate::account::call("accounts.read", &json!({}))
                        })
                        .await
                        .map_err(|_| "worker_failed")?
                    },
                    Duration::from_secs(2),
                )));
            }
        }
        receiver
    }

    pub(crate) fn is_current(&self, event: &Event) -> bool {
        if event.account.is_empty() && event.generation == 0 {
            return self
                .inner
                .registry_task
                .lock()
                .is_ok_and(|task| task.is_some());
        }
        self.inner.state.lock().is_ok_and(|state| {
            state
                .watches
                .get(&event.account)
                .is_some_and(|watch| watch.generation == event.generation)
        })
    }

    pub async fn call(&self, method: &str, params: &Value) -> Result<Value, &'static str> {
        if method == "mail.watch" {
            let request: WatchParams =
                serde_json::from_value(params.clone()).map_err(|_| "invalid_params")?;
            let account = account_id(&request.account_id)?;
            if !(1..=100).contains(&request.page_size)
                || !(30..=3600).contains(&request.interval_sec)
                || request.query.len() > 8192
                || request.query.chars().any(char::is_control)
            {
                return Err("invalid_params");
            }
            let registered = crate::account::list;
            let accounts = tokio::task::spawn_blocking(registered)
                .await
                .map_err(|_| "worker_failed")??;
            if !accounts["accounts"].as_array().is_some_and(|entries| {
                entries
                    .iter()
                    .any(|entry| entry["id"] == account && entry["provider"] == "gmail")
            }) {
                return Err("mail_account_unknown");
            }
            return self
                .watch(account, request.query, request.interval_sec)
                .await;
        }
        if !matches!(method, "mail.unwatch" | "mail.check" | "mail.snapshot") {
            return Err("unknown_method");
        }
        let request: AccountParams =
            serde_json::from_value(params.clone()).map_err(|_| "invalid_params")?;
        let account = account_id(&request.account_id)?;
        if method == "mail.unwatch" {
            let _operation = self.inner.operations.lock().await;
            let watch = self
                .inner
                .state
                .lock()
                .map_err(|_| "session_failed")?
                .watches
                .remove(&account);
            for task in watch.into_iter().flat_map(Watch::tasks) {
                task.abort();
                let _ = task.await;
            }
            return Ok(json!({"unwatched":true}));
        }
        let state = self.inner.state.lock().map_err(|_| "session_failed")?;
        let watch = state.watches.get(&account).ok_or("mail_watch_unknown")?;
        if method == "mail.check" {
            if !watch.checking {
                watch.trigger.notify_one();
            }
            Ok(json!({"checking":true}))
        } else {
            Ok(watch.snapshot.clone())
        }
    }

    async fn watch(
        &self,
        account: String,
        query: String,
        interval: u64,
    ) -> Result<Value, &'static str> {
        let _operation = self.inner.operations.lock().await;
        let old = {
            let mut state = self.inner.state.lock().map_err(|_| "session_failed")?;
            if let Some(watch) = state.watches.get(&account) {
                if watch.query == query && watch.interval == interval {
                    return Ok(watch.snapshot.clone());
                }
            } else if state.watches.len() >= 32 {
                return Err("mail_watch_limit");
            }
            state.watches.remove(&account)
        };
        for task in old.into_iter().flat_map(Watch::tasks) {
            task.abort();
            let _ = task.await;
        }
        let mut state = self.inner.state.lock().map_err(|_| "session_failed")?;
        state.generation += 1;
        let generation = state.generation;
        let snapshot = json!({"accountId":account,"sequence":state.sequence,"estimate":0,"messages":[],"checkedAt":0,"error":""});
        let trigger = Arc::new(Notify::new());
        state.watches.insert(
            account.clone(),
            Watch {
                generation,
                query: query.clone(),
                interval,
                snapshot: snapshot.clone(),
                trigger: trigger.clone(),
                checking: true,
                task: None,
            },
        );
        let inner = self.inner.clone();
        let key = account.clone();
        let task = tokio::spawn(async move {
            loop {
                {
                    let Ok(mut state) = inner.state.lock() else {
                        return;
                    };
                    let Some(watch) = state
                        .watches
                        .get_mut(&account)
                        .filter(|watch| watch.generation == generation)
                    else {
                        return;
                    };
                    watch.checking = true;
                }
                let result = tokio::time::timeout(
                    Duration::from_secs(25),
                    (inner.check)(account.clone(), query.clone()),
                )
                .await
                .unwrap_or(Err("mail_check_timeout"));
                {
                    let Ok(mut state) = inner.state.lock() else {
                        return;
                    };
                    if !state
                        .watches
                        .get(&account)
                        .is_some_and(|watch| watch.generation == generation)
                    {
                        return;
                    }
                    state.sequence += 1;
                    let sequence = state.sequence;
                    let watch = state.watches.get_mut(&account).unwrap();
                    watch.checking = false;
                    let snapshot = &mut watch.snapshot;
                    snapshot["sequence"] = json!(sequence);
                    snapshot["checkedAt"] = json!(
                        SystemTime::now()
                            .duration_since(UNIX_EPOCH)
                            .unwrap_or_default()
                            .as_millis() as u64
                    );
                    match result {
                        Ok(value) => {
                            snapshot["estimate"] = value["estimate"].clone();
                            snapshot["messages"] = value["messages"].clone();
                            let visible = json!([value["estimate"], value["messages"]]);
                            snapshot["fingerprint"] = json!(format!(
                                "{:x}",
                                Sha256::digest(visible.to_string().as_bytes())
                            ));
                            snapshot["error"] = json!("");
                        }
                        Err(error) => snapshot["error"] = json!(error),
                    }
                    let _ = inner.events.send(Event {
                        account: account.clone(),
                        generation,
                        value: json!({"jsonrpc":"2.0","method":"mail.updated","params":snapshot}),
                    });
                }
                tokio::select! {
                    _ = tokio::time::sleep(Duration::from_secs(interval)) => {},
                    _ = trigger.notified() => {},
                }
            }
        });
        state.watches.get_mut(&key).unwrap().task = Some(task);
        Ok(snapshot)
    }

    pub async fn shutdown(&self) {
        let registry = self
            .inner
            .registry_task
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .take();
        if let Some(task) = registry {
            task.abort();
            let _ = task.await;
        }
        let _operation = self.inner.operations.lock().await;
        let tasks: Vec<_> = self
            .inner
            .state
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .watches
            .drain()
            .flat_map(|(_, watch)| watch.tasks())
            .collect();
        for task in &tasks {
            task.abort();
        }
        for task in tasks {
            let _ = task.await;
        }
    }
}

async fn registry_changes<F, Fut>(sender: broadcast::Sender<Event>, read: F, interval: Duration)
where
    F: Fn() -> Fut,
    Fut: std::future::Future<Output = Result<Value, &'static str>>,
{
    let mut revision = String::new();
    loop {
        if let Ok(value) = read().await {
            let next = value["revision"].as_str().unwrap_or("");
            if !revision.is_empty() && next != revision {
                let _ = sender.send(Event {
                    account: String::new(), generation: 0,
                    value: json!({"jsonrpc":"2.0","method":"accounts.changed","params":{"revision":next}}),
                });
            }
            revision = next.to_owned();
        }
        tokio::time::sleep(interval).await;
    }
}

impl Drop for Sync {
    fn drop(&mut self) {
        if let Ok(mut task) = self.inner.registry_task.lock()
            && let Some(task) = task.take()
        {
            task.abort();
        }
        if let Ok(mut state) = self.inner.state.lock() {
            for (_, watch) in state.watches.drain() {
                for task in watch.tasks() {
                    task.abort();
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use tokio::sync::Semaphore;

    // Invariant: Gmail's own shape: a truncated first page whose estimate is a placeholder, then a
    // finished page. The count is the ids, the estimate is never read, and only the first three ids
    // are kept for the preview.
    #[tokio::test]
    async fn unread_is_counted_from_listed_ids_not_the_estimate() {
        let asked = Arc::new(Mutex::new(Vec::new()));
        let (total, preview) = count_listed(|token| {
            asked.lock().unwrap().push(token.clone());
            async move {
                Ok(match token.as_str() {
                    "" => json!({"ids":["a","b","c","d"],"nextPageToken":"p2","estimate":201}),
                    "p2" => json!({"ids":["e"],"nextPageToken":"","estimate":201}),
                    _ => unreachable!(),
                })
            }
        })
        .await
        .unwrap();
        assert_eq!(total, 5);
        assert_eq!(preview, vec![json!("a"), json!("b"), json!("c")]);
        assert_eq!(*asked.lock().unwrap(), vec!["", "p2"]);
    }

    #[tokio::test]
    async fn a_finished_page_is_exact_and_an_empty_one_is_zero() {
        let (total, preview) = count_listed(|_| async {
            Ok(json!({"ids":["a","b"],"nextPageToken":"","estimate":201}))
        })
        .await
        .unwrap();
        assert_eq!((total, preview.len()), (2, 2));
        let (total, preview) =
            count_listed(|_| async { Ok(json!({"ids":[],"nextPageToken":"","estimate":201})) })
                .await
                .unwrap();
        assert_eq!((total, preview.len()), (0, 0));
    }

    #[tokio::test]
    async fn counting_stops_at_the_cap_and_on_a_server_going_in_circles() {
        let calls = Arc::new(AtomicUsize::new(0));
        let (total, _) = count_listed(|token| {
            let n = calls.fetch_add(1, Ordering::SeqCst);
            async move {
                let ids: Vec<String> = (0..100).map(|i| format!("{token}-{i}")).collect();
                Ok(json!({"ids":ids,"nextPageToken":format!("p{}", n + 1),"estimate":201}))
            }
        })
        .await
        .unwrap();
        assert_eq!(total, UNREAD_CAP);
        assert_eq!(calls.load(Ordering::SeqCst), 5);

        let (total, _) = count_listed(|_| async {
            Ok(json!({"ids":["a"],"nextPageToken":"same","estimate":201}))
        })
        .await
        .unwrap();
        assert_eq!(total, 2);

        let (total, _) = count_listed(|token| async move {
            Ok(if token.is_empty() {
                json!({"ids":["a"],"nextPageToken":"p2","estimate":201})
            } else {
                json!({"ids":[],"nextPageToken":"p3","estimate":201})
            })
        })
        .await
        .unwrap();
        assert_eq!(total, 1);

        assert_eq!(
            count_listed(|_| async { Ok(json!({"nextPageToken":""})) }).await,
            Err("gmail_invalid_response")
        );
    }

    #[tokio::test]
    async fn unread_pagination_never_requests_a_previously_seen_token() {
        let asked = Arc::new(Mutex::new(Vec::new()));
        let (total, preview) = count_listed(|token| {
            asked.lock().unwrap().push(token.clone());
            async move {
                Ok(match token.as_str() {
                    "" => json!({"ids":["one"],"nextPageToken":"a"}),
                    "a" => json!({"ids":["two"],"nextPageToken":"b"}),
                    "b" => json!({"ids":["three"],"nextPageToken":"a"}),
                    _ => panic!("unexpected synthetic page token"),
                })
            }
        })
        .await
        .unwrap();
        assert_eq!(*asked.lock().unwrap(), ["", "a", "b"]);
        assert_eq!(total, 3);
        assert_eq!(preview, [json!("one")]);
    }

    async fn event(events: &mut broadcast::Receiver<Event>) -> Event {
        tokio::time::timeout(Duration::from_secs(2), events.recv())
            .await
            .unwrap()
            .unwrap()
    }

    #[tokio::test]
    async fn immediate_check_snapshot_manual_check_and_errors() {
        let count = Arc::new(AtomicUsize::new(0));
        let sync = Sync::with_checker(Arc::new({
            let count = count.clone();
            move |account, query| {
                assert_eq!(account, "one");
                assert_eq!(query, "is:unread");
                let count = count.clone();
                Box::pin(async move {
                    if count.fetch_add(1, Ordering::SeqCst) == 0 {
                        Ok(json!({"estimate":7,"messages":[{"id":"new"}]}))
                    } else {
                        Err("gmail_http_failed")
                    }
                })
            }
        }));
        let mut events = sync.subscribe();
        sync.watch("one".into(), "is:unread".into(), 30)
            .await
            .unwrap();
        let first = event(&mut events).await;
        assert_eq!(first.value["method"], "mail.updated");
        assert_eq!(first.value["params"]["messages"][0]["id"], "new");
        assert_eq!(first.value["params"]["estimate"], 7);
        assert!(first.value["params"]["checkedAt"].as_u64().unwrap() > 0);
        assert_eq!(
            sync.call("mail.snapshot", &json!({"accountId":"one"}))
                .await
                .unwrap(),
            first.value["params"]
        );
        sync.call("mail.check", &json!({"accountId":"one"}))
            .await
            .unwrap();
        let second = event(&mut events).await;
        assert_eq!(second.value["params"]["error"], "gmail_http_failed");
        assert_eq!(second.value["params"]["estimate"], 7);
        assert!(
            second.value["params"]["sequence"].as_u64()
                > first.value["params"]["sequence"].as_u64()
        );
        sync.shutdown().await;
        assert!(!sync.is_current(&second));
    }

    #[tokio::test]
    async fn unchanged_count_still_reports_changed_message_identity() {
        let count = Arc::new(AtomicUsize::new(0));
        let sync = Sync::with_checker(Arc::new(move |_, _| {
            let n = count.fetch_add(1, Ordering::SeqCst);
            Box::pin(async move { Ok(json!({"estimate":1,"messages":[{"id":n / 2}]})) })
        }));
        let mut events = sync.subscribe();
        sync.watch("one".into(), "".into(), 30).await.unwrap();
        let first = event(&mut events).await.value["params"]["fingerprint"].clone();
        assert!(first.as_str().is_some_and(|s| !s.is_empty()));
        sync.call("mail.check", &json!({"accountId":"one"}))
            .await
            .unwrap();
        let same = event(&mut events).await.value["params"]["fingerprint"].clone();
        assert_eq!(first, same);
        sync.call("mail.check", &json!({"accountId":"one"}))
            .await
            .unwrap();
        let changed = event(&mut events).await.value["params"]["fingerprint"].clone();
        assert_ne!(same, changed);
        sync.shutdown().await;
    }

    struct Active(Arc<AtomicUsize>);
    impl Drop for Active {
        fn drop(&mut self) {
            self.0.fetch_sub(1, Ordering::SeqCst);
        }
    }

    #[tokio::test]
    async fn slow_checks_coalesce_and_replacement_cancels_old_generation() {
        let started = Arc::new(Semaphore::new(0));
        let active = Arc::new(AtomicUsize::new(0));
        let count = Arc::new(AtomicUsize::new(0));
        let sync = Sync::with_checker(Arc::new({
            let started = started.clone();
            let active = active.clone();
            let count = count.clone();
            move |_, query| {
                let started = started.clone();
                let active = active.clone();
                let count = count.clone();
                Box::pin(async move {
                    assert_eq!(
                        active.fetch_add(1, Ordering::SeqCst),
                        0,
                        "checks must not overlap"
                    );
                    let _active = Active(active);
                    count.fetch_add(1, Ordering::SeqCst);
                    started.add_permits(1);
                    if query == "slow" {
                        std::future::pending::<()>().await;
                    }
                    Ok(json!({"estimate":1,"messages":[{"id":query}]}))
                })
            }
        }));
        let mut events = sync.subscribe();
        sync.watch("one".into(), "slow".into(), 30).await.unwrap();
        started.acquire().await.unwrap().forget();
        for _ in 0..5 {
            sync.call("mail.check", &json!({"accountId":"one"}))
                .await
                .unwrap();
        }
        tokio::task::yield_now().await;
        assert_eq!(count.load(Ordering::SeqCst), 1);
        sync.watch("one".into(), "replacement".into(), 30)
            .await
            .unwrap();
        let replacement = event(&mut events).await;
        assert_eq!(
            replacement.value["params"]["messages"][0]["id"],
            "replacement"
        );
        assert_eq!(count.load(Ordering::SeqCst), 2);
        assert!(events.try_recv().is_err());
        sync.call("mail.unwatch", &json!({"accountId":"one"}))
            .await
            .unwrap();
        assert!(!sync.is_current(&replacement));
        assert_eq!(active.load(Ordering::SeqCst), 0);
        assert_eq!(
            sync.call("mail.snapshot", &json!({"accountId":"one"}))
                .await,
            Err("mail_watch_unknown")
        );
    }

    #[tokio::test]
    async fn slow_account_does_not_stall_fast_account_and_shutdown_cancels() {
        let active = Arc::new(AtomicUsize::new(0));
        let started = Arc::new(Semaphore::new(0));
        let sync = Sync::with_checker(Arc::new({
            let active = active.clone();
            let started = started.clone();
            move |account, _| {
                let active = active.clone();
                let started = started.clone();
                Box::pin(async move {
                    active.fetch_add(1, Ordering::SeqCst);
                    let _active = Active(active);
                    if account == "slow" {
                        started.add_permits(1);
                        std::future::pending::<()>().await;
                    }
                    Ok(json!({"estimate":0,"messages":[]}))
                })
            }
        }));
        let mut events = sync.subscribe();
        sync.watch("slow".into(), "".into(), 30).await.unwrap();
        started.acquire().await.unwrap().forget();
        sync.watch("fast".into(), "".into(), 30).await.unwrap();
        assert_eq!(
            event(&mut events).await.value["params"]["accountId"],
            "fast"
        );
        sync.shutdown().await;
        assert_eq!(active.load(Ordering::SeqCst), 0);
    }

    #[tokio::test]
    async fn dropping_session_cancels_in_progress_checks() {
        let active = Arc::new(AtomicUsize::new(0));
        let started = Arc::new(Semaphore::new(0));
        let sync = Sync::with_checker(Arc::new({
            let active = active.clone();
            let started = started.clone();
            move |_, _| {
                let active = active.clone();
                let started = started.clone();
                Box::pin(async move {
                    active.fetch_add(1, Ordering::SeqCst);
                    let _active = Active(active);
                    started.add_permits(1);
                    std::future::pending().await
                })
            }
        }));
        sync.watch("one".into(), "".into(), 30).await.unwrap();
        started.acquire().await.unwrap().forget();
        drop(sync);
        tokio::time::timeout(Duration::from_secs(2), async {
            while active.load(Ordering::SeqCst) != 0 {
                tokio::task::yield_now().await;
            }
        })
        .await
        .expect("dropped session left a running check");
    }

    #[tokio::test]
    async fn malformed_watches_are_refused_before_configuration_access() {
        let sync = Sync::with_checker(Arc::new(|_, _| panic!("must not check")));
        for params in [
            json!({"accountId":"one","query":"","intervalSec":29}),
            json!({"accountId":"one","query":"","intervalSec":3601}),
            json!({"accountId":"one","query":"bad\n","intervalSec":30}),
            json!({"accountId":"one\u{0000}","query":"","intervalSec":30}),
            json!({"accountId":"one","query":"","intervalSec":30,"url":"https://example.org"}),
        ] {
            assert_eq!(
                sync.call("mail.watch", &params).await,
                Err("invalid_params")
            );
        }
    }

    #[tokio::test]
    async fn watch_limit_and_identical_updates_do_not_restart() {
        let sync = Sync::with_checker(Arc::new(|_, _| Box::pin(std::future::pending())));
        for i in 0..32 {
            sync.watch(i.to_string(), "".into(), 30).await.unwrap();
        }
        assert_eq!(
            sync.watch("extra".into(), "".into(), 30).await,
            Err("mail_watch_limit")
        );
        let before = sync.inner.state.lock().unwrap().generation;
        sync.watch("0".into(), "".into(), 30).await.unwrap();
        assert_eq!(sync.inner.state.lock().unwrap().generation, before);
        sync.shutdown().await;
    }

    #[tokio::test]
    async fn periodic_check_runs_without_a_manual_trigger() {
        let sync = Sync::with_checker(Arc::new(|_, _| {
            Box::pin(async { Ok(json!({"estimate":0,"messages":[]})) })
        }));
        let mut events = sync.subscribe();
        // Invariant: Private seam accelerates the interval; the RPC boundary still requires 30
        // seconds.
        sync.watch("one".into(), "".into(), 1).await.unwrap();
        let first = event(&mut events).await;
        let second = event(&mut events).await;
        assert!(
            second.value["params"]["sequence"].as_u64()
                > first.value["params"]["sequence"].as_u64()
        );
        sync.shutdown().await;
    }

    #[tokio::test]
    async fn registry_watcher_emits_only_revision_on_change_and_stops_on_shutdown() {
        let revision = Arc::new(AtomicUsize::new(1));
        let reads = Arc::new(AtomicUsize::new(0));
        let sync = Sync::with_checker(Arc::new(|_, _| Box::pin(std::future::pending())));
        let mut events = sync.subscribe();
        let task = tokio::spawn(registry_changes(
            sync.inner.events.clone(),
            {
                let revision = revision.clone();
                let reads = reads.clone();
                move || {
                    let revision = revision.clone();
                    let reads = reads.clone();
                    async move {
                        reads.fetch_add(1, Ordering::SeqCst);
                        Ok(
                            json!({"revision":revision.load(Ordering::SeqCst).to_string(),"registry":{"clientSecret":"must never be an event"}}),
                        )
                    }
                }
            },
            Duration::from_millis(10),
        ));
        *sync.inner.registry_task.lock().unwrap() = Some(task);
        while reads.load(Ordering::SeqCst) < 2 {
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
        assert!(events.try_recv().is_err());
        revision.store(2, Ordering::SeqCst);
        let changed = event(&mut events).await;
        assert_eq!(
            changed.value,
            json!({"jsonrpc":"2.0","method":"accounts.changed","params":{"revision":"2"}})
        );
        assert!(sync.is_current(&changed));
        sync.shutdown().await;
        assert!(!sync.is_current(&changed));
        let before = reads.load(Ordering::SeqCst);
        tokio::time::sleep(Duration::from_millis(30)).await;
        assert_eq!(reads.load(Ordering::SeqCst), before);
    }
}
