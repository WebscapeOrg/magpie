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
    assert_eq!(result.completeness, content::Completeness::Missing);
}
#[test]
fn attachment_disposition_uses_the_complete_trimmed_token() {
    let resource = json!({"payload":{"mimeType":"multipart/mixed","parts":[
        {"mimeType":"text/plain","headers":[{"name":"content-disposition","value":" \tAttachment ; filename=file.txt"}],"body":{"attachmentId":"external","size":10}},
        {"mimeType":"text/plain","headers":[{"name":"Content-Disposition","value":"attachment-extra"}],"body":{"data":URL_SAFE_NO_PAD.encode("inline body")}}
    ]}});
    let result = content::extract(&resource);
    assert!(result.complete());
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

fn set_edit_state(store: &Store, ticket: &str, state: &str) {
    store
        .write(|db| {
            db.execute("UPDATE edits SET state=?2 WHERE ticket=?1", [ticket, state])
                .map(|_| ())
                .map_err(|_| "local_storage_corrupt")
        })
        .unwrap();
}

fn edit_tickets(store: &Store) -> Vec<String> {
    store.edits().unwrap().as_array().unwrap().iter().map(|edit| edit["ticket"].as_str().unwrap().to_owned()).collect()
}

#[test]
fn undo_drops_a_queued_change_and_shows_the_mail_where_it_was() {
    let path = directory();
    let store = Store::open(open_directory(&path)).unwrap();
    store.put(&message("one", "body"), 1).unwrap();
    store.edit("archive", &["one".into()], &[], &["INBOX".into()]).unwrap();
    store.undo_edit("archive").unwrap();
    assert_eq!(store.resource("one").unwrap().unwrap()["labelIds"], json!(["INBOX", "UNREAD"]));
    assert!(store.claim_changes("one").unwrap().is_none(), "nothing is left to send");
    assert!(edit_tickets(&store).is_empty());
    drop(store);
    std::fs::remove_dir_all(path).unwrap();
}

#[test]
fn undo_reverses_only_what_a_delivered_change_altered() {
    let path = directory();
    let store = Store::open(open_directory(&path)).unwrap();
    store.put(&message("one", "body"), 1).unwrap();
    store
        .edit(
            "trash",
            &["one".into()],
            &["TRASH".into(), "UNREAD".into()],
            &["INBOX".into(), "STARRED".into()],
        )
        .unwrap();
    set_edit_state(&store, "trash", "done");
    store.undo_edit("trash").unwrap();
    let changes = store.claim_changes("one").unwrap().unwrap();
    assert_eq!(changes.additions, ["INBOX"], "STARRED was never on this mail");
    assert_eq!(changes.removals, ["TRASH"], "UNREAD was on this mail before");
    drop(store);
    std::fs::remove_dir_all(path).unwrap();
}

#[test]
fn undo_adds_nothing_back_to_a_mail_that_had_no_labels() {
    let path = directory();
    let store = Store::open(open_directory(&path)).unwrap();
    let mut bare = message("one", "body");
    bare["labelIds"] = json!([]);
    store.put(&bare, 1).unwrap();
    store.edit("archive", &["one".into()], &[], &["INBOX".into()]).unwrap();
    set_edit_state(&store, "archive", "done");
    store.undo_edit("archive").unwrap();
    assert!(store.claim_changes("one").unwrap().is_none(), "it was never in the Inbox");
    drop(store);
    std::fs::remove_dir_all(path).unwrap();
}

#[test]
fn undo_of_a_mail_the_copy_does_not_have_is_the_plain_opposite() {
    let path = directory();
    let store = Store::open(open_directory(&path)).unwrap();
    store.edit("archive", &["absent".into()], &[], &["INBOX".into()]).unwrap();
    set_edit_state(&store, "archive", "done");
    store.undo_edit("archive").unwrap();
    assert_eq!(store.claim_changes("absent").unwrap().unwrap().additions, ["INBOX"]);
    drop(store);
    std::fs::remove_dir_all(path).unwrap();
}

#[test]
fn undo_leaves_a_mail_changed_since_alone() {
    let path = directory();
    let store = Store::open(open_directory(&path)).unwrap();
    store.put(&message("one", "body"), 1).unwrap();
    store.edit("archive", &["one".into()], &[], &["INBOX".into()]).unwrap();
    set_edit_state(&store, "archive", "done");
    store.edit("back", &["one".into()], &["INBOX".into()], &[]).unwrap();
    set_edit_state(&store, "back", "done");
    assert_eq!(store.undo_edit("archive").unwrap(), 1, "Undo says it left that mail alone");
    assert!(store.edits().unwrap().as_array().unwrap().iter().all(|edit| edit["ticket"] != "archive:undo"), "the newer change stands");
    drop(store);
    std::fs::remove_dir_all(path).unwrap();
}

#[test]
fn undo_of_a_refusal_that_was_dismissed_does_nothing() {
    let path = directory();
    let store = Store::open(open_directory(&path)).unwrap();
    store.put(&message("one", "body"), 1).unwrap();
    store.edit("archive", &["one".into()], &[], &["INBOX".into()]).unwrap();
    set_edit_state(&store, "archive", "dismissed");
    store.undo_edit("archive").unwrap();
    assert!(store.claim_changes("one").unwrap().is_none());
    drop(store);
    std::fs::remove_dir_all(path).unwrap();
}

#[test]
fn undo_reverses_a_change_being_sent_and_is_safe_to_press_twice() {
    let path = directory();
    let store = Store::open(open_directory(&path)).unwrap();
    store.put(&message("one", "body"), 1).unwrap();
    store.edit("archive", &["one".into()], &[], &["INBOX".into()]).unwrap();
    assert!(store.claim_changes("one").unwrap().is_some());
    store.undo_edit("archive").unwrap();
    store.undo_edit("archive").unwrap();
    let reversal = store.edits().unwrap().as_array().unwrap().iter().find(|edit| edit["ticket"] == "archive:undo").cloned().unwrap();
    assert_eq!(reversal["count"], 1, "pressing Undo twice queues one reversal");
    assert_eq!(store.claim_changes("one").unwrap().unwrap().additions, ["INBOX"]);
    drop(store);
    std::fs::remove_dir_all(path).unwrap();
}

#[test]
fn undo_leaves_a_change_gmail_refused_alone() {
    let path = directory();
    let store = Store::open(open_directory(&path)).unwrap();
    store.put(&message("one", "body"), 1).unwrap();
    store.edit("archive", &["one".into()], &[], &["INBOX".into()]).unwrap();
    set_edit_state(&store, "archive", "conflict");
    store.undo_edit("archive").unwrap();
    assert!(!edit_tickets(&store).iter().any(|ticket| ticket == "archive:undo"));
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

#[test]
fn attached_multipart_subtrees_do_not_supply_body_text_or_missing_body_jobs() {
    let resource = json!({"payload":{"mimeType":"multipart/mixed","parts":[
        {"mimeType":"text/plain","body":{"data":URL_SAFE_NO_PAD.encode("visible body")}},
        {"mimeType":"multipart/mixed","filename":"attached.eml","parts":[
            {"mimeType":"text/plain","body":{"data":URL_SAFE_NO_PAD.encode("attachment-only text")}},
            {"mimeType":"text/html","body":{"attachmentId":"external-attachment-body","size":10}}
        ]}
    ]}});
    let extracted = content::extract(&resource);
    assert_eq!(extracted.body, "visible body\n");
    assert_eq!(extracted.filenames, "attached.eml\n");
    assert!(extracted.complete());
}

#[test]
fn cached_hydration_keeps_server_labels_pending_edits_and_metadata_repair() {
    let path = directory();
    let store = Store::open(open_directory(&path)).unwrap();
    store.put(&message("one", "partial"), 1).unwrap();
    store
        .edit("star", &["one".into()], &["STARRED".into()], &[])
        .unwrap();
    let effective = store.resource("one").unwrap().unwrap();
    store.put_cached(&effective, 1).unwrap();
    store.cancel_edit("star").unwrap();
    assert_eq!(
        store.resource("one").unwrap().unwrap()["labelIds"],
        json!(["INBOX", "UNREAD"])
    );
    assert_eq!(store.status().unwrap()["pending"], 1);
    store.metadata(&json!({"id":"one"})).unwrap();
    assert_eq!(store.label_counts("INBOX").unwrap()["total"], 0);
    assert_eq!(store.status().unwrap()["pending"], 0);
    assert!(store.complete_resource("one").unwrap().is_some());
    for invalid in [json!(null), json!("INBOX"), json!([1])] {
        assert!(
            store
                .metadata(&json!({"id":"one","labelIds":invalid}))
                .is_err()
        );
        assert_eq!(
            store.resource("one").unwrap().unwrap()["labelIds"],
            json!([])
        );
    }
    drop(store);
    std::fs::remove_dir_all(path).unwrap();
}

#[test]
fn deletion_history_notifies_and_prevents_late_body_resurrection() {
    let path = directory();
    let store = Store::open(open_directory(&path)).unwrap();
    let resource = message("one", "delayed saved body");
    store.put(&resource, 1).unwrap();
    let changed = sync::apply_history(
        &store,
        &json!({"historyId":"200","history":[{"messagesDeleted":[{"message":{"id":"one"}}]}]}),
        "",
    )
    .unwrap();
    assert!(changed);
    assert_eq!(store.put_cached(&resource, 1), Err("gmail_not_found"));
    assert_eq!(store.put(&resource, 1), Err("gmail_not_found"));
    assert!(store.resource("one").unwrap().is_none());
    drop(store);
    std::fs::remove_dir_all(path).unwrap();
}
#[test]
fn alert_snapshot_lists_inbox_ids_and_names_only_unread_senders() {
    let path = directory();
    {
        let store = Store::open(open_directory(&path)).unwrap();
        let mut fresh = message("fresh", "New body");
        fresh["internalDate"] = json!("1700000300000");
        let mut read = message("read", "Seen body");
        read["labelIds"] = json!(["INBOX"]);
        read["internalDate"] = json!("1700000200000");
        let mut archived = message("archived", "Archived body");
        archived["labelIds"] = json!(["UNREAD"]);
        archived["internalDate"] = json!("1700000250000");
        let mut old = message("old", "Old body");
        old["internalDate"] = json!("1600000000000");
        for resource in [&fresh, &read, &archived, &old] {
            store.put(resource, 1).unwrap();
        }
        let snapshot = store.alert_snapshot().unwrap();
        assert_eq!(snapshot["ready"], false, "an Inbox that was never listed is not ready");
        assert_eq!(snapshot["paused"], false);
        assert_eq!(snapshot["inbox"], json!(["fresh", "read", "old"]), "Inbox only, newest first, however old");
        let unread = snapshot["unread"].as_array().unwrap();
        let ids: Vec<_> = unread.iter().map(|m| m["id"].as_str().unwrap()).collect();
        assert_eq!(ids, ["fresh", "old"], "unread Inbox mail only");
        assert_eq!(unread[0]["date"], 1_700_000_300_000_i64);
        assert_eq!(unread[0]["from"]["email"], "alice@example.org");
        assert_eq!(unread[0]["subject"], "Café 合成");
        assert!(unread.iter().all(|m| m.get("snippet").is_none() && m.get("body").is_none()));
        assert_eq!(unread[1]["from"]["email"], "alice@example.org", "the newest 2,000 carry sender details");
        store
            .edit("ticket", &["fresh".into()], &[], &["UNREAD".into()])
            .unwrap();
        store
            .write(|db| store::set_state(db, "inboxReady", "true"))
            .unwrap();
        let snapshot = store.alert_snapshot().unwrap();
        assert_eq!(snapshot["ready"], true);
        assert_eq!(snapshot["unread"].as_array().unwrap().len(), 1, "a local read edit counts immediately");
        assert_eq!(snapshot["unread"][0]["id"], "old");
        store
            .write(|db| store::set_state(db, "paused", "true"))
            .unwrap();
        assert_eq!(store.alert_snapshot().unwrap()["paused"], true);
    }
    std::fs::remove_dir_all(path).unwrap();
}

pub(super) fn part(content_type: &str, bytes: &[u8]) -> Value {
    json!({"mimeType":"text/plain","headers":[{"name":"Content-Type","value":content_type}],
        "body":{"data":URL_SAFE_NO_PAD.encode(bytes),"size":bytes.len()}})
}

pub(super) fn with_payload(id: &str, payload: Value) -> Value {
    let mut resource = message(id, "");
    resource["payload"] = payload;
    resource
}

#[test]
fn text_that_does_not_fit_its_character_set_is_complete_and_unreadable_text_is_not_fetchable() {
    // Old mail in Japanese often declares ISO-2022-JP but carries a few bytes outside it.
    let mixed = part("text/plain; charset=ISO-2022-JP", b"\x1b$B$3$s\x1b(B hello \xff\xfe there");
    let text = content::extract(&json!({"payload": mixed}));
    assert_eq!(text.completeness, content::Completeness::Complete);
    assert!(text.body.contains("hello") && text.body.contains("there") && text.body.contains('\u{fffd}'));

    let damaged = json!({"mimeType":"text/plain","body":{"data":"*not base64*","size":12}});
    assert_eq!(content::extract(&json!({"payload": damaged})).completeness, content::Completeness::Unreadable);
    let empty = json!({"mimeType":"text/html","body":{"size":12}});
    assert_eq!(content::extract(&json!({"payload": empty})).completeness, content::Completeness::Unreadable);
    // A part Gmail serves separately is fetched first, so it outranks a damaged one.
    let separate = json!({"mimeType":"text/html","body":{"attachmentId":"later","size":12}});
    for parts in [json!([damaged, separate]), json!([separate, damaged])] {
        let resource = json!({"payload":{"mimeType":"multipart/alternative","parts":parts}});
        assert_eq!(content::extract(&resource).completeness, content::Completeness::Missing);
    }
}

#[test]
fn unreadable_text_is_given_up_on_and_reported_while_missing_text_backs_off() {
    let path = directory();
    let store = Store::open(open_directory(&path)).unwrap();
    store.write(|db| store::set_state(db, "inventoryComplete", "true")).unwrap();
    store.put(&message("fine", "body"), 1).unwrap();
    let damaged = with_payload("damaged", json!({"mimeType":"text/plain","body":{"data":"*","size":3}}));
    store.put(&damaged, 1).unwrap();

    let status = store.status().unwrap();
    assert_eq!((status["stored"].as_i64(), status["textComplete"].as_i64(), status["pending"].as_i64()), (Some(2), Some(1), Some(0)));
    assert_eq!(status["unsaved"], 1);
    assert_eq!(status["unsavedReasons"], json!({"local_text_unreadable": 1}));
    assert_eq!(status["failed"], 0);
    assert_eq!(status["complete"], true, "a message that can never be saved is settled");
    assert_eq!(status["health"]["missing"], 0);
    assert!(store.resource("damaged").unwrap().is_some());

    // Re-listing the Inbox checks its labels only; it never fetches its content again.
    store.write(|db| {
        store::sql(db.execute(&format!("INSERT INTO jobs(id,kind) VALUES(?1,{})", store::FETCH_KIND), ["damaged"]))?;
        Ok(())
    }).unwrap();
    let kind: String = store.read(|db| store::sql(db.query_row("SELECT kind FROM jobs WHERE id='damaged'", [], |r| r.get(0)))).unwrap();
    assert_eq!(kind, "metadata");
    store.metadata(&json!({"id":"damaged","labelIds":["INBOX"]})).unwrap();
    assert_eq!(store.status().unwrap()["pending"], 0);

    // A text part Gmail serves separately is fetched again, later after each failure.
    let mut separate = message("separate", "");
    separate["payload"]["body"] = json!({"attachmentId":"later","size":40});
    let before = chrono::Utc::now().timestamp_millis();
    store.put(&separate, 1).unwrap();
    store.put(&separate, 1).unwrap();
    let (error, attempts, retry_at): (String, i64, i64) = store.read(|db| store::sql(db.query_row(
        "SELECT error,attempts,retry_at FROM jobs WHERE id='separate'", [], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?))))).unwrap();
    assert_eq!((error.as_str(), attempts), ("local_text_incomplete", 2));
    assert!(retry_at >= before + 5 * 60_000 && retry_at < before + 6 * 60_000);
    let status = store.status().unwrap();
    assert_eq!((status["failed"].as_i64(), status["unsaved"].as_i64(), status["complete"].as_bool()), (Some(1), Some(1), Some(false)));

    // Deleting a message forgets that it could not be saved in full.
    store.delete("damaged").unwrap();
    assert_eq!(store.status().unwrap()["unsaved"], 0);
    drop(store);
    std::fs::remove_dir_all(path).unwrap();
}

