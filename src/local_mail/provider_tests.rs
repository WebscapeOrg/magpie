use super::{LocalMail, store, sync, tests::message};
use crate::{
    credentials,
    mail::tests::{account_fixture, isolated},
    providers::{gmail, gmail_http},
};
use serde_json::{Value, json};
use std::{
    collections::BTreeMap,
    sync::{Arc, Mutex},
    time::Duration,
};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::TcpListener,
};

const ACCOUNT: &str = "replica@example.org";

struct World {
    messages: BTreeMap<String, Value>,
    requests: Vec<String>,
    writes: Vec<Value>,
    unauthorized: bool,
    pause: String,
    paginated_history: bool,
    expired_history: bool,
    /// Requests containing this text are answered with a length larger than any accepted reply.
    oversized: String,
    /// Requests containing this text are answered with another message's id.
    mismatched: String,
}

struct Provider {
    origin: String,
    world: Arc<Mutex<World>>,
    paused: Arc<tokio::sync::Notify>,
    task: tokio::task::JoinHandle<()>,
}

impl Provider {
    async fn new() -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let origin = format!("http://{}", listener.local_addr().unwrap());
        let world = Arc::new(Mutex::new(World {
            messages: ["one", "two"]
                .into_iter()
                .map(|id| (id.into(), message(id, "Synthetic saved body")))
                .collect(),
            requests: Vec::new(),
            writes: Vec::new(),
            unauthorized: false,
            pause: String::new(),
            paginated_history: false,
            expired_history: false,
            oversized: String::new(),
            mismatched: String::new(),
        }));
        let state = world.clone();
        let paused = Arc::new(tokio::sync::Notify::new());
        let ready = paused.clone();
        let task = tokio::spawn(async move {
            let mut handlers = tokio::task::JoinSet::new();
            loop {
                let (mut socket, _) = listener.accept().await.unwrap();
                let state = state.clone();
                let ready = ready.clone();
                handlers.spawn(async move {
                    let mut bytes = Vec::new();
                    while !bytes.ends_with(b"\r\n\r\n") {
                        let Ok(byte) = socket.read_u8().await else { return };
                        bytes.push(byte);
                        assert!(bytes.len() < 65_536);
                    }
                    let headers = String::from_utf8(bytes).unwrap();
                    let line = headers.lines().next().unwrap().to_owned();
                    let length: usize = headers.lines().find_map(|line| {
                        let (name, value) = line.split_once(':')?;
                        name.eq_ignore_ascii_case("content-length").then(|| value.trim().parse().unwrap())
                    }).unwrap_or(0);
                    assert!(length < 65_536);
                    let mut body = vec![0; length];
                    socket.read_exact(&mut body).await.unwrap();
                    let request = serde_json::from_slice(&body).unwrap_or(Value::Null);
                    let (status, response, pause, oversized) = {
                        let mut world = state.lock().unwrap();
                        world.requests.push(line.clone());
                        let url = reqwest::Url::parse(&format!("http://fixture{}", line.split_whitespace().nth(1).unwrap())).unwrap();
                        let pause = !world.pause.is_empty() && line.contains(&world.pause);
                        let oversized = !world.oversized.is_empty() && line.contains(&world.oversized);
                        let mismatched = !world.mismatched.is_empty() && line.contains(&world.mismatched);
                        let (status, mut response) = answer(&mut world, &line, &url, request);
                        if mismatched { response["id"] = json!("another-message"); }
                        (status, response.to_string(), pause, oversized)
                    };
                    if pause {
                        ready.notify_one();
                        while !state.lock().unwrap().pause.is_empty() {
                            tokio::time::sleep(Duration::from_millis(5)).await;
                        }
                    }
                    let length = if oversized { 512 * 1024 * 1024 } else { response.len() };
                    let reply = format!("HTTP/1.1 {status} Fixture\r\nContent-Type: application/json\r\nContent-Length: {length}\r\nConnection: close\r\n\r\n{response}");
                    let _ = socket.write_all(reply.as_bytes()).await;
                });
            }
        });
        Self {
            origin,
            world,
            paused,
            task,
        }
    }

    async fn interrupt(&self, step: impl std::future::Future<Output = Result<bool, &'static str>>) {
        tokio::select! {
            result = step => panic!("sync completed before the controlled request paused: {result:?}"),
            () = self.paused.notified() => {},
            () = tokio::time::sleep(Duration::from_secs(10)) => {
                panic!("sync did not reach the controlled provider pause");
            }
        }
    }
}

impl Drop for Provider {
    fn drop(&mut self) {
        self.task.abort();
    }
}

fn answer(world: &mut World, line: &str, url: &reqwest::Url, body: Value) -> (u16, Value) {
    let path = url.path();
    if path == "/token" {
        return (
            200,
            json!({"access_token":"synthetic-access","expires_in":3600}),
        );
    }
    if world.unauthorized {
        return (401, json!({"error":{"errors":[{"reason":"authError"}]}}));
    }
    if path.ends_with("/profile") {
        return (
            200,
            json!({"historyId":"100","messagesTotal":2,"emailAddress":ACCOUNT}),
        );
    }
    if path.ends_with("/history") {
        if world.expired_history {
            return (404, json!({}));
        }
        if world.paginated_history
            && !url
                .query_pairs()
                .any(|(key, value)| key == "pageToken" && !value.is_empty())
        {
            return (
                200,
                json!({"historyId":"200","nextPageToken":"history-two"}),
            );
        }
        return (200, json!({"historyId":"200"}));
    }
    if path.ends_with("/labels") {
        return (200, json!({"labels":[{"id":"INBOX","name":"INBOX"}]}));
    }
    if path.contains("/attachments/") {
        use base64::Engine as _;
        return (200, json!({"data":base64::engine::general_purpose::URL_SAFE_NO_PAD.encode("Downloaded body text"),"size":20}));
    }
    if path.contains("/threads/") {
        return (200, json!({"id":"thread","messages":world.messages.values().cloned().collect::<Vec<_>>()}));
    }
    if path.ends_with("/messages") {
        if url
            .query_pairs()
            .any(|(key, value)| key == "labelIds" && value == "INBOX")
        {
            return (
                200,
                json!({"messages":world.messages.values().filter(|m| m["labelIds"].as_array().is_some_and(|labels|labels.iter().any(|l| l=="INBOX"))).map(|m|json!({"id":m["id"]})).collect::<Vec<_>>() }),
            );
        }
        return if url
            .query_pairs()
            .any(|(key, value)| key == "pageToken" && value == "page-two")
        {
            (200, json!({"messages":[{"id":"two"}]}))
        } else {
            (
                200,
                json!({"messages":[{"id":"one"}],"nextPageToken":"page-two"}),
            )
        };
    }
    if let Some(id) = path.strip_prefix("/gmail/v1/users/me/messages/") {
        if let Some(id) = id.strip_suffix("/modify") {
            assert!(line.starts_with("POST "));
            world.writes.push(body.clone());
            let Some(message) = world.messages.get_mut(id) else {
                return (404, json!({}));
            };
            let labels = message["labelIds"].as_array_mut().unwrap();
            labels.retain(|label| !body["removeLabelIds"].as_array().unwrap().contains(label));
            for label in body["addLabelIds"].as_array().unwrap() {
                if !labels.contains(label) {
                    labels.push(label.clone());
                }
            }
            return (200, message.clone());
        }
        return world
            .messages
            .get(id)
            .map(|m| (200, m.clone()))
            .unwrap_or((404, json!({})));
    }
    panic!("unexpected synthetic provider request: {line}")
}

