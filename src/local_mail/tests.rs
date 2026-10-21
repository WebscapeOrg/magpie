use super::*;
use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use std::{
    fs::File,
    sync::atomic::{AtomicU64, Ordering},
};
static SERIAL: AtomicU64 = AtomicU64::new(0);
pub(super) fn directory() -> std::path::PathBuf {
    let parent = std::env::temp_dir().canonicalize().unwrap();
    let name = format!(
        "magpie-local-{}-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos(),
        SERIAL.fetch_add(1, Ordering::Relaxed)
    );
    crate::platform::private_fs::directories(&parent, &[&name], true)
        .unwrap()
        .unwrap();
    parent.join(name)
}
pub(super) fn open_directory(path: &std::path::Path) -> File {
    let path = path.canonicalize().unwrap();
    crate::platform::private_fs::directories(
        path.parent().unwrap(),
        &[path.file_name().unwrap().to_str().unwrap()],
        false,
    )
    .unwrap()
    .unwrap()
}
pub(super) fn message(id: &str, text: &str) -> Value {
    json!({"id":id,"threadId":"thread","labelIds":["INBOX","UNREAD"],"internalDate":"1700000000000",
        "payload":{"mimeType":"text/plain","headers":[{"name":"From","value":"Alice <alice@example.org>"},{"name":"Subject","value":"Café 合成"}],
        "body":{"data":URL_SAFE_NO_PAD.encode(text),"size":text.len()}}})
}
#[test]
fn local_mail_search_and_edits_survive_restart() {
    let path = directory();
    {
        let store = Store::open(open_directory(&path)).unwrap();
        store
            .put(&message("one", "Offline café needles"), 1)
            .unwrap();
        store.put(&message("two", "Other body"), 1).unwrap();
        assert_eq!(
            store.list("\"café needles\"", 50, "").unwrap()["summaries"]
                .as_array()
                .unwrap()
                .len(),
            1
        );
        assert_eq!(
            store.list("from:alice café", 50, "").unwrap()["summaries"]
                .as_array()
                .unwrap()
                .len(),
            2
        );
        store
            .edit("ticket", &["one".into()], &[], &["UNREAD".into()])
            .unwrap();
        assert_eq!(
            store.list("is:unread", 50, "").unwrap()["summaries"]
                .as_array()
                .unwrap()
                .len(),
            1
        );
        assert_eq!(
            store.resource("one").unwrap().unwrap()["labelIds"],
            json!(["INBOX"])
        );
        assert_eq!(store.status().unwrap()["pendingEdits"], 1);
        assert!(
            Store::open(open_directory(&path)).is_err(),
            "another owner must not open the database"
        );
    }
    {
        let store = Store::open(open_directory(&path)).unwrap();
        assert_eq!(
            store.resource("one").unwrap().unwrap()["labelIds"],
            json!(["INBOX"])
        );
        store.cancel_edit("ticket").unwrap();
        assert_eq!(
            store.list("is:unread", 50, "").unwrap()["summaries"]
                .as_array()
                .unwrap()
                .len(),
            2
        );
        store.delete("two").unwrap();
        assert_eq!(
            store.list("", 50, "").unwrap()["summaries"]
                .as_array()
                .unwrap()
                .len(),
            1
        );
    }
    std::fs::remove_dir_all(path).unwrap();
}
#[test]
fn all_inline_text_parts_are_indexed_and_missing_text_is_explicit() {
    let text = |value: &str| json!({"mimeType":"text/plain","body":{"data":URL_SAFE_NO_PAD.encode(value)}});
    let resource = json!({"payload":{"mimeType":"multipart/mixed","parts":[text("first"),text("last"),{"mimeType":"text/html","body":{"attachmentId":"external","size":10}},{"mimeType":"text/plain","filename":"file.txt","body":{"data":URL_SAFE_NO_PAD.encode("private-file-text")}}]}});
    let result = content::extract(&resource);
    assert!(result.body.contains("first") && result.body.contains("last"));
    assert!(!result.body.contains("private-file-text"));
    assert!(!result.complete);
}
#[test]
fn attachment_disposition_uses_the_complete_trimmed_token() {
    let resource = json!({"payload":{"mimeType":"multipart/mixed","parts":[
        {"mimeType":"text/plain","headers":[{"name":"content-disposition","value":" \tAttachment ; filename=file.txt"}],"body":{"attachmentId":"external","size":10}},
        {"mimeType":"text/plain","headers":[{"name":"Content-Disposition","value":"attachment-extra"}],"body":{"data":URL_SAFE_NO_PAD.encode("inline body")}}
    ]}});
    let result = content::extract(&resource);
    assert!(result.complete);
    assert_eq!(result.body, "inline body\n");
}
#[cfg(unix)]
#[test]
fn database_and_sidecar_links_never_touch_their_targets() {
    use std::os::unix::fs::symlink;
    for name in ["mail.sqlite", "mail.sqlite-wal", "mail.sqlite-journal"] {
        let path = directory();
        let target = path.join("untouched");
        std::fs::write(&target, b"secret sentinel").unwrap();
        symlink(&target, path.join(name)).unwrap();
        let result = Store::open(open_directory(&path));
        assert!(result.is_err(), "{name}");
        assert_eq!(std::fs::read(&target).unwrap(), b"secret sentinel");
        std::fs::remove_dir_all(path).unwrap();
    }
}
#[test]
fn sqlite_cannot_attach_a_path_outside_its_directory() {
    let path = directory();
    let store = Store::open(open_directory(&path)).unwrap();
    let escaped = path.join("escaped");
    assert!(
        store
            .write(|db| {
                store::sql(
                    db.execute("ATTACH DATABASE ?1 AS escaped", [escaped.to_str().unwrap()]),
                )?;
                Ok(())
            })
            .is_err()
    );
    assert!(!escaped.exists());
    drop(store);
    std::fs::remove_dir_all(path).unwrap();
}

