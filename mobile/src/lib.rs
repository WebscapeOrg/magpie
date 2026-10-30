use futures_util::FutureExt;
use serde_json::{Value, json};
use std::{
    collections::HashMap,
    ffi::c_void,
    panic::AssertUnwindSafe,
    sync::{
        Arc, Mutex, OnceLock,
        atomic::{AtomicBool, AtomicU64, Ordering},
    },
    time::Duration,
};
use tokio::sync::{Notify, oneshot};

type Callback = extern "C" fn(u64, *const u8, usize, *mut c_void);
struct Completion {
    id: u64,
    callback: Callback,
    context: usize,
}
impl Completion {
    fn finish(&self, value: Value) {
        let bytes = serde_json::to_vec(&value)
            .unwrap_or_else(|_| b"{\"error\":\"mobile_encoding_failed\"}".to_vec());
        (self.callback)(
            self.id,
            bytes.as_ptr(),
            bytes.len(),
            self.context as *mut c_void,
        );
    }
}
struct Host {
    engine: omamail::backend::Engine,
    closed: AtomicBool,
    active: AtomicBool,
    lifecycle: tokio::sync::Mutex<()>,
    operations: tokio::sync::RwLock<()>,
    control: Mutex<()>,
    pending: Mutex<HashMap<u64, (usize, Option<oneshot::Sender<()>>)>>,
    drained: Notify,
    events: Mutex<Vec<tokio::sync::broadcast::Receiver<Value>>>,
}
static RUNTIME: OnceLock<tokio::runtime::Runtime> = OnceLock::new();
static HOSTS: OnceLock<Mutex<HashMap<u64, Arc<Host>>>> = OnceLock::new();
static SERIAL: AtomicU64 = AtomicU64::new(1);
fn hosts() -> &'static Mutex<HashMap<u64, Arc<Host>>> {
    HOSTS.get_or_init(Mutex::default)
}
fn runtime() -> &'static tokio::runtime::Runtime {
    RUNTIME.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .enable_all()
            .build()
            .expect("mobile runtime")
    })
}
type Operation =
    Box<dyn FnOnce() -> std::pin::Pin<Box<dyn std::future::Future<Output = ()>>> + Send>;