fn credentials(fixture: &crate::mail::tests::AccountFixture) -> credentials::tests::StoreOverride {
    let directory = crate::platform::private_fs::directories(&fixture.config, &["omamail"], true)
        .unwrap()
        .unwrap();
    crate::platform::private_fs::atomic_replace(&directory, "credentials.json",
        json!({"installed":{"client_id":"123-replica.apps.googleusercontent.com","client_secret":"synthetic-secret"}}).to_string().as_bytes()).unwrap();
    credentials::tests::isolated_store(credentials::tests::SingleCredential {
        key: credentials::CredentialKey {
            provider: "gmail".into(),
            account_id: ACCOUNT.into(),
            kind: credentials::CredentialKind::GoogleRefreshToken {
                client_id: "123-replica.apps.googleusercontent.com".into(),
            },
        },
        secret: credentials::Secret::new(b"synthetic-refresh".to_vec()).unwrap(),
    })
}

fn set(store: &store::Store, key: &str, value: &str) {
    store.write(|db| store::set_state(db, key, value)).unwrap();
}

async fn synchronize(local: &LocalMail, gmail: &gmail::Session) {
    let store = local.store(ACCOUNT).await.unwrap();
    for _ in 0..8 {
        set(&store, "lastHistory", "0");
        sync::step(&store, gmail, ACCOUNT).await.unwrap();
        if store.status().unwrap()["complete"] == true
            && store.status().unwrap()["health"]["inboxKnown"] == true
        {
            return;
        }
    }
    panic!(
        "synthetic inventory did not finish: {}",
        store.status().unwrap()
    );
}

#[tokio::test]
async fn cached_mail_survives_auth_failure_and_offline_edits_reconcile_with_provider() {
    if isolated() {
        return;
    }
    let fixture =
        account_fixture(json!({"version":1,"accounts":[{"provider":"gmail","email":ACCOUNT}]}));
    let _credential = credentials(&fixture);
    let provider = Provider::new().await;
    let client = reqwest::Client::builder().no_proxy().build().unwrap();
    gmail_http::with_test_transport(client, provider.origin.clone(), async {
        let local = LocalMail::default();
        let gmail = gmail::Session::default();
        synchronize(&local, &gmail).await;
        let store = local.store(ACCOUNT).await.unwrap();
        provider.world.lock().unwrap().unauthorized = true;
        set(&store, "lastHistory", "0");
        assert_eq!(sync::step(&store, &gmail, ACCOUNT).await, Err("gmail_unauthorized"));
        let requests = provider.world.lock().unwrap().requests.len();
        let list = local.call("local.list", &json!({"accountId":ACCOUNT,"query":"in:inbox","limit":50})).await.unwrap();
        assert_eq!(list["summaries"].as_array().unwrap().len(), 2);
        assert_eq!(local.call("local.labelCounts", &json!({"accountId":ACCOUNT,"id":"INBOX"})).await.unwrap()["unread"], 2);
        assert!(local.read(ACCOUNT, "one", &gmail).await.unwrap()["payload"]["body"]["data"].is_string());
        assert_eq!(provider.world.lock().unwrap().requests.len(), requests, "cached reads must not contact the unauthorized provider");
        local.call("local.edit", &json!({"accountId":ACCOUNT,"ticket":"undo","ids":["one"],"addLabelIds":["STARRED"],"removeLabelIds":[]})).await.unwrap();
        local.call("local.cancelEdit", &json!({"accountId":ACCOUNT,"ticket":"undo"})).await.unwrap();
        assert!(!store.resource("one").unwrap().unwrap()["labelIds"].as_array().unwrap().contains(&json!("STARRED")));
        for (ticket, add, remove) in [("star", vec!["STARRED"], vec![]), ("unstar", vec![], vec!["STARRED"]), ("read-archive", vec![], vec!["UNREAD","INBOX"])] {
            local.call("local.edit", &json!({"accountId":ACCOUNT,"ticket":ticket,"ids":["one"],"addLabelIds":add,"removeLabelIds":remove})).await.unwrap();
        }
        assert_eq!(local.call("local.labelCounts", &json!({"accountId":ACCOUNT,"id":"INBOX"})).await.unwrap()["total"], 1);
        assert!(provider.world.lock().unwrap().writes.is_empty());
        drop(store);
        local.shutdown().await;
        drop(local);
        let restarted = LocalMail::default();
        let store = restarted.store(ACCOUNT).await.unwrap();
        assert!(store.status().unwrap()["pendingEdits"].as_u64().unwrap() > 0);
        provider.world.lock().unwrap().unauthorized = false;
        sync::step(&store, &gmail, ACCOUNT).await.unwrap();
        assert_eq!(store.status().unwrap()["pendingEdits"], 0);
        let world = provider.world.lock().unwrap();
        assert_eq!(world.writes.len(), 1, "rapid reversals must coalesce to one mutation");
        assert_eq!(world.messages["one"]["labelIds"], json!([]));
        drop(world);
        restarted.call("local.edit", &json!({"accountId":ACCOUNT,"ticket":"deleted","ids":["two"],"addLabelIds":["STARRED"],"removeLabelIds":[]})).await.unwrap();
        provider.world.lock().unwrap().messages.remove("two");
        sync::step(&store, &gmail, ACCOUNT).await.unwrap();
        assert_eq!(store.status().unwrap()["editConflicts"], 1);
        let edits = store.edits().unwrap();
        let conflict = edits.as_array().unwrap().iter().find(|edit| edit["ticket"] == "deleted").unwrap();
        assert_eq!(conflict["error"], "message_deleted");
        assert_eq!(provider.world.lock().unwrap().writes.len(), 1, "a deleted message must not receive a mutation");
        restarted.shutdown().await;
    }).await;
}