#[test]
fn coalescing_preserves_latest_intent_and_undo_stops_before_claim() {
    let path = directory();
    let store = Store::open(open_directory(&path)).unwrap();
    store.put(&message("one", "body"), 1).unwrap();
    store
        .edit("star", &["one".into()], &["STARRED".into()], &[])
        .unwrap();
    store
        .edit("unstar", &["one".into()], &[], &["STARRED".into()])
        .unwrap();
    store
        .edit("read", &["one".into()], &[], &["UNREAD".into()])
        .unwrap();
    store.cancel_edit("read").unwrap();
    let changes = store.claim_changes("one").unwrap().unwrap();
    assert!(changes.additions.is_empty());
    assert_eq!(changes.removals, ["STARRED"]);
    assert_eq!(store.cancel_edit("star"), Err("local_edit_already_started"));
    assert_eq!(
        store.resource("one").unwrap().unwrap()["labelIds"],
        json!(["INBOX", "UNREAD"])
    );
    assert_eq!(
        store.edit("star", &["one".into()], &[], &["STARRED".into()]),
        Err("local_edit_id_conflict")
    );
    drop(store);
    std::fs::remove_dir_all(path).unwrap();
}

#[test]
fn missing_text_is_retryable_and_paging_never_repeats_the_previous_page() {
    let path = directory();
    let store = Store::open(open_directory(&path)).unwrap();
    for id in ["one", "two", "three"] {
        store.put(&message(id, "body"), 1).unwrap();
    }
    let first = store.list("", 2, "").unwrap();
    let second = store
        .list("", 2, first["nextPageToken"].as_str().unwrap())
        .unwrap();
    assert_eq!(second["summaries"].as_array().unwrap().len(), 1);
    assert!(
        !first["summaries"]
            .as_array()
            .unwrap()
            .iter()
            .any(|v| v["id"] == second["summaries"][0]["id"])
    );
    assert!(
        store
            .list("other", 2, first["nextPageToken"].as_str().unwrap())
            .is_err()
    );
    let mut missing = message("missing", "body");
    missing["payload"]["body"] = json!({"size":20,"attachmentId":"text-part"});
    store.put(&missing, 1).unwrap();
    assert!(store.resource("missing").unwrap().is_some());
    assert!(store.complete_resource("missing").unwrap().is_none());
    assert!(store.complete_resource("one").unwrap().is_some());
    let status = store.status().unwrap();
    assert_eq!(status["stored"], 4);
    assert_eq!(status["textComplete"], 3);
    assert_eq!(status["failed"], 1);
    assert_eq!(status["complete"], false);
    store
        .edit(
            "unfetched",
            &["online-search-result".into()],
            &["STARRED".into()],
            &[],
        )
        .unwrap();
    assert_eq!(store.status().unwrap()["pendingEdits"], 1);
    store.cancel_edit("unfetched").unwrap();
    assert_eq!(store.status().unwrap()["pendingEdits"], 0);
    drop(store);
    std::fs::remove_dir_all(path).unwrap();
}