#[test]
fn failed_fetches_wait_longer_each_time_and_too_large_mail_is_given_up_on() {
    let path = directory();
    let store = Store::open(open_directory(&path)).unwrap();
    store.write(|db| {
        store::sql(db.execute("INSERT INTO jobs(id,kind) VALUES('slow','content'),('huge','content'),('labels','metadata')", []))?;
        for (attempt, wait) in [(1, 60_000), (2, 5 * 60_000), (3, 30 * 60_000), (4, 2 * 3_600_000), (5, 12 * 3_600_000), (6, 24 * 3_600_000), (7, 24 * 3_600_000)] {
            store::retry_later(db, "slow", "gmail_http_failed", 1_000)?;
            let (attempts, retry_at): (i64, i64) = store::sql(db.query_row("SELECT attempts,retry_at FROM jobs WHERE id='slow'", [], |r| Ok((r.get(0)?, r.get(1)?))))?;
            assert_eq!((attempts, retry_at), (attempt, 1_000 + wait));
        }
        store::give_up(db, "huge", "gmail_response_too_large")?;
        store::give_up(db, "labels", "local_content_too_large")?;
        Ok(())
    }).unwrap();
    let jobs: Vec<(String, String)> = store.read(|db| {
        let mut query = store::sql(db.prepare("SELECT id,kind FROM jobs ORDER BY id"))?;
        let rows = store::sql(query.query_map([], |r| Ok((r.get(0)?, r.get(1)?))))?;
        store::sql(rows.collect::<rusqlite::Result<Vec<_>>>())
    }).unwrap();
    let jobs: Vec<(&str, &str)> = jobs.iter().map(|(id, kind)| (id.as_str(), kind.as_str())).collect();
    assert_eq!(jobs, [("huge", "metadata"), ("labels", "metadata"), ("slow", "content")],
        "a content fetch given up on becomes a label check");
    let status = store.status().unwrap();
    assert_eq!(status["unsavedReasons"], json!({"gmail_response_too_large": 1, "local_content_too_large": 1}));
    assert_eq!(status["health"]["missing"], 1, "only the message still being fetched is missing");
    drop(store);
    std::fs::remove_dir_all(path).unwrap();
}

