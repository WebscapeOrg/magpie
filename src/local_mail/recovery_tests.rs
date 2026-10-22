use super::{
    store::{self, Store},
    sync,
    tests::{directory, message, open_directory},
};
use serde_json::json;
use std::{path::PathBuf, sync::Arc};

struct Mailbox(PathBuf);
impl Mailbox {
    fn new() -> Self {
        Self(directory())
    }
    fn open(&self) -> Arc<Store> {
        Store::open(open_directory(&self.0)).unwrap()
    }
}
impl Drop for Mailbox {
    fn drop(&mut self) {
        std::fs::remove_dir_all(&self.0).unwrap();
    }
}
fn checkpoint(store: &Store, key: &str) -> String {
    store.read(|db| store::state(db, key)).unwrap()
}
fn set(store: &Store, key: &str, value: &str) {
    store.write(|db| store::set_state(db, key, value)).unwrap();
}

#[test]
fn inventory_and_history_checkpoints_survive_process_exit() {
    if let Some(path) = std::env::var_os("MAGPIE_RECOVERY_CHILD") {
        let store = Store::open(open_directory(&PathBuf::from(path))).unwrap();
        match std::env::var("MAGPIE_RECOVERY_PHASE").unwrap().as_str() {
            "inventory" => {
                store.put(&message("seen", "cached body"), 1).unwrap();
                store
                    .put(&message("unvisited", "kept until reconciliation"), 1)
                    .unwrap();
                store
                    .edit("pending", &["unvisited".into()], &["STARRED".into()], &[])
                    .unwrap();
                set(&store, "generation", "2");
                set(&store, "history", "100");
                sync::apply_inventory(
                    &store,
                    &json!({"messages":[{"id":"seen"},{"id":"download"}],"nextPageToken":"page-2"}),
                    "",
                    2,
                )
                .unwrap();
            }
            "history" => {
                assert_eq!(checkpoint(&store, "page"), "page-2");
                sync::apply_inventory(&store, &json!({"messages":[]}), "page-2", 2).unwrap();
                sync::apply_history(
                    &store,
                    &json!({"historyId":"200","nextPageToken":"history-2","history":[
                        {"messagesAdded":[{"message":{"id":"arrived"}}]}
                    ]}),
                    "",
                )
                .unwrap();
            }
            _ => panic!("unknown recovery phase"),
        }
        std::process::exit(73);
    }
    let mailbox = Mailbox::new();
    for phase in ["inventory", "history"] {
        let child = std::process::Command::new(std::env::current_exe().unwrap())
            .args(["--exact", "local_mail::recovery_tests::inventory_and_history_checkpoints_survive_process_exit", "--nocapture"])
            .env("MAGPIE_RECOVERY_CHILD", &mailbox.0)
            .env("MAGPIE_RECOVERY_PHASE", phase)
            .output().unwrap();
        assert_eq!(
            child.status.code(),
            Some(73),
            "{}\n{}",
            String::from_utf8_lossy(&child.stdout),
            String::from_utf8_lossy(&child.stderr)
        );
        let store = mailbox.open();
        assert_eq!(checkpoint(&store, "history"), "100");
        assert!(store.resource("unvisited").unwrap().is_some());
        assert_eq!(store.status().unwrap()["inventoryComplete"], false);
        assert_eq!(store.status().unwrap()["complete"], false);
        assert_eq!(store.status().unwrap()["pendingEdits"], 1);
        assert_eq!(
            checkpoint(&store, "page"),
            if phase == "inventory" { "page-2" } else { "" }
        );
        assert_eq!(
            checkpoint(&store, "historyPage"),
            if phase == "history" { "history-2" } else { "" }
        );
        assert_eq!(
            store.status().unwrap()["pending"],
            if phase == "inventory" { 1 } else { 2 }
        );
    }
    let store = mailbox.open();
    sync::apply_history(&store, &json!({"historyId":"200"}), "history-2").unwrap();
    assert_eq!(checkpoint(&store, "history"), "200");
    assert_eq!(store.status().unwrap()["inventoryComplete"], true);
    assert_eq!(
        store.status().unwrap()["complete"],
        false,
        "pending bodies prevent complete coverage"
    );
    assert!(store.resource("seen").unwrap().is_some());
    assert!(store.resource("unvisited").unwrap().is_none());
    assert_eq!(store.status().unwrap()["pendingEdits"], 0);
    assert_eq!(
        store.edits().unwrap(),
        json!([{"ticket":"pending","state":"conflict","error":"message_deleted","count":1}])
    );
    for id in ["download", "arrived"] {
        store.put(&message(id, "download completed"), 2).unwrap();
    }
    assert_eq!(store.status().unwrap()["complete"], true);
    drop(store);
    let reopened = mailbox.open();
    assert_eq!(reopened.status().unwrap()["complete"], true);
    assert_eq!(reopened.status().unwrap()["editConflicts"], 1);
    assert_eq!(
        reopened.label_counts("INBOX").unwrap(),
        json!({"total":3,"unread":3})
    );
}