#[tokio::test]
async fn interrupted_provider_body_keeps_inventory_checkpoint_and_unvisited_mail() {
    if isolated() {
        return;
    }
    let fixture =
        account_fixture(json!({"version":1,"accounts":[{"provider":"gmail","email":ACCOUNT}]}));
    let _credential = credentials(&fixture);
    let provider = Provider::new().await;
    let client = reqwest::Client::builder().no_proxy().build().unwrap();
    gmail_http::with_test_transport(client, provider.origin.clone(), async {
        let local = LocalMail::default();
        let gmail = gmail::Session::default();
        let store = local.store(ACCOUNT).await.unwrap();
        store
            .put(&message("unvisited", "preserved until reconciliation"), 0)
            .unwrap();
        set(&store, "legacyImported", "true");
        provider.world.lock().unwrap().pause = "/messages/one".into();
        provider
            .interrupt(sync::step(&store, &gmail, ACCOUNT))
            .await;
        assert!(
            provider
                .world
                .lock()
                .unwrap()
                .requests
                .iter()
                .any(|r| r.contains("/messages/one?")),
            "the real body request must have started"
        );
        assert_eq!(
            store.read(|db| store::state(db, "page")).unwrap(),
            "page-two"
        );
        assert_eq!(store.status().unwrap()["complete"], false);
        assert!(store.resource("unvisited").unwrap().is_some());
        assert!(store.resource("one").unwrap().is_none());
        drop(store);
        local.shutdown().await;
        drop(local);
        provider.world.lock().unwrap().pause.clear();
        let restarted = LocalMail::default();
        synchronize(&restarted, &gmail).await;
        let store = restarted.store(ACCOUNT).await.unwrap();
        assert_eq!(store.status().unwrap()["complete"], true);
        assert!(store.resource("unvisited").unwrap().is_none());
        assert!(store.complete_resource("one").unwrap().is_some());
        assert!(store.complete_resource("two").unwrap().is_some());
        restarted.shutdown().await;
    })
    .await;
}

#[tokio::test]
async fn interrupted_inventory_and_history_requests_resume_their_saved_page() {
    if isolated() {
        return;
    }
    let fixture =
        account_fixture(json!({"version":1,"accounts":[{"provider":"gmail","email":ACCOUNT}]}));
    let _credential = credentials(&fixture);
    let provider = Provider::new().await;
    let client = reqwest::Client::builder().no_proxy().build().unwrap();
    gmail_http::with_test_transport(client, provider.origin.clone(), async {
        let gmail = gmail::Session::default();
        let mut local = LocalMail::default();
        let mut store = local.store(ACCOUNT).await.unwrap();
        store
            .put(
                &{
                    let mut m = message("unvisited", "kept during partial inventory");
                    m["labelIds"] = json!([]);
                    m
                },
                0,
            )
            .unwrap();
        set(&store, "legacyImported", "true");
        sync::step(&store, &gmail, ACCOUNT).await.unwrap();
        assert_eq!(
            store.read(|db| store::state(db, "page")).unwrap(),
            "page-two"
        );
        for (pause, checkpoint, expected) in [
            ("pageToken=page-two", "page", "page-two"),
            ("pageToken=history-two", "historyPage", "history-two"),
        ] {
            if checkpoint == "historyPage" {
                provider.world.lock().unwrap().paginated_history = true;
                set(&store, "lastHistory", "0");
                sync::step(&store, &gmail, ACCOUNT).await.unwrap();
            }
            provider.world.lock().unwrap().pause = pause.into();
            provider
                .interrupt(sync::step(&store, &gmail, ACCOUNT))
                .await;
            assert!(
                provider
                    .world
                    .lock()
                    .unwrap()
                    .requests
                    .iter()
                    .any(|line| line.contains(pause))
            );
            assert_eq!(
                store.read(|db| store::state(db, checkpoint)).unwrap(),
                expected
            );
            assert!(store.resource("unvisited").unwrap().is_some());
            assert_eq!(store.status().unwrap()["inventoryComplete"], false);
            drop(store);
            local.shutdown().await;
            drop(local);
            local = LocalMail::default();
            store = local.store(ACCOUNT).await.unwrap();
            assert_eq!(
                store.read(|db| store::state(db, checkpoint)).unwrap(),
                expected
            );
            provider.world.lock().unwrap().pause.clear();
            sync::step(&store, &gmail, ACCOUNT).await.unwrap();
        }
        assert!(store.resource("unvisited").unwrap().is_none());
        synchronize(&local, &gmail).await;
        assert_eq!(store.status().unwrap()["complete"], true);
        store
            .put(
                &message("retained", "kept while expired history rebuilds"),
                0,
            )
            .unwrap();
        provider.world.lock().unwrap().expired_history = true;
        set(&store, "lastHistory", "0");
        sync::step(&store, &gmail, ACCOUNT).await.unwrap();
        assert!(store.resource("retained").unwrap().is_some());
        assert_eq!(store.status().unwrap()["inventoryComplete"], false);
        provider.world.lock().unwrap().expired_history = false;
        provider.world.lock().unwrap().paginated_history = false;
        synchronize(&local, &gmail).await;
        assert!(store.resource("retained").unwrap().is_none());
        local.shutdown().await;
    })
    .await;
}

#[cfg(target_os = "linux")]
#[tokio::test]
#[ignore = "requires an isolated tmpfs smaller than 1 GiB; scripts/test-low-space.py"]
async fn low_space_refuses_body_download_and_preserves_saved_mail() {
    if let Some(path) = std::env::var_os("MAGPIE_LOW_SPACE_SEED") {
        let store = store::Store::open(super::tests::open_directory(&std::path::PathBuf::from(
            path,
        )))
        .unwrap();
        store
            .put(&message("saved", "saved body remains readable"), 0)
            .unwrap();
        return;
    }
    if isolated() {
        return;
    }
    let fixture =
        account_fixture(json!({"version":1,"accounts":[{"provider":"gmail","email":ACCOUNT}]}));
    let _credential = credentials(&fixture);
    let provider = Provider::new().await;
    let client = reqwest::Client::builder().no_proxy().build().unwrap();
    gmail_http::with_test_transport(client, provider.origin.clone(), async {
        let gmail = gmail::Session::default();
        let directory = std::path::PathBuf::from("/tmp/mail-check/store");
        let store = store::Store::open(super::tests::open_directory(&directory)).unwrap();
        assert!(
            crate::platform::private_fs::available_bytes(store.directory()).unwrap()
                < 1024 * 1024 * 1024
        );
        assert_eq!(
            store.put(&message("unsaved", "refused body"), 0),
            Err("local_disk_low")
        );
        set(&store, "legacyImported", "true");
        assert_eq!(
            sync::step(&store, &gmail, ACCOUNT).await,
            Err("local_disk_low")
        );
        assert!(store.resource("saved").unwrap().is_some());
        assert_eq!(store.status().unwrap()["complete"], false);
        assert!(
            provider
                .world
                .lock()
                .unwrap()
                .requests
                .iter()
                .all(|line| !line.contains("/messages/one")),
            "low space must refuse before a body request"
        );
        assert!(store.resource("unsaved").unwrap().is_none());
        drop(store);
        std::fs::remove_dir_all(directory).unwrap();
    })
    .await;
}