fn damaged_copy() -> Value {
    with_payload("damaged", json!({"mimeType":"text/plain","body":{"data":"*","size":3}}))
}

#[test]
fn stores_saved_under_the_old_rules_are_repaired_once_from_their_saved_copies() {
    let path = directory();
    {
        let store = Store::open(open_directory(&path)).unwrap();
        let mixed = with_payload("mixed", part("text/plain; charset=ISO-2022-JP", b"\x1b$B$3$s\x1b(B hello \xff"));
        let damaged = damaged_copy();
        let mut separate = message("separate", "");
        separate["payload"]["body"] = json!({"attachmentId":"later","size":40});
        for resource in [&mixed, &damaged, &separate] {
            store.put(resource, 1).unwrap();
        }
        // What an older Magpie left behind: incomplete text, a five-minute content retry for each,
        // no record of mail that cannot be saved, and no failure counts on jobs.
        store.write(|db| {
            store::sql(db.execute_batch("UPDATE messages SET text_complete=0;
                DELETE FROM unsaved; DELETE FROM jobs; DELETE FROM state WHERE key='textRepair';
                INSERT INTO jobs(id,kind,error,retry_at) SELECT id,'content','local_text_incomplete',1 FROM messages;
                ALTER TABLE jobs DROP COLUMN attempts;"))
        }).unwrap();
    }
    let store = Store::open(open_directory(&path)).unwrap();
    store.repair_text().unwrap();
    let complete: Vec<String> = store.read(|db| {
        let mut query = store::sql(db.prepare("SELECT id FROM messages WHERE text_complete=1 ORDER BY id"))?;
        let rows = store::sql(query.query_map([], |r| r.get(0)))?;
        store::sql(rows.collect::<rusqlite::Result<Vec<String>>>())
    }).unwrap();
    assert_eq!(complete, ["mixed"]);
    let jobs = |store: &Store| -> Vec<(String, String, i64, i64)> { store.read(|db| {
        let mut query = store::sql(db.prepare("SELECT id,kind,attempts,retry_at FROM jobs ORDER BY id"))?;
        let rows = store::sql(query.query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?))))?;
        store::sql(rows.collect::<rusqlite::Result<Vec<_>>>())
    }).unwrap() };
    // The repaired message keeps a label check at once, since a label change may have been waiting
    // on its fetch. A saved copy cannot show that Gmail's copy is damaged, so that one is fetched.
    assert_eq!(jobs(&store), [
        ("damaged".to_string(), "content".to_string(), 0, 1),
        ("mixed".to_string(), "metadata".to_string(), 0, 0),
        ("separate".to_string(), "content".to_string(), 0, 1),
    ]);
    assert_eq!(store.status().unwrap()["unsaved"], 0);
    assert!(store.complete_resource("mixed").unwrap().is_some());
    assert_eq!(store.list("hello", 50, "").unwrap()["summaries"].as_array().unwrap().len(), 1);
    store.put(&damaged_copy(), 1).unwrap();
    assert_eq!(store.status().unwrap()["unsavedReasons"], json!({"local_text_unreadable": 1}), "Gmail's own copy decides");
    // The repair runs once: a message marked incomplete later is left to the job queue.
    store.write(|db| store::sql(db.execute("UPDATE messages SET text_complete=0 WHERE id='mixed'", []))).unwrap();
    drop(store);
    let store = Store::open(open_directory(&path)).unwrap();
    store.repair_text().unwrap();
    assert!(store.complete_resource("mixed").unwrap().is_none());
    drop(store);
    std::fs::remove_dir_all(path).unwrap();
}

