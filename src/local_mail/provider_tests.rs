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
}

struct Provider {
    origin: String,
    world: Arc<Mutex<World>>,
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
        }));
        let state = world.clone();
        let task = tokio::spawn(async move {
            let mut handlers = tokio::task::JoinSet::new();
            loop {
                let (mut socket, _) = listener.accept().await.unwrap();
                let state = state.clone();
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
                    let (status, response, pause) = {
                        let mut world = state.lock().unwrap();
                        world.requests.push(line.clone());
                        let url = reqwest::Url::parse(&format!("http://fixture{}", line.split_whitespace().nth(1).unwrap())).unwrap();
                        let pause = !world.pause.is_empty() && line.contains(&world.pause);
                        let (status, response) = answer(&mut world, &line, &url, request);
                        (status, response.to_string(), pause)
                    };
                    if pause {
                        while !state.lock().unwrap().pause.is_empty() {
                            tokio::time::sleep(Duration::from_millis(5)).await;
                        }
                    }
                    let reply = format!("HTTP/1.1 {status} Fixture\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{response}", response.len());
                    let _ = socket.write_all(reply.as_bytes()).await;
                });
            }
        });
        Self {
            origin,
            world,
            task,
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
    if path.ends_with("/messages") {
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
        if store.status().unwrap()["complete"] == true {
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
        assert!(
            tokio::time::timeout(
                Duration::from_millis(300),
                sync::step(&store, &gmail, ACCOUNT)
            )
            .await
            .is_err()
        );
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
            .put(&message("unvisited", "kept during partial inventory"), 0)
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
            assert!(
                tokio::time::timeout(
                    Duration::from_millis(300),
                    sync::step(&store, &gmail, ACCOUNT)
                )
                .await
                .is_err()
            );
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