#[tokio::test]
async fn attached_multipart_descendants_never_start_body_downloads() {
    if isolated() {
        return;
    }
    let fixture =
        account_fixture(json!({"version":1,"accounts":[{"provider":"gmail","email":ACCOUNT}]}));
    let _credential = credentials(&fixture);
    let provider = Provider::new().await;
    let client = reqwest::Client::builder().no_proxy().build().unwrap();
    gmail_http::with_test_transport(client, provider.origin.clone(), async {
        let gmail = gmail::Session::default();
        for foreground in [false, true] {
            let mut resource = json!({"payload":{"mimeType":"multipart/mixed","headers":[{"name":"Content-Disposition","value":"attachment"}],"parts":[{"mimeType":"text/plain","body":{"attachmentId":"private-attached-body","size":10}}]}});
            let before = resource.clone();
            let result = sync::hydrate_text(&gmail, ACCOUNT, "one", &mut resource, foreground).await;
            assert!(provider.world.lock().unwrap().requests.is_empty(), "attachment subtree must not contact provider");
            assert_eq!(result, Ok(()));
            assert_eq!(resource, before);
        }
    }).await;
}

#[tokio::test]
async fn legacy_and_expired_inventory_refresh_labels_without_reloading_bodies_or_writing_gmail() {
    if isolated() {
        return;
    }
    let fixture =
        account_fixture(json!({"version":1,"accounts":[{"provider":"gmail","email":ACCOUNT}]}));
    let _credential = credentials(&fixture);
    let provider = Provider::new().await;
    let client = reqwest::Client::builder().no_proxy().build().unwrap();
    gmail_http::with_test_transport(client, provider.origin.clone(), async {
        crate::cache::resource::put(ACCOUNT, "one", &message("one", "saved legacy body"))
            .await
            .unwrap();
        provider
            .world
            .lock()
            .unwrap()
            .messages
            .get_mut("one")
            .unwrap()["labelIds"] = json!([]);
        let local = LocalMail::default();
        let gmail = gmail::Session::default();
        synchronize(&local, &gmail).await;
        let store = local.store(ACCOUNT).await.unwrap();
        assert_eq!(store.label_counts("INBOX").unwrap()["total"], 1);
        assert_eq!(
            store.resource("one").unwrap().unwrap()["labelIds"],
            json!([])
        );
        assert_eq!(
            store.resource("one").unwrap().unwrap()["payload"]["body"]["data"],
            message("one", "saved legacy body")["payload"]["body"]["data"]
        );
        assert!(
            provider
                .world
                .lock()
                .unwrap()
                .requests
                .iter()
                .any(|r| r.contains("/messages/one?format=minimal"))
        );
        assert!(
            !provider
                .world
                .lock()
                .unwrap()
                .requests
                .iter()
                .any(|r| r.contains("/messages/one?format=full"))
        );
        provider
            .world
            .lock()
            .unwrap()
            .messages
            .get_mut("two")
            .unwrap()["labelIds"] = json!(["STARRED"]);
        sync::restart_inventory(&store).unwrap();
        synchronize(&local, &gmail).await;
        assert_eq!(store.label_counts("INBOX").unwrap()["total"], 0);
        assert_eq!(
            store.resource("two").unwrap().unwrap()["labelIds"],
            json!(["STARRED"])
        );
        assert!(
            provider.world.lock().unwrap().writes.is_empty(),
            "metadata repair must not change Gmail"
        );
        local.shutdown().await;
    })
    .await;
}

#[tokio::test]
async fn upgrading_a_completed_replica_repairs_existing_labels_once() {
    if isolated() {
        return;
    }
    let fixture =
        account_fixture(json!({"version":1,"accounts":[{"provider":"gmail","email":ACCOUNT}]}));
    let _credential = credentials(&fixture);
    let provider = Provider::new().await;
    let client = reqwest::Client::builder().no_proxy().build().unwrap();
    gmail_http::with_test_transport(client, provider.origin.clone(), async {
        let gmail = gmail::Session::default();
        let local = LocalMail::default();
        let store = local.store(ACCOUNT).await.unwrap();
        for id in ["one", "two"] {
            store.put(&message(id, "retained body"), 4).unwrap();
        }
        for (key, value) in [
            ("history", "200"),
            ("generation", "4"),
            ("legacyImported", "true"),
            ("inventoryListed", "true"),
            ("inventoryComplete", "true"),
        ] {
            set(&store, key, value);
        }
        assert_eq!(store.status().unwrap()["complete"], true);
        provider
            .world
            .lock()
            .unwrap()
            .messages
            .get_mut("one")
            .unwrap()
            .as_object_mut()
            .unwrap()
            .remove("labelIds");
        sync::step(&store, &gmail, ACCOUNT).await.unwrap();
        assert_eq!(store.status().unwrap()["complete"], false);
        drop(store);
        local.shutdown().await;
        drop(local);
        let restarted = LocalMail::default();
        synchronize(&restarted, &gmail).await;
        let store = restarted.store(ACCOUNT).await.unwrap();
        assert_eq!(store.label_counts("INBOX").unwrap()["total"], 1);
        assert_eq!(
            store.resource("one").unwrap().unwrap()["labelIds"],
            json!([])
        );
        let generation = store.read(|db| store::state(db, "generation")).unwrap();
        sync::repair_inventory(&store).unwrap();
        assert_eq!(
            store.read(|db| store::state(db, "generation")).unwrap(),
            generation
        );
        assert!(provider.world.lock().unwrap().writes.is_empty());
        restarted.shutdown().await;
    })
    .await;
}

#[tokio::test]
async fn content_jobs_ignore_stale_cached_labels_and_refuse_wrong_message_identity() {
    if isolated() {
        return;
    }
    let fixture =
        account_fixture(json!({"version":1,"accounts":[{"provider":"gmail","email":ACCOUNT}]}));
    let _credential = credentials(&fixture);
    let provider = Provider::new().await;
    let client = reqwest::Client::builder().no_proxy().build().unwrap();
    gmail_http::with_test_transport(client, provider.origin.clone(), async {
        crate::cache::resource::put(ACCOUNT, "one", &message("one", "old body"))
            .await
            .unwrap();
        let local = LocalMail::default();
        let gmail = gmail::Session::default();
        let store = local.store(ACCOUNT).await.unwrap();
        set(&store, "legacyImported", "true");
        provider
            .world
            .lock()
            .unwrap()
            .messages
            .get_mut("one")
            .unwrap()["labelIds"] = json!([]);
        synchronize(&local, &gmail).await;
        assert_eq!(
            store.resource("one").unwrap().unwrap()["labelIds"],
            json!([])
        );
        assert!(
            provider
                .world
                .lock()
                .unwrap()
                .requests
                .iter()
                .any(|r| r.contains("/messages/one?format=full"))
        );
        store.put_cached(&message("one", "saved body"), 1).unwrap();
        let before = store.resource("two").unwrap();
        provider
            .world
            .lock()
            .unwrap()
            .messages
            .get_mut("one")
            .unwrap()["id"] = json!("two");
        assert_eq!(
            sync::step(&store, &gmail, ACCOUNT).await,
            Err("gmail_invalid_response")
        );
        assert_eq!(store.resource("two").unwrap(), before);
        assert_eq!(store.status().unwrap()["pending"], 1);
        assert!(provider.world.lock().unwrap().writes.is_empty());
        local.shutdown().await;
    })
    .await;
}