fn job_kind(store: &Store, id: &str) -> Option<String> {
    use rusqlite::OptionalExtension;
    store.read(|db| store::sql(db.query_row("SELECT kind FROM jobs WHERE id=?1", [id], |r| r.get(0)).optional())).unwrap()
}

#[test]
fn an_unreadable_local_copy_leaves_the_decision_to_gmails_copy() {
    let path = directory();
    let store = Store::open(open_directory(&path)).unwrap();
    // A text part with a size but no bytes, as a field-masked or cached copy can carry.
    let mut copy = message("masked", "");
    copy["payload"]["body"] = json!({"size": 12});
    store.put_cached(&copy, 1).unwrap();
    assert_eq!(job_kind(&store, "masked").as_deref(), Some("content"));
    assert_eq!(store.status().unwrap()["unsaved"], 0);
    // Gmail's own copy with the same damage is given up on, and a cached copy afterwards keeps that.
    store.put(&copy, 1).unwrap();
    assert_eq!(store.status().unwrap()["unsavedReasons"], json!({"local_text_unreadable": 1}));
    assert_eq!(job_kind(&store, "masked"), None);
    store.put_cached(&copy, 1).unwrap();
    assert_eq!(job_kind(&store, "masked").as_deref(), Some("metadata"));
    assert_eq!(store.status().unwrap()["unsaved"], 1);
    drop(store);
    std::fs::remove_dir_all(path).unwrap();
}