#[test]
fn malformed_and_cyclic_inventory_pages_commit_nothing() {
    let mailbox = Mailbox::new();
    let store = mailbox.open();
    store.put(&message("cached", "sentinel"), 1).unwrap();
    let invalid =
        json!({"messages":[{"id":"cached"},{"id":"new-job"},{"id":""}],"nextPageToken":"next"});
    assert_eq!(
        sync::apply_inventory(&store, &invalid, "", 2),
        Err("gmail_invalid_response")
    );
    assert_eq!(checkpoint(&store, "page"), "");
    assert_eq!(store.status().unwrap()["pending"], 0);
    assert_eq!(
        store
            .read(|db| store::sql(db.query_row(
                "SELECT generation FROM messages WHERE id='cached'",
                [],
                |row| row.get::<_, i64>(0)
            )))
            .unwrap(),
        1
    );
    sync::apply_inventory(
        &store,
        &json!({"messages":[{"id":"cached"}],"nextPageToken":"next"}),
        "",
        2,
    )
    .unwrap();
    sync::apply_inventory(
        &store,
        &json!({"messages":[],"nextPageToken":"last"}),
        "next",
        2,
    )
    .unwrap();
    assert_eq!(
        sync::apply_inventory(
            &store,
            &json!({"messages":[{"id":"forbidden"}],"nextPageToken":"next"}),
            "last",
            2
        ),
        Err("gmail_invalid_response")
    );
    assert_eq!(checkpoint(&store, "page"), "last");
    assert_eq!(
        store.status().unwrap()["pending"],
        0,
        "refused page must not enqueue its messages"
    );
    assert_eq!(store.status().unwrap()["inventoryComplete"], false);
}

#[test]
fn expired_history_preserves_mail_and_intents_until_new_inventory_finishes() {
    let mailbox = Mailbox::new();
    {
        let store = mailbox.open();
        store
            .put(&message("retained", "offline needle"), 7)
            .unwrap();
        store
            .edit(
                "offline-star",
                &["retained".into()],
                &["STARRED".into()],
                &[],
            )
            .unwrap();
        for (key, value) in [
            ("generation", "7"),
            ("history", "expired"),
            ("historyPage", "old-history-page"),
            ("page", "old-inventory-page"),
            ("inventoryListed", "true"),
            ("inventoryComplete", "true"),
        ] {
            set(&store, key, value);
        }
        store
            .write(|db| {
                store::sql(db.execute("INSERT INTO history_pages VALUES('old-history-page')", []))?;
                store::sql(db.execute(
                    "INSERT INTO inventory_pages VALUES(7,'old-inventory-page')",
                    [],
                ))?;
                Ok(())
            })
            .unwrap();
        sync::restart_inventory(&store).unwrap();
    }
    let store = mailbox.open();
    assert_eq!(checkpoint(&store, "generation"), "8");
    for key in ["history", "historyPage", "page"] {
        assert_eq!(checkpoint(&store, key), "");
    }
    assert_eq!(store.status().unwrap()["complete"], false);
    assert_eq!(store.status().unwrap()["pendingEdits"], 1);
    assert_eq!(
        store.list("needle is:starred", 50, "").unwrap()["summaries"][0]["id"],
        "retained"
    );
    sync::apply_inventory(
        &store,
        &json!({"messages":[{"id":"retained"}],"nextPageToken":"old-inventory-page"}),
        "",
        8,
    )
    .unwrap();
    sync::apply_inventory(&store, &json!({"messages":[]}), "old-inventory-page", 8).unwrap();
    sync::apply_history(
        &store,
        &json!({"historyId":"new","nextPageToken":"old-history-page"}),
        "",
    )
    .unwrap();
    assert_eq!(store.status().unwrap()["inventoryComplete"], false);
    sync::apply_history(&store, &json!({"historyId":"new"}), "old-history-page").unwrap();
    assert_eq!(store.status().unwrap()["complete"], true);
    assert_eq!(store.status().unwrap()["pendingEdits"], 1);
    store.cancel_edit("offline-star").unwrap();
    assert_eq!(
        store.list("is:starred", 50, "").unwrap()["summaries"],
        json!([])
    );
    assert!(store.complete_resource("retained").unwrap().is_some());
}