#[tokio::test]
async fn delayed_foreground_reads_cannot_erase_history_repairs_or_resurrect_deleted_mail() {
    if isolated() {
        return;
    }
    let fixture =
        account_fixture(json!({"version":1,"accounts":[{"provider":"gmail","email":ACCOUNT}]}));
    let _credential = credentials(&fixture);
    let provider = Provider::new().await;
    let client = reqwest::Client::builder().no_proxy().build().unwrap();
    gmail_http::with_test_transport(client, provider.origin.clone(), async {
        let local = LocalMail::default();
        let gmail = gmail::Session::default();
        let store = local.store(ACCOUNT).await.unwrap();
        for (key, value) in [
            ("legacyImported", "true"),
            ("labelInventoryVersion", "1"),
            ("history", "200"),
            ("inventoryListed", "true"),
            ("inventoryComplete", "true"),
            ("inboxListed", "true"),
            ("inboxReady", "true"),
        ] {
            set(&store, key, value);
        }
        for (id, deleted) in [("one", false), ("two", true)] {
            provider.world.lock().unwrap().pause = format!("/messages/{id}?");
            let reading = local.read(ACCOUNT, id, &gmail);
            tokio::pin!(reading);
            let deadline = tokio::time::Instant::now() + Duration::from_secs(10);
            loop {
                assert!(
                    tokio::time::timeout(Duration::from_millis(20), &mut reading)
                        .await
                        .is_err()
                );
                if provider
                    .world
                    .lock()
                    .unwrap()
                    .requests
                    .iter()
                    .any(|r| r.contains(&format!("/messages/{id}?")))
                {
                    break;
                }
                assert!(
                    tokio::time::Instant::now() < deadline,
                    "foreground request did not reach the controlled provider"
                );
            }
            let event = if deleted {
                json!({"messagesDeleted":[{"message":{"id":id}}]})
            } else {
                json!({"labelsRemoved":[{"message":{"id":id},"labelIds":["INBOX","UNREAD"]}]})
            };
            sync::apply_history(&store, &json!({"historyId":"300","history":[event]}), "").unwrap();
            provider.world.lock().unwrap().messages.get_mut(id).unwrap()["labelIds"] = json!([]);
            provider.world.lock().unwrap().pause.clear();
            let answer = tokio::time::timeout(Duration::from_secs(2), reading)
                .await
                .unwrap();
            if deleted {
                assert_eq!(answer, Err("gmail_not_found"));
                assert!(store.resource(id).unwrap().is_none());
            } else {
                answer.unwrap();
                assert_eq!(store.status().unwrap()["pending"], 1);
                sync::step(&store, &gmail, ACCOUNT).await.unwrap();
                assert_eq!(store.resource(id).unwrap().unwrap()["labelIds"], json!([]));
                assert_eq!(store.status().unwrap()["pending"], 0);
            }
        }
        assert!(provider.world.lock().unwrap().writes.is_empty());
        local.shutdown().await;
    })
    .await;
}

#[cfg(feature = "mobile")]
#[tokio::test]
async fn background_receive_preserves_pause_and_queued_edits_without_provider_writes() {
    if isolated() { return; }
    let fixture = account_fixture(json!({"version":1,"accounts":[{"provider":"gmail","email":ACCOUNT}]}));
    let _credential = credentials(&fixture);
    let provider = Provider::new().await;
    let client = reqwest::Client::builder().no_proxy().build().unwrap();
    gmail_http::with_test_transport(client, provider.origin.clone(), async {
        let local = LocalMail::default();
        let gmail = gmail::Session::default();
        synchronize(&local, &gmail).await;
        let store = local.store(ACCOUNT).await.unwrap();
        store.edit("pending-star", &["one".into()], &["STARRED".into()], &[]).unwrap();
        set(&store, "paused", "true");
        local.set_suspended(true);
        let requests = provider.world.lock().unwrap().requests.len();
        let paused = local.background_refresh(ACCOUNT, &gmail).await.unwrap();
        assert_eq!(paused["paused"], true);
        assert_eq!(provider.world.lock().unwrap().requests.len(), requests, "paused refresh must not reach Gmail");
        assert_eq!(store.status().unwrap()["pendingEdits"], 1);
        set(&store, "paused", "false");
        let result = local.background_refresh(ACCOUNT, &gmail).await.unwrap();
        assert_eq!(result["checked"], true, "must await history response: {result}");
        assert_eq!(result["ids"].as_array().unwrap().len(), 2);
        assert!(provider.world.lock().unwrap().writes.is_empty(), "background refresh cannot send queued edits");
        assert_eq!(store.status().unwrap()["pendingEdits"], 1);
        let requests = provider.world.lock().unwrap().requests.len();
        assert_eq!(local.background_refresh("foreign@example.test", &gmail).await, Err("local_account_unknown"));
        assert_eq!(provider.world.lock().unwrap().requests.len(), requests, "unknown account cannot reach Gmail");
        assert!(local.jobs.lock().unwrap().is_empty(), "background refresh must not start watchers");
        local.shutdown().await;
    }).await;
}