#[test]
fn malformed_history_rolls_back_jobs_deletions_and_checkpoint() {
    let path = directory();
    let store = Store::open(open_directory(&path)).unwrap();
    store.put(&message("kept", "sentinel"), 1).unwrap();
    store
        .write(|db| store::set_state(db, "history", "100"))
        .unwrap();
    let invalid = json!({"historyId":"200","history":[{"messagesDeleted":[{"message":{"id":"kept"}}]},{"messagesAdded":"invalid"}]});
    assert!(sync::apply_history(&store, &invalid, "").is_err());
    assert!(store.resource("kept").unwrap().is_some());
    assert_eq!(store.read(|db| store::state(db, "history")).unwrap(), "100");
    let page = json!({"historyId":"200","nextPageToken":"next","history":[{"messagesAdded":[{"message":{"id":"new"}}]}]});
    sync::apply_history(&store, &page, "").unwrap();
    assert_eq!(store.status().unwrap()["pending"], 1);
    assert!(sync::apply_history(&store, &page, "other").is_err());
    assert_eq!(store.read(|db| store::state(db, "history")).unwrap(), "100");
    sync::apply_history(&store, &json!({"historyId":"200"}), "next").unwrap();
    assert_eq!(store.read(|db| store::state(db, "history")).unwrap(), "200");
    drop(store);
    std::fs::remove_dir_all(path).unwrap();
}

#[test]
fn large_summary_pages_keep_a_continuation_and_reject_an_oversized_single_row() {
    let path = directory();
    let store = Store::open(open_directory(&path)).unwrap();
    for id in ["a", "b"] {
        store.put(&message(id, "body"), 1).unwrap();
        let summary = json!({"id":id,"subject":"x".repeat(9*1024*1024)}).to_string();
        store
            .write(|db| {
                store::sql(db.execute(
                    "UPDATE messages SET summary=?2 WHERE id=?1",
                    rusqlite::params![id, summary],
                ))?;
                Ok(())
            })
            .unwrap();
    }
    let first = store.list("in:inbox", 50, "").unwrap();
    assert_eq!(first["summaries"].as_array().unwrap().len(), 1);
    let second = store
        .list("in:inbox", 50, first["nextPageToken"].as_str().unwrap())
        .unwrap();
    assert_eq!(second["summaries"].as_array().unwrap().len(), 1);
    assert_ne!(first["summaries"][0]["id"], second["summaries"][0]["id"]);
    assert_eq!(second["nextPageToken"], "");
    store
        .write(|db| {
            store::sql(db.execute(
                "UPDATE messages SET summary=?1 WHERE id='b'",
                [json!({"id":"b","subject":"x".repeat(17*1024*1024)}).to_string()],
            ))?;
            Ok(())
        })
        .unwrap();
    assert_eq!(
        store.list("in:inbox", 50, ""),
        Err("local_content_too_large")
    );
    drop(store);
    std::fs::remove_dir_all(path).unwrap();
}

#[test]
fn committed_mail_and_queued_edits_survive_process_exit_without_checkpoint() {
    if let Some(path) = std::env::var_os("MAGPIE_WAL_CHILD") {
        let store = Store::open(open_directory(&std::path::PathBuf::from(path))).unwrap();
        store
            .put(&message("durable", "committed needle"), 1)
            .unwrap();
        store
            .edit(
                "durable-edit",
                &["durable".into()],
                &["STARRED".into()],
                &[],
            )
            .unwrap();
        std::process::exit(73);
    }
    let path = directory();
    let child=std::process::Command::new(std::env::current_exe().unwrap())
        .args(["--exact","local_mail::tests::committed_mail_and_queued_edits_survive_process_exit_without_checkpoint","--nocapture"])
        .env("MAGPIE_WAL_CHILD",&path).output().unwrap();
    assert_eq!(
        child.status.code(),
        Some(73),
        "{}\n{}",
        String::from_utf8_lossy(&child.stdout),
        String::from_utf8_lossy(&child.stderr)
    );
    let store = Store::open(open_directory(&path)).unwrap();
    assert_eq!(
        store.list("needle is:starred", 50, "").unwrap()["summaries"][0]["id"],
        "durable"
    );
    assert_eq!(store.status().unwrap()["pendingEdits"], 1);
    drop(store);
    std::fs::remove_dir_all(path).unwrap();
}