fn executor() -> Result<&'static tokio::sync::mpsc::UnboundedSender<Operation>, &'static str> {
    static EXECUTOR: OnceLock<Result<tokio::sync::mpsc::UnboundedSender<Operation>, &'static str>> =
        OnceLock::new();
    EXECUTOR
        .get_or_init(|| {
            let (sender, mut receiver) = tokio::sync::mpsc::unbounded_channel::<Operation>();
            std::thread::Builder::new()
                .name("magpie-mobile".into())
                .spawn(|| {
                    runtime().block_on(tokio::task::LocalSet::new().run_until(async move {
                        while let Some(operation) = receiver.recv().await {
                            tokio::task::spawn_local(operation());
                        }
                    }));
                })
                .map_err(|_| "mobile_executor_failed")?;
            Ok(sender)
        })
        .as_ref()
        .map_err(|error| *error)
}
fn submit(operation: Operation) -> Result<(), &'static str> {
    executor()?
        .send(operation)
        .map_err(|_| "mobile_executor_failed")
}
fn host(id: u64) -> Option<Arc<Host>> {
    hosts().lock().ok()?.get(&id).cloned()
}
fn error(code: &str) -> Value {
    json!({"error":code})
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn magpie_engine_create(config: *const u8, count: usize) -> u64 {
    std::panic::catch_unwind(|| {
        if config.is_null() || count == 0 || count > 16384 {
            return 0;
        }
        let Ok(config) =
            serde_json::from_slice::<Value>(unsafe { std::slice::from_raw_parts(config, count) })
        else {
            return 0;
        };
        #[cfg(target_os = "ios")]
        {
            let (Some(root), Some(home)) = (config["root"].as_str(), config["home"].as_str())
            else {
                return 0;
            };
            if omamail::platform::dirs::initialize_mobile(root.into(), home.into()).is_err() {
                return 0;
            }
        }
        let _ = config;
        let Ok(mut registry) = hosts().lock() else {
            return 0;
        };
        if !registry.is_empty() {
            return 0;
        }
        let runtime = runtime();
        if executor().is_err() {
            return 0;
        }
        let _entered = runtime.enter();
        let id = SERIAL.fetch_add(1, Ordering::Relaxed);
        let engine = omamail::backend::Engine::default();
        let events = Mutex::new(engine.notifications());
        registry.insert(
            id,
            Arc::new(Host {
                engine,
                events,
                active: AtomicBool::new(true),
                lifecycle: tokio::sync::Mutex::new(()),
                operations: tokio::sync::RwLock::new(()),
                control: Mutex::new(()),
                closed: AtomicBool::new(false),
                pending: Mutex::default(),
                drained: Notify::new(),
            }),
        );
        id
    })
    .unwrap_or(0)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn magpie_engine_request(
    handle: u64,
    id: u64,
    bytes: *const u8,
    count: usize,
    callback: Option<Callback>,
    context: *mut c_void,
) -> bool {
    std::panic::catch_unwind(|| {
        let Some(callback) = callback else { return false; };
        if bytes.is_null() || count == 0 || count > 32 * 1024 * 1024 { return false; }
        let Some(host) = host(handle) else { return false; };
        let Ok(mut pending) = host.pending.lock() else { return false; };
        let admitted_bytes: usize = pending.values().map(|entry| entry.0).sum();
        if host.closed.load(Ordering::Acquire) || pending.len() >= 32 || pending.contains_key(&id) || admitted_bytes + count > 64 * 1024 * 1024 { return false; }
        let Ok(request) = serde_json::from_slice::<Value>(unsafe { std::slice::from_raw_parts(bytes, count) }) else { return false; };
        let Some(method) = request["method"].as_str().filter(|m| m.len() <= 128) else { return false; };
        let method = method.to_owned();
        let params = request.get("params").cloned().unwrap_or(json!({}));
        let (cancel, cancelled) = oneshot::channel();
        pending.insert(id, (count, Some(cancel)));
        drop(pending);
        let completion = Completion { id, callback, context: context as usize };
        let admitted = host.clone();
        if submit(Box::new(move || Box::pin(async move {
            let cancellable = read_only(&method);
            let dispatch = async {
                let removing=matches!(method.as_str(),"accounts.mobileRemove"|"engine.suspend"|"engine.copyAttachments"|"engine.clearDraft");
                let _exclusive=if removing {Some(host.operations.write().await)}else{None};
                let _shared=if !removing {Some(host.operations.read().await)}else{None};
                if !host.active.load(Ordering::Acquire) && !matches!(method.as_str(), "engine.info" | "engine.events" | "engine.suspend" | "engine.resume") { return Err("mobile_suspended"); }
                host.engine.mobile_authorize(&params).await?;
                match method.as_str() {
                    "accounts.mobileRemove"=>host.engine.mobile_remove_account(&params).await,
                    "engine.contacts"=>host.engine.mobile_contacts(&params).await,
                    "engine.copyAttachments" | "engine.clearDraft"=>host.engine.mobile_draft_attachments(&method,&params).await,
                    "engine.conversation"=>host.engine.mobile_conversation(&params).await,
                    "engine.releaseSend"=>host.engine.mobile_release_send(&params).await,
                    "engine.checkSend"=>host.engine.mobile_check_send(&params).await,
                    "engine.info" => {
                        let mut info=host.engine.dispatch("system.info",&json!({})).await?;
                        info["abiVersion"]=json!(1);
                        info["buildId"]=json!(option_env!("MAGPIE_ENGINE_BUILD").unwrap_or("development"));
                        Ok(info)
                    },
                    "engine.events" => {
                        let mut events = Vec::new();
                        let mut streams = host.events.lock().map_err(|_| "mobile_request_failed")?;
                        for stream in streams.iter_mut() {
                            while events.len() < 256 {
                                match stream.try_recv() {
                                    Ok(event) => events.push(event),
                                    Err(tokio::sync::broadcast::error::TryRecvError::Lagged(_)) => { events.push(json!({"method":"engine.refreshRequired"})); break; },
                                    Err(_) => break,
                                }
                            }
                        }
                        Ok(json!({"events":events}))
                    },
                    "auth.mobileExchange" => omamail::auth::mobile_exchange(&params).await,
                    "engine.suspend" => { let _lock = host.lifecycle.lock().await; if !host.active.load(Ordering::Acquire) {host.engine.mobile_suspend().await?;} Ok(json!({"suspended":!host.active.load(Ordering::Acquire)})) },
                    "engine.resume" => { let _lock = host.lifecycle.lock().await; Ok(json!({"suspended":!host.active.load(Ordering::Acquire)})) },
                    "mail.watch" | "mail.check" | "mail.unwatch" | "request.upload" | "system.quit" | "auth.begin" | "auth.poll" | "auth.cancel" | "inbox.snooze" | "inbox.wake" | "inbox.tick" | "inbox.overviews" => Err("mobile_service_required"),
                    "outbox.compose" if params["resumeUnsent"] != true => Err("mobile_resumable_send_required"),
                    "mail.send" | "gmail.send" | "outbox.enqueue" => Err("mobile_use_outbox"),
                    _ => host.engine.dispatch(&method, &params).await,
                }
            };
            let guarded = AssertUnwindSafe(dispatch).catch_unwind();
            tokio::pin!(guarded);
            let outcome = if cancellable {
                tokio::select! {
                    _ = cancelled => { let _=guarded.await; Ok(Err("mobile_cancelled")) },
                    result = tokio::time::timeout(Duration::from_secs(90), &mut guarded) => match result { Ok(value)=>value, Err(_)=>{let _=guarded.await; Ok(Err("mobile_timeout"))} },
                }
            } else { guarded.await };
            let answer = match outcome {
                Ok(Ok(result)) => json!({"result":result}),
                Ok(Err(code)) => error(code),
                Err(_) => error("mobile_request_failed"),
            };
            completion.finish(answer);
            if let Ok(mut pending) = host.pending.lock() { pending.remove(&id); }
            host.drained.notify_one();
        }))).is_err() {
            if let Ok(mut pending) = admitted.pending.lock() { pending.remove(&id); }
            admitted.drained.notify_one();
            return false;
        }
        true
    }).unwrap_or(false)
}

#[unsafe(no_mangle)]
pub extern "C" fn magpie_engine_cancel(handle: u64, id: u64) {
    let _ = std::panic::catch_unwind(|| {
        if let Some(host) = host(handle)
            && let Ok(mut pending) = host.pending.lock()
            && let Some(cancel) = pending.get_mut(&id).and_then(|entry| entry.1.take())
        {
            let _ = cancel.send(());
        }
    });
}

#[unsafe(no_mangle)]
pub extern "C" fn magpie_engine_destroy(
    handle: u64,
    callback: Option<Callback>,
    context: *mut c_void,
) -> bool {
    let Some(callback) = callback else {
        return false;
    };
    let Some(host) = host(handle) else {
        return false;
    };
    let Ok(control) = host.control.lock() else {
        return false;
    };
    let Ok(pending) = host.pending.lock() else {
        return false;
    };
    if host.closed.swap(true, Ordering::AcqRel) {
        return false;
    }
    host.active.store(false, Ordering::Release);
    host.engine.set_suspended_now(true);
    drop(pending);
    drop(control);
    let completion = Completion {
        id: 0,
        callback,
        context: context as usize,
    };
    let admitted = host.clone();
    if submit(Box::new(move || {
        Box::pin(async move {
            loop {
                let notified = host.drained.notified();
                if host.pending.lock().is_ok_and(|p| p.is_empty()) {
                    break;
                }
                notified.await;
            }
            let result = AssertUnwindSafe(host.engine.shutdown())
                .catch_unwind()
                .await
                .unwrap_or(Err("mobile_shutdown_failed"));
            if result.is_ok() {
                if let Ok(mut registry) = hosts().lock() {
                    registry.remove(&handle);
                }
            }
            completion.finish(match result {
                Ok(()) => json!({"result":{"closed":true}}),
                Err(code) => error(code),
            });
            if result.is_err() {
                loop {
                    tokio::time::sleep(Duration::from_secs(1)).await;
                    let retried = AssertUnwindSafe(host.engine.shutdown())
                        .catch_unwind()
                        .await;
                    if matches!(retried, Ok(Ok(()))) {
                        if let Ok(mut registry) = hosts().lock() {
                            registry.remove(&handle);
                        }
                        break;
                    }
                }
            }
        })
    }))
    .is_err()
    {
        if let Ok(_control) = admitted.control.lock() {
            admitted.closed.store(false, Ordering::Release);
        }
        return false;
    }
    true
}

fn read_only(method: &str) -> bool {
    matches!(
        method,
        "engine.contacts"
            | "engine.conversation"
            | "engine.checkSend"
            | "engine.info"
            | "system.info"
            | "accounts.read"
            | "accounts.list"
            | "local.list"
            | "local.summaries"
            | "local.status"
            | "local.overview"
            | "local.edits"
            | "local.labelCounts"
            | "gmail.list"
            | "gmail.read"
            | "gmail.labels"
            | "gmail.profile"
            | "gmail.sendAs"
            | "reader.open"
            | "reader.render"
            | "contacts.suggest"
            | "outbox.snapshot"
            | "compose.recoveryRead"
    )
}
#[unsafe(no_mangle)]
pub extern "C" fn magpie_engine_set_active(handle: u64, active: bool) -> bool {
    std::panic::catch_unwind(|| {
        let Some(host) = host(handle) else {
            return false;
        };
        let Ok(_control) = host.control.lock() else {
            return false;
        };
        if host.closed.load(Ordering::Acquire) {
            return false;
        }
        host.active.store(active, Ordering::Release);
        host.engine.set_suspended_now(!active);
        true
    })
    .unwrap_or(false)
}