#[cfg(feature = "mobile")]
#[tokio::test]
async fn background_receive_waits_for_a_foreground_request_instead_of_failing() {
    if isolated() { return; }
    let fixture = account_fixture(json!({"version":1,"accounts":[{"provider":"gmail","email":ACCOUNT}]}));
    let _credential = credentials(&fixture);
    let provider = Provider::new().await;
    let client = reqwest::Client::builder().no_proxy().build().unwrap();
    gmail_http::with_test_transport(client, provider.origin.clone(), async {
        let local = LocalMail::default();
        let gmail = gmail::Session::default();
        synchronize(&local, &gmail).await;
        // A foreground request, as the snooze tick makes beside a background check, is in flight.
        provider.world.lock().unwrap().pause = "/profile".into();
        let profile = json!({"accountId":ACCOUNT});
        let foreground = gmail.call("gmail.profile", &profile);
        tokio::pin!(foreground);
        tokio::select! {
            result = &mut foreground => panic!("answered before the controlled pause: {result:?}"),
            _ = provider.paused.notified() => {},
            _ = tokio::time::sleep(Duration::from_secs(5)) => panic!("did not reach the profile request"),
        }
        let refresh = local.background_refresh(ACCOUNT, &gmail);
        tokio::pin!(refresh);
        tokio::select! {
            result = &mut refresh => panic!("the background check ended while a foreground request held Gmail: {result:?}"),
            _ = tokio::time::sleep(Duration::from_millis(600)) => {},
        }
        provider.world.lock().unwrap().pause.clear();
        let (result, answered) = tokio::join!(refresh, foreground);
        answered.unwrap();
        let result = result.unwrap();
        assert_eq!(result["checked"], true, "{result}");
        assert_eq!(result["error"], Value::Null, "{result}");
        local.shutdown().await;
    }).await;
}

#[tokio::test]
async fn a_message_fetch_deferred_for_a_foreground_request_is_not_put_off() {
    if isolated() { return; }
    let fixture = account_fixture(json!({"version":1,"accounts":[{"provider":"gmail","email":ACCOUNT}]}));
    let _credential = credentials(&fixture);
    let provider = Provider::new().await;
    let client = reqwest::Client::builder().no_proxy().build().unwrap();
    gmail_http::with_test_transport(client, provider.origin.clone(), async {
        let local = LocalMail::default();
        let gmail = gmail::Session::default();
        synchronize(&local, &gmail).await;
        let store = local.store(ACCOUNT).await.unwrap();
        provider.world.lock().unwrap().messages.insert("three".into(), message("three", "Synthetic new body"));
        let added = json!({"messagesAdded":[{"message":{"id":"three","threadId":"thread","labelIds":["INBOX","UNREAD"]}}]});
        sync::apply_history(&store, &json!({"historyId":"300","history":[added]}), "").unwrap();
        set(&store, "lastHistory", &chrono::Utc::now().timestamp_millis().to_string());
        // A foreground request, such as the snooze tick's, holds Gmail when the new message is fetched.
        provider.world.lock().unwrap().pause = "/profile".into();
        let profile = json!({"accountId":ACCOUNT});
        let foreground = gmail.call("gmail.profile", &profile);
        tokio::pin!(foreground);
        tokio::select! {
            result = &mut foreground => panic!("answered before the controlled pause: {result:?}"),
            _ = provider.paused.notified() => {},
            _ = tokio::time::sleep(Duration::from_secs(5)) => panic!("did not reach the profile request"),
        }
        assert_eq!(sync::receive(&store, &gmail, ACCOUNT).await, Err("gmail_request_deferred"));
        provider.world.lock().unwrap().pause.clear();
        foreground.await.unwrap();
        sync::receive(&store, &gmail, ACCOUNT).await.unwrap();
        assert!(store.resource("three").unwrap().is_some(), "the message is fetched as soon as Gmail is free");
        local.shutdown().await;
    }).await;
}

#[cfg(feature = "mobile")]
#[tokio::test]
async fn cancelled_background_history_does_not_claim_a_completed_check_and_can_resume() {
    if isolated() { return; }
    let fixture = account_fixture(json!({"version":1,"accounts":[{"provider":"gmail","email":ACCOUNT}]}));
    let _credential = credentials(&fixture);
    let provider = Provider::new().await;
    let client = reqwest::Client::builder().no_proxy().build().unwrap();
    gmail_http::with_test_transport(client, provider.origin.clone(), async {
        let local = LocalMail::default();
        let gmail = gmail::Session::default();
        synchronize(&local, &gmail).await;
        let store = local.store(ACCOUNT).await.unwrap();
        let before = store.status().unwrap()["health"]["lastChecked"].clone();
        provider.world.lock().unwrap().pause = "/history?".into();
        {
            let work = local.background_refresh(ACCOUNT, &gmail);
            tokio::pin!(work);
            tokio::select! {
                result = &mut work => panic!("completed before history response: {result:?}"),
                _ = provider.paused.notified() => {},
                _ = tokio::time::sleep(Duration::from_secs(5)) => panic!("did not reach history"),
            }
        }
        assert_eq!(store.status().unwrap()["health"]["lastChecked"], before);
        assert!(provider.world.lock().unwrap().writes.is_empty());
        provider.world.lock().unwrap().pause.clear();
        let result = local.background_refresh(ACCOUNT, &gmail).await.unwrap();
        assert_eq!(result["checked"], true);
        assert_eq!(result["ids"].as_array().unwrap().len(), 2);
        local.shutdown().await;
    }).await;
}

#[cfg(feature = "mobile")]
#[tokio::test]
async fn background_drain_tracks_cancelled_opens_before_the_store_exists_without_blocking() {
    if isolated() { return; }
    let _fixture = account_fixture(json!({"version":1,"accounts":[{"provider":"gmail","email":ACCOUNT}]}));
    let local = LocalMail::default();
    local.set_suspended(true);
    let held = local.stores.lock().unwrap();
    let gmail = gmail::Session::default();
    {
        let work = local.background_refresh(ACCOUNT, &gmail);
        tokio::pin!(work);
        tokio::select! {
            _ = &mut work => panic!("store opened through held mutex"),
            _ = tokio::time::sleep(Duration::from_millis(30)) => {},
        }
    }
    assert!(Arc::strong_count(&local.stores) > 1, "blocking open still owns the map");
    assert_eq!(local.drain(Duration::from_millis(30)).await, Err("local_busy"), "pending open cannot be mistaken for quiescence");
    drop(held);
    local.drain(Duration::from_secs(2)).await.unwrap();
    assert!(local.stores.lock().unwrap().contains_key(ACCOUNT));
    assert_eq!(Arc::strong_count(&local.stores), 1);
}