#[test]
fn unsaved_mail_gmail_no_longer_lists_is_forgotten_after_inventory() {
    let path = directory();
    let store = Store::open(open_directory(&path)).unwrap();
    store.put(&message("old", "body"), 1).unwrap();
    store.write(|db| {
        store::set_state(db, "generation", "1")?;
        store::give_up(db, "listed", "gmail_response_too_large")?;
        store::give_up(db, "gone", "gmail_response_too_large")?;
        store::set_state(db, "generation", "2")?;
        store::sql(db.execute("UPDATE unsaved SET generation=2 WHERE id='listed'", []))?;
        store::set_state(db, "inventoryListed", "true")?;
        store::set_state(db, "inventoryComplete", "false")?;
        Ok(())
    }).unwrap();
    sync::apply_history(&store, &json!({"historyId":"9"}), "").unwrap();
    let status = store.status().unwrap();
    assert_eq!((status["inventoryComplete"].as_bool(), status["stored"].as_i64()), (Some(true), Some(0)));
    assert_eq!(status["unsavedReasons"], json!({"gmail_response_too_large": 1}), "only the message Gmail still lists remains");
    drop(store);
    std::fs::remove_dir_all(path).unwrap();
}

#[test]
fn a_pending_label_change_survives_the_repair_and_unsaved_mail_is_never_fetched_in_full() {
    let path = directory();
    {
        let store = Store::open(open_directory(&path)).unwrap();
        let mut mixed = with_payload("mixed", part("text/plain; charset=ISO-2022-JP", b"\x1b$B$3$s\x1b(B hello \xff"));
        mixed["labelIds"] = json!(["UNREAD"]);
        store.put(&mixed, 1).unwrap();
        // An older Magpie merged a label change into the content fetch and closed before it ran.
        store.write(|db| store::sql(db.execute_batch(
            "UPDATE messages SET text_complete=0; DELETE FROM jobs; DELETE FROM state WHERE key='textRepair';
             INSERT INTO jobs(id,kind,priority,error,retry_at) VALUES('mixed','content',100,'local_text_incomplete',0);"))).unwrap();
    }
    let store = Store::open(open_directory(&path)).unwrap();
    store.repair_text().unwrap();
    assert_eq!(job_kind(&store, "mixed").as_deref(), Some("metadata"));

    store.write(|db| store::give_up(db, "huge", "gmail_response_too_large")).unwrap();
    sync::apply_history(&store, &json!({"historyId":"9","history":[{"messagesAdded":[{"message":{"id":"huge"}}]}]}), "").unwrap();
    assert_eq!(job_kind(&store, "huge").as_deref(), Some("metadata"));
    store.write(|db| store::sql(db.execute("DELETE FROM jobs WHERE id='huge'", []))).unwrap();
    store.edit("ticket-1", &["huge".to_string()], &["STARRED".to_string()], &[]).unwrap();
    assert_eq!(job_kind(&store, "huge").as_deref(), Some("metadata"));
    drop(store);
    std::fs::remove_dir_all(path).unwrap();
}

#[test]
fn a_change_to_a_message_starts_its_waits_again() {
    let path = directory();
    let store = Store::open(open_directory(&path)).unwrap();
    store.put(&message("slow", "body"), 1).unwrap();
    store.write(|db| {
        store::sql(db.execute("INSERT INTO jobs(id,kind) VALUES('slow','metadata')", []))?;
        for _ in 0..5 { store::retry_later(db, "slow", "gmail_http_failed", 1_000)?; }
        Ok(())
    }).unwrap();
    sync::apply_history(&store, &json!({"historyId":"9","history":[{"labelsAdded":[{"message":{"id":"slow"}}]}]}), "").unwrap();
    store.write(|db| store::retry_later(db, "slow", "gmail_http_failed", 1_000)).unwrap();
    let (attempts, retry_at): (i64, i64) = store.read(|db| store::sql(db.query_row(
        "SELECT attempts,retry_at FROM jobs WHERE id='slow'", [], |r| Ok((r.get(0)?, r.get(1)?))))).unwrap();
    assert_eq!((attempts, retry_at), (1, 1_000 + 60_000));
    drop(store);
    std::fs::remove_dir_all(path).unwrap();
}

#[test]
fn a_store_from_an_earlier_build_of_this_change_gains_the_unsaved_generation() {
    let path = directory();
    {
        let store = Store::open(open_directory(&path)).unwrap();
        store.write(|db| store::sql(db.execute_batch("ALTER TABLE unsaved DROP COLUMN generation;"))).unwrap();
    }
    let store = Store::open(open_directory(&path)).unwrap();
    store.write(|db| store::give_up(db, "huge", "gmail_response_too_large")).unwrap();
    assert_eq!(store.status().unwrap()["unsaved"], 1);
    // A message whose text is saved is never recorded as unsaved.
    store.put(&message("saved", "body"), 1).unwrap();
    store.write(|db| store::give_up(db, "saved", "gmail_response_too_large")).unwrap();
    assert_eq!(store.status().unwrap()["unsaved"], 1);
    drop(store);
    std::fs::remove_dir_all(path).unwrap();
}
#[test]
fn replies_name_the_newest_message_the_owner_sent_in_each_thread() {
    let path = directory();
    {
        let store = Store::open(open_directory(&path)).unwrap();
        let at = |resource: &mut Value, thread: &str, date: &str, labels: Value| {
            resource["threadId"] = json!(thread);
            resource["internalDate"] = json!(date);
            resource["labelIds"] = labels;
        };
        let mut asked = message("asked", "Can you send the receipts?");
        at(&mut asked, "t1", "1700000000000", json!(["INBOX"]));
        let mut first = message("first", "Here is one.");
        at(&mut first, "t1", "1700000100000", json!(["SENT"]));
        let mut second = message("second", "And the rest.");
        at(&mut second, "t1", "1700000200000", json!(["SENT"]));
        let mut elsewhere = message("elsewhere", "Another thread.");
        at(&mut elsewhere, "t2", "1700000300000", json!(["SENT"]));
        let mut quiet = message("quiet", "No answer yet.");
        at(&mut quiet, "t3", "1700000000000", json!(["INBOX"]));
        for resource in [&asked, &first, &second, &elsewhere, &quiet] {
            store.put(resource, 1).unwrap();
        }
        let replies = store.replies(&["asked".into(), "quiet".into(), "missing".into()]).unwrap();
        assert_eq!(
            replies,
            vec![("asked".into(), "t1".into(), Some("second".into())), ("quiet".into(), "t3".into(), None)],
            "the newest sent message of the email's own thread; an email this copy lacks is left out"
        );
    }
    std::fs::remove_dir_all(path).unwrap();
}

#[test]
fn download_measurements_survive_reopen_but_old_resource_fields_are_not_provenance() {
    let path = directory();
    let mut resource = message("timed", "Synthetic body");
    resource[crate::providers::gmail::DOWNLOAD_MS] = json!(999_999);
    let run = json!({"origin":"desktop","startedAt":100,"finishedAt":200});
    resource[crate::providers::gmail::DOWNLOAD_RUN] = run.clone();
    {
        let store = Store::open(open_directory(&path)).unwrap();
        store.put_cached(&resource, 1).unwrap();
        assert!(store.resource("timed").unwrap().unwrap()[crate::providers::gmail::DOWNLOAD_MS].is_null());
        assert!(store.resource("timed").unwrap().unwrap()[crate::providers::gmail::DOWNLOAD_RUN].is_null());
        store.put_downloaded(&resource, 1, true, Some(125)).unwrap();
        assert_eq!(store.resource("timed").unwrap().unwrap()[crate::providers::gmail::DOWNLOAD_RUN], run);
        assert_eq!(store.resource("timed").unwrap().unwrap()[crate::providers::gmail::DOWNLOAD_MS], 125);
        store.put_cached(&resource, 1).unwrap();
        assert_eq!(store.resource("timed").unwrap().unwrap()[crate::providers::gmail::DOWNLOAD_MS], 125);
    }
    {
        let store = Store::open(open_directory(&path)).unwrap();
        assert_eq!(store.resource("timed").unwrap().unwrap()[crate::providers::gmail::DOWNLOAD_MS], 125);
        assert_eq!(store.resource("timed").unwrap().unwrap()[crate::providers::gmail::DOWNLOAD_RUN], run);
        let later = json!({"origin":"desktop","startedAt":300,"finishedAt":400});
        let mut newest = resource.clone();
        newest[crate::providers::gmail::DOWNLOAD_RUN] = later.clone();
        newest[crate::providers::gmail::DOWNLOAD_MS] = json!(50);
        store.record_downloads(&[newest]).unwrap();
        store.put_downloaded(&resource, 1, true, Some(125)).unwrap();
        assert_eq!(store.resource("timed").unwrap().unwrap()[crate::providers::gmail::DOWNLOAD_RUN], later);
        assert_eq!(store.resource("timed").unwrap().unwrap()[crate::providers::gmail::DOWNLOAD_MS], 50);
        store.delete("timed").unwrap();
        store.record_downloads(&[resource.clone()]).unwrap();
        assert_eq!(store.read(|db| store::sql(db.query_row("SELECT COUNT(*) FROM message_download_runs", [], |r| r.get::<_, i64>(0)))).unwrap(), 0);
        assert_eq!(store.read(|db| store::sql(db.query_row("SELECT COUNT(*) FROM message_downloads", [], |r| r.get::<_, i64>(0)))).unwrap(), 0);
    }
    std::fs::remove_dir_all(path).unwrap();
}