#[test]
fn saved_bodies_counts_and_undo_remain_available_after_sync_auth_failure() {
    let mailbox = Mailbox::new();
    {
        let store = mailbox.open();
        store.put(&message("saved", "offline needle"), 1).unwrap();
        store
            .edit("read-offline", &["saved".into()], &[], &["UNREAD".into()])
            .unwrap();
        set(&store, "error", "gmail_auth_required");
    }
    let store = mailbox.open();
    assert_eq!(store.status().unwrap()["error"], "gmail_auth_required");
    assert!(store.complete_resource("saved").unwrap().is_some());
    assert_eq!(
        store.list("needle", 50, "").unwrap()["summaries"][0]["unread"],
        false
    );
    assert_eq!(
        store.label_counts("INBOX").unwrap(),
        json!({"total":1,"unread":0})
    );
    store.cancel_edit("read-offline").unwrap();
    assert_eq!(
        store.label_counts("INBOX").unwrap(),
        json!({"total":1,"unread":1})
    );
    assert_eq!(store.overview().unwrap()["unread"], 1);
}

#[tokio::test]
async fn pausing_downloads_clears_sync_warnings_without_losing_saved_mail() {
    for error in [
        "gmail_request_deferred",
        "gmail_server_rate_limited",
        "gmail_rate_limited",
    ] {
        let mailbox = Mailbox::new();
        let store = mailbox.open();
        store.put(&message("saved", "offline body"), 1).unwrap();
        set(&store, "paused", "true");
        set(&store, "error", error);
        let (events, mut updates) = tokio::sync::broadcast::channel(4);
        let worker = tokio::spawn(sync::watch(
            Arc::clone(&store),
            Arc::new(crate::providers::gmail::Session::default()),
            "sync@example.org".into(),
            events,
        ));
        let update = tokio::time::timeout(std::time::Duration::from_secs(2), updates.recv())
            .await
            .unwrap()
            .unwrap();
        worker.abort();
        let _ = worker.await;
        assert_eq!(update["params"]["status"]["error"], "");
        assert_eq!(store.status().unwrap()["error"], "");
        assert_eq!(store.status().unwrap()["paused"], true);
        assert!(store.complete_resource("saved").unwrap().is_some());
    }
}

#[test]
fn local_admission_deferrals_are_pending_downloads_without_counting_as_failures() {
    let mailbox = Mailbox::new();
    let store = mailbox.open();
    store.write(|db| {
        store::sql(db.execute("INSERT INTO jobs(id,error) VALUES('waiting','gmail_request_deferred'),('failed','gmail_http_failed')", []))?;
        Ok(())
    }).unwrap();
    let status = store.status().unwrap();
    assert_eq!(status["pending"], 2);
    assert_eq!(status["failed"], 1);
    assert_eq!(status["complete"], false);
}