#[tokio::test]
async fn mail_that_can_never_be_saved_is_reported_and_never_fetched_in_full_again() {
    if isolated() { return; }
    let fixture = account_fixture(json!({"version":1,"accounts":[{"provider":"gmail","email":ACCOUNT}]}));
    let _credential = credentials(&fixture);
    let provider = Provider::new().await;
    {
        let mut world = provider.world.lock().unwrap();
        let mut damaged = message("damaged", "");
        damaged["payload"]["body"] = json!({"data":"*not base64*","size":12});
        world.messages.insert("damaged".into(), damaged);
        world.messages.insert("huge".into(), message("huge", "Synthetic body Gmail reports as too large"));
        world.oversized = "/messages/huge?format=full".into();
    }
    let client = reqwest::Client::builder().no_proxy().build().unwrap();
    gmail_http::with_test_transport(client, provider.origin.clone(), async {
        let local = LocalMail::default();
        let gmail = gmail::Session::default();
        let store = local.store(ACCOUNT).await.unwrap();
        for _ in 0..20 {
            set(&store, "lastHistory", "0");
            sync::step(&store, &gmail, ACCOUNT).await.unwrap();
        }
        let status = store.status().unwrap();
        assert_eq!(status["unsavedReasons"], json!({"gmail_response_too_large": 1, "local_text_unreadable": 1}), "{status}");
        assert_eq!((status["complete"].as_bool(), status["health"]["missing"].as_i64()), (Some(true), Some(0)), "{status}");
        // Listing the Inbox again queues both, but only for their labels.
        provider.world.lock().unwrap().requests.clear();
        set(&store, "inboxListed", "");
        set(&store, "inboxPage", "");
        for _ in 0..10 {
            set(&store, "lastHistory", "0");
            let _ = sync::step(&store, &gmail, ACCOUNT).await;
        }
        let requests = provider.world.lock().unwrap().requests.clone();
        assert!(requests.iter().any(|line| line.contains("/messages/damaged?format=minimal")), "{requests:?}");
        assert!(!requests.iter().any(|line| line.contains("format=full") && (line.contains("/messages/damaged") || line.contains("/messages/huge"))), "{requests:?}");
        local.shutdown().await;
    }).await;
}

#[tokio::test]
async fn a_failing_message_waits_longer_after_each_failed_fetch() {
    if isolated() { return; }
    let fixture = account_fixture(json!({"version":1,"accounts":[{"provider":"gmail","email":ACCOUNT}]}));
    let _credential = credentials(&fixture);
    let provider = Provider::new().await;
    {
        let mut world = provider.world.lock().unwrap();
        world.messages.insert("flaky".into(), message("flaky", "Synthetic body that never arrives intact"));
        world.mismatched = "/messages/flaky?format=full".into();
    }
    let client = reqwest::Client::builder().no_proxy().build().unwrap();
    gmail_http::with_test_transport(client, provider.origin.clone(), async {
        let local = LocalMail::default();
        let gmail = gmail::Session::default();
        let store = local.store(ACCOUNT).await.unwrap();
        let job = || -> Option<(i64, i64, String)> {
            use rusqlite::OptionalExtension;
            store.read(|db| store::sql(db.query_row("SELECT attempts,retry_at,error FROM jobs WHERE id='flaky' AND kind='content'", [], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?))).optional())).unwrap()
        };
        let mut waits = Vec::new();
        for _ in 0..30 {
            if waits.len() == 2 { break; }
            set(&store, "lastHistory", "0");
            let before = chrono::Utc::now().timestamp_millis();
            let _ = sync::step(&store, &gmail, ACCOUNT).await;
            let after = chrono::Utc::now().timestamp_millis();
            if let Some((attempts, retry_at, error)) = job()
                && attempts as usize == waits.len() + 1
            {
                assert_eq!(error, "gmail_invalid_response");
                waits.push((retry_at - after, retry_at - before));
                // Make it due again at once, as if the wait had passed.
                store.write(|db| store::sql(db.execute("UPDATE jobs SET retry_at=0 WHERE id='flaky'", []))).unwrap();
            }
        }
        assert_eq!(waits.len(), 2, "{:?}", provider.world.lock().unwrap().requests);
        for ((shortest, longest), wait) in waits.into_iter().zip([60_000, 5 * 60_000]) {
            assert!(shortest <= wait && wait <= longest, "{shortest}..{longest} should hold {wait}");
        }
        local.shutdown().await;
    }).await;
}

#[tokio::test]
async fn opening_an_account_repairs_text_saved_under_the_old_rules() {
    if isolated() { return; }
    let _fixture = account_fixture(json!({"version":1,"accounts":[{"provider":"gmail","email":ACCOUNT}]}));
    {
        let local = LocalMail::default();
        let store = local.store(ACCOUNT).await.unwrap();
        let mixed = super::tests::with_payload("mixed", super::tests::part("text/plain; charset=ISO-2022-JP", b"\x1b$B$3$s\x1b(B hello \xff"));
        store.put(&mixed, 1).unwrap();
        store.write(|db| store::sql(db.execute_batch("UPDATE messages SET text_complete=0; DELETE FROM state WHERE key='textRepair';"))).unwrap();
        assert!(store.complete_resource("mixed").unwrap().is_none());
        drop(store);
        local.shutdown().await;
    }
    let local = LocalMail::default();
    let store = local.store(ACCOUNT).await.unwrap();
    assert!(store.complete_resource("mixed").unwrap().is_some(), "the account's store repairs itself when it opens");
    local.shutdown().await;
}

#[tokio::test]
async fn gmail_download_duration_is_measured_at_transport_and_reused_without_refetch() {
    if isolated() { return; }
    let fixture = account_fixture(json!({"version":1,"accounts":[{"provider":"gmail","email":ACCOUNT}]}));
    let _credential = credentials(&fixture);
    let provider = Provider::new().await;
    {
        let mut world = provider.world.lock().unwrap();
        world.messages.get_mut("one").unwrap()[gmail::DOWNLOAD_MS] = json!(99_999);
        world.messages.get_mut("one").unwrap()[gmail::DOWNLOAD_RUN] = json!({"origin":"forged"});
        world.messages.get_mut("two").unwrap()[gmail::DOWNLOAD_MS] = json!(99_999);
        world.messages.get_mut("two").unwrap()[gmail::DOWNLOAD_RUN] = json!({"origin":"forged"});
        world.pause = "/messages/one?".into();
    }
    let client = reqwest::Client::builder().no_proxy().build().unwrap();
    gmail_http::with_test_transport(client, provider.origin.clone(), async {
        let local = LocalMail::default();
        let gmail = gmail::Session::default();
        let delayed = async {
            provider.paused.notified().await;
            tokio::time::sleep(Duration::from_millis(90)).await;
            provider.world.lock().unwrap().pause.clear();
        };
        let (raw, ()) = tokio::join!(local.read(ACCOUNT,"one",&gmail), delayed);
        let raw = raw.unwrap();
        let millis = raw[gmail::DOWNLOAD_MS].as_u64().unwrap();
        assert_eq!(raw[gmail::DOWNLOAD_RUN]["origin"], if cfg!(feature="mobile") { "app" } else { "desktop" });
        assert!(raw[gmail::DOWNLOAD_RUN]["finishedAt"].as_i64().unwrap() >= raw[gmail::DOWNLOAD_RUN]["startedAt"].as_i64().unwrap());
        assert!((80..10_000).contains(&millis), "measured transport interval: {millis}");
        let requests = provider.world.lock().unwrap().requests.len();
        let cached = local.read(ACCOUNT,"one",&gmail).await.unwrap();
        assert_eq!(cached[gmail::DOWNLOAD_MS], millis);
        assert_eq!(cached[gmail::DOWNLOAD_RUN], raw[gmail::DOWNLOAD_RUN]);
        assert!(cached[gmail::DOWNLOAD_START].is_null(), "in-flight lifecycle token is not persisted");
        assert_eq!(provider.world.lock().unwrap().requests.len(), requests, "details/rewrite never refetch for a timer");
        let replica = gmail.replica_call(ACCOUNT,"content",&json!({"id":"two"})).await.unwrap();
        assert!(replica[gmail::DOWNLOAD_MS].as_u64().unwrap() < 99_999);
        let minimal = gmail.replica_call(ACCOUNT,"minimal",&json!({"id":"two"})).await.unwrap();
        assert!(minimal[gmail::DOWNLOAD_MS].is_null());
        assert!(minimal[gmail::DOWNLOAD_RUN].is_null());
        let metadata = gmail.call("gmail.read", &json!({"accountId":ACCOUNT,"id":"two","full":false})).await.unwrap();
        assert!(metadata[gmail::DOWNLOAD_MS].is_null());
        assert!(metadata[gmail::DOWNLOAD_RUN].is_null());
        local.shutdown().await;
    }).await;
}