#[test]
#[ignore = "synthetic 100k/1m latency benchmark; run explicitly"]
fn benchmark_local_queries() {
    use std::time::Instant;
    let count = std::env::var("MAGPIE_BENCH_MESSAGES")
        .ok()
        .and_then(|v| v.parse::<usize>().ok())
        .unwrap_or(100_000);
    assert!((1..=1_000_000).contains(&count));
    let path = directory();
    let store = Store::open(open_directory(&path)).unwrap();
    let started = Instant::now();
    store.write(|db| {
        let mut messages=store::sql(db.prepare("INSERT INTO messages(id,thread_id,date,summary,blob,server_labels,sender,recipients,copied,subject,filenames,has_attachment,text_complete,generation) VALUES(?1,?1,?2,?3,'synthetic','[\"INBOX\"]','alice@example.org','bob@example.org','','Invoice','','0',1,1)"))?;
        let mut labels=store::sql(db.prepare("INSERT INTO labels VALUES(?1,'INBOX')"))?;
        let mut search=store::sql(db.prepare("INSERT INTO search(rowid,id,subject,sender,recipients,copied,filenames,body) VALUES(?1,?2,'Invoice','alice@example.org','bob@example.org','','',?3)"))?;
        for n in 0..count {
            let id=format!("synthetic-{n:08}");
            let summary=json!({"id":id,"subject":"Invoice","from":{"email":"alice@example.org"},"unread":false,"labelIds":["INBOX"]}).to_string();
            store::sql(messages.execute(rusqlite::params![id,1_700_000_000_000i64+n as i64,summary]))?;
            store::sql(labels.execute([&id]))?;
            store::sql(search.execute(rusqlite::params![(n+1) as i64,id,if n%100==0 {"café needle invoice"} else {"ordinary invoice"}]))?;
        }
        store::set_state(db,"inventoryComplete","true")
    }).unwrap();
    let import_ms = started.elapsed().as_millis();
    let background = std::env::var("MAGPIE_BENCH_BACKGROUND").as_deref() == Ok("1");
    let stop = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
    let worker = background.then(|| {
        let store = store.clone();
        let stop = stop.clone();
        std::thread::spawn(move || {
            let mut writes = 0;
            while !stop.load(Ordering::Relaxed) {
                store
                    .put(&message("background", "Synthetic incoming mail"), 1)
                    .unwrap();
                writes += 1;
                std::thread::sleep(std::time::Duration::from_millis(25));
            }
            writes
        })
    });
    let mut cases = Vec::new();
    for query in [
        "in:inbox",
        "needle",
        "\"café needle\"",
        "from:alice subject:invoice",
        "invoice OR needle -is:unread",
    ] {
        let mut times = Vec::new();
        for _ in 0..31 {
            let at = Instant::now();
            let result = store.list(query, 50, "").unwrap();
            assert!(!result["summaries"].as_array().unwrap().is_empty());
            times.push(at.elapsed().as_micros());
        }
        times.sort();
        eprintln!(
            "LOCAL_CASE {}",
            json!({"query":query,"medianUs":times[15],"p95Us":times[29]})
        );
        cases.push(json!({"query":query,"medianUs":times[15],"p95Us":times[29]}));
    }
    stop.store(true, Ordering::Relaxed);
    let writes = worker.map_or(0, |worker| worker.join().unwrap());
    println!(
        "LOCAL_BENCH {}",
        json!({"messages":count,"fixtureImportMs":import_ms,"cases":cases,"sqlite":rusqlite::version(),"backgroundWrites":writes})
    );
    drop(store);
    std::fs::remove_dir_all(path).unwrap();
}