#[cfg(feature = "mobile")]
#[tokio::test]
async fn background_refresh_records_download_origin_independently_of_later_app_reads() {
    if isolated() { return; }
    let fixture = account_fixture(json!({"version":1,"accounts":[{"provider":"gmail","email":ACCOUNT}]}));
    let _credential = credentials(&fixture);
    let provider = Provider::new().await;
    let client = reqwest::Client::builder().no_proxy().build().unwrap();
    gmail_http::with_test_transport(client, provider.origin.clone(), async {
        let engine = crate::backend::Engine::default();
        let result = engine.mobile_background_refresh(&json!({})).await.unwrap();
        assert!(result["accounts"][0]["error"].is_null(), "{result}");
        let before = provider.world.lock().unwrap().requests.len();
        let raw = engine.fetch_resource(ACCOUNT,"one").await.unwrap();
        assert_eq!(raw[gmail::DOWNLOAD_RUN]["origin"], "backgroundRefresh");
        assert_eq!(provider.world.lock().unwrap().requests.len(),before,"reading the recorded context must not redownload mail");
    }).await;
}

#[cfg(feature = "mobile")]
#[tokio::test]
async fn download_context_includes_a_delayed_body_fetch_and_later_partial_hydration() {
    if isolated() { return; }
    let fixture = account_fixture(json!({"version":1,"accounts":[{"provider":"gmail","email":ACCOUNT}]}));
    let _credential = credentials(&fixture);
    let provider = Provider::new().await;
    {
        let mut world = provider.world.lock().unwrap();
        world.messages.get_mut("one").unwrap()["payload"]["body"] = json!({"attachmentId":"body","size":20});
        world.pause = "/attachments/body".into();
    }
    struct Restore;
    impl Drop for Restore { fn drop(&mut self) { crate::inbox::claude::diagnostics::foreground(true); } }
    let _restore = Restore;
    crate::inbox::claude::diagnostics::foreground(true);
    let client = reqwest::Client::builder().no_proxy().build().unwrap();
    gmail_http::with_test_transport(client, provider.origin.clone(), async {
        let local = LocalMail::default();
        let gmail = gmail::Session::default();
        let leave = async {
            provider.paused.notified().await;
            crate::inbox::claude::diagnostics::foreground(false);
            tokio::time::sleep(Duration::from_millis(40)).await;
            provider.world.lock().unwrap().pause.clear();
        };
        let (raw, ()) = tokio::join!(local.read(ACCOUNT,"one",&gmail), leave);
        let raw = raw.unwrap();
        assert_eq!(raw[gmail::DOWNLOAD_RUN]["startedActive"],true);
        assert_eq!(raw[gmail::DOWNLOAD_RUN]["finishedActive"],false);
        assert_eq!(raw[gmail::DOWNLOAD_RUN]["leftApp"],true);
        assert!(raw[gmail::DOWNLOAD_RUN]["remainingText"].is_null());
        let interval = raw[gmail::DOWNLOAD_RUN]["finishedAt"].as_i64().unwrap() - raw[gmail::DOWNLOAD_RUN]["startedAt"].as_i64().unwrap();
        assert!(interval >= 35,"body fetch must be inside the recorded download interval: {interval}");
        crate::inbox::claude::diagnostics::foreground(true);
        let store = local.store(ACCOUNT).await.unwrap();
        let mut partial = message("partial","");
        partial["payload"]["body"] = json!({"attachmentId":"body","size":20});
        store.put_cached(&partial,1).unwrap();
        let later = local.read(ACCOUNT,"partial",&gmail).await.unwrap();
        assert_eq!(later[gmail::DOWNLOAD_RUN]["origin"],"app");
        assert_eq!(later[gmail::DOWNLOAD_RUN]["remainingText"],true);
        assert!(later[gmail::DOWNLOAD_MS].is_u64());
        let cached = local.read(ACCOUNT,"partial",&gmail).await.unwrap();
        assert_eq!(cached[gmail::DOWNLOAD_RUN],later[gmail::DOWNLOAD_RUN]);
        local.shutdown().await;
    }).await;
}

#[tokio::test]
async fn direct_and_thread_downloads_are_recorded_without_storing_or_copying_mail_bodies() {
    if isolated() { return; }
    let fixture = account_fixture(json!({"version":1,"accounts":[{"provider":"gmail","email":ACCOUNT}]}));
    let _credential = credentials(&fixture);
    let provider = Provider::new().await;
    let client = reqwest::Client::builder().no_proxy().build().unwrap();
    gmail_http::with_test_transport(client, provider.origin.clone(), async {
        let engine = crate::backend::Engine::default();
        let raw = engine.dispatch("gmail.read", &json!({"accountId":ACCOUNT,"id":"one","full":true})).await.unwrap();
        assert!(raw[gmail::DOWNLOAD_RUN]["startedAt"].is_i64());
        let rows = engine.fetch_thread_resources(ACCOUNT,"thread").await.unwrap();
        assert_eq!(rows.len(),2);
        drop(engine);
        let local = LocalMail::default();
        let store = local.store(ACCOUNT).await.unwrap();
        let recorded = store.read(|db| store::sql(db.query_row("SELECT COUNT(*) FROM message_download_runs",[],|row| row.get::<_,i64>(0)))).unwrap();
        assert_eq!(recorded,2,"both thread message IDs have their own local download record");
        assert_eq!(store.read(|db| store::sql(db.query_row("SELECT COUNT(*) FROM messages",[],|row| row.get::<_,i64>(0)))).unwrap(),0,"metadata recording does not copy the bodies into the local mail store");
        drop(store);
        local.shutdown().await;
    }).await;
}
