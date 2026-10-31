use super::store::{Store, set_state, sql, state};
use super::sync::disk;
use crate::providers::gmail;
use rusqlite::{Connection, params};
use serde_json::{Value, json};
use std::sync::Arc;

type Result<T> = std::result::Result<T, &'static str>;

pub(super) fn reset(db: &Connection) -> Result<()> {
    for key in ["inboxPage", "inboxListed", "inboxReady"] {
        set_state(db, key, "")?;
    }
    sql(db.execute_batch(
        "DELETE FROM inbox_scan; DELETE FROM inbox_pages; DELETE FROM inbox_dirty;",
    ))?;
    Ok(())
}

pub(super) async fn scan(
    store: &Arc<Store>,
    gmail: &gmail::Session,
    account: &str,
) -> Result<bool> {
    let (listed, page, generation) = disk(store, |s| {
        s.read(|db| {
            Ok((
                state(db, "inboxListed")? == "true",
                state(db, "inboxPage")?,
                state(db, "generation")?.parse::<i64>().unwrap_or(1),
            ))
        })
    })
    .await?;
    if listed {
        return Ok(false);
    }
    let response = gmail
        .replica_call(account, "inbox", &json!({"pageToken":page}))
        .await?;
    disk(store, move |s| apply_page(s, &response, &page, generation)).await?;
    Ok(true)
}

pub(super) fn apply_page(
    store: &Store,
    response: &Value,
    page: &str,
    generation: i64,
) -> Result<()> {
    if !response.is_object()
        || response
            .get("nextPageToken")
            .is_some_and(|v| !v.is_string())
    {
        return Err("gmail_invalid_response");
    }
    let next = response["nextPageToken"].as_str().unwrap_or("");
    if (!next.is_empty() && next == page)
        || (!response["messages"].is_array()
            && !(response["messages"].is_null()
                && response["resultSizeEstimate"] == 0
                && next.is_empty()))
    {
        return Err("gmail_invalid_response");
    }
    store.write(|db| {
        if state(db,"generation")?.parse::<i64>().unwrap_or(1) != generation || state(db,"inboxPage")? != page || state(db,"inboxListed")? == "true" { return Ok(()); }
        if !next.is_empty() && sql(db.execute("INSERT OR IGNORE INTO inbox_pages VALUES(?1)", [next]))? == 0 {
            return Err("gmail_invalid_response");
        }
        for message in response["messages"].as_array().into_iter().flatten() {
            let id = super::sync::valid_id(&message["id"])?;
            sql(db.execute("INSERT OR IGNORE INTO inbox_scan VALUES(?1)", [id]))?;
            queue(db, id, generation)?;
        }
        set_state(db, "inboxPage", next)?;
        if !next.is_empty() { return Ok(()); }
        sql(db.execute_batch("DELETE FROM inbox_members; INSERT INTO inbox_members SELECT id FROM inbox_scan;"))?;
        let mut statement = sql(db.prepare("SELECT id FROM inbox_dirty UNION SELECT message_id FROM labels WHERE label='INBOX' AND message_id NOT IN (SELECT id FROM inbox_members)"))?;
        let ids = sql(sql(statement.query_map([], |r| r.get::<_, String>(0)))?.collect::<rusqlite::Result<Vec<_>>>())?;
        for id in ids { queue(db, &id, generation)?; }
        set_state(db, "inboxListed", "true")?;
        set_state(db, "lastHistory", "0")?;
        sql(db.execute_batch("DELETE FROM inbox_scan; DELETE FROM inbox_pages;"))?;
        Ok(())
    })
}

fn queue(db: &Connection, id: &str, generation: i64) -> Result<()> {
    sql(db.execute(
        "UPDATE messages SET generation=max(generation,?2) WHERE id=?1",
        params![id, generation],
    ))?;
    sql(db.execute("INSERT INTO jobs(id,kind,priority,generation) VALUES(?1,CASE WHEN EXISTS(SELECT 1 FROM messages WHERE id=?1 AND text_complete=1) THEN 'metadata' ELSE 'content' END,2000,?2) ON CONFLICT(id) DO UPDATE SET priority=max(priority,2000),retry_at=0,generation=max(jobs.generation,excluded.generation)",params![id,generation]))?;
    Ok(())
}

pub(super) fn changed(db: &Connection, id: &str) -> Result<()> {
    sql(db.execute("INSERT OR IGNORE INTO inbox_dirty VALUES(?1)", [id]))?;
    sql(db.execute(
        "UPDATE jobs SET priority=max(priority,2000) WHERE id=?1",
        [id],
    ))?;
    Ok(())
}

pub(super) fn resource(db: &Connection, id: &str, labels: &Value) -> Result<()> {
    if labels
        .as_array()
        .is_some_and(|ls| ls.iter().any(|l| l == "INBOX"))
    {
        sql(db.execute("INSERT OR IGNORE INTO inbox_members VALUES(?1)", [id]))?;
    } else {
        sql(db.execute("DELETE FROM inbox_members WHERE id=?1", [id]))?;
    }
    if state(db, "inboxListed")? == "true" {
        sql(db.execute("DELETE FROM inbox_dirty WHERE id=?1", [id]))?;
    }
    Ok(())
}

pub(super) fn deleted(db: &Connection, id: &str) -> Result<()> {
    for table in ["inbox_members", "inbox_scan", "inbox_dirty"] {
        sql(db.execute(&format!("DELETE FROM {table} WHERE id=?1"), [id]))?;
    }
    Ok(())
}

pub(super) fn health(db: &Connection) -> Result<Value> {
    let inbox_known = state(db, "inboxReady")? == "true";
    let all_known = state(db, "inventoryComplete")? == "true";
    let count = |query| sql(db.query_row(query, [], |r| r.get::<_, i64>(0)));
    let missing = count(
        "SELECT count(*) FROM (SELECT id FROM jobs WHERE id NOT IN (SELECT id FROM messages WHERE text_complete=1) UNION SELECT id FROM messages WHERE text_complete=0)",
    )?;
    let inbox_missing = count(
        "SELECT count(*) FROM inbox_members WHERE id NOT IN (SELECT id FROM messages WHERE text_complete=1)",
    )?;
    let dirty = count("SELECT count(*) FROM inbox_dirty")?;
    let inbox_pending = count(
        "SELECT count(*) FROM jobs WHERE id IN (SELECT id FROM inbox_members UNION SELECT message_id FROM labels WHERE label='INBOX')",
    )?;
    let mismatch = count(
        "SELECT count(*) FROM (SELECT id FROM inbox_members WHERE id NOT IN (SELECT message_id FROM labels WHERE label='INBOX') UNION SELECT message_id FROM labels WHERE label='INBOX' AND message_id NOT IN (SELECT id FROM inbox_members))",
    )?;
    let edits = count("SELECT count(*) FROM edits WHERE state IN ('queued','sending','conflict')")?;
    let metadata = count(
        "SELECT count(*) FROM jobs WHERE id IN (SELECT id FROM messages WHERE text_complete=1)",
    )?;
    Ok(json!({
        "lastChecked":state(db,"lastChecked")?.parse::<i64>().ok(),
        "inboxKnown":inbox_known,"inventoryKnown":all_known,
        "inboxComplete":inbox_known && inbox_missing==0 && dirty==0 && inbox_pending==0 && mismatch==0 && edits==0,
        "inboxMissing":if inbox_known {Some(inbox_missing)} else {None},
        "missing":missing,"missingExact":all_known,
        "otherMissing":if all_known && inbox_known && dirty==0 {Some((missing-inbox_missing).max(0))} else {None},
        "metadataPending":metadata,"unclassified":dirty,
        "otherDownloaded":state(db,"otherDownloaded")?.parse::<u64>().unwrap_or(0)
    }))
}

pub(super) fn downloaded(db: &Connection, id: &str) -> Result<()> {
    let other: bool = sql(db.query_row(
        "SELECT NOT EXISTS(SELECT 1 FROM inbox_members WHERE id=?1)",
        [id],
        |r| r.get(0),
    ))?;
    if other && state(db, "inboxReady")? == "true" {
        let total = state(db, "otherDownloaded")?
            .parse::<u64>()
            .unwrap_or(0)
            .saturating_add(1);
        set_state(db, "otherDownloaded", &total.to_string())?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::local_mail::{
        sync,
        tests::{directory, message, open_directory},
    };
    struct Fixture(std::path::PathBuf, Arc<Store>);
    impl Fixture {
        fn new() -> Self {
            let p = directory();
            let s = Store::open(open_directory(&p)).unwrap();
            Self(p, s)
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            std::fs::remove_dir_all(&self.0).unwrap();
        }
    }
    fn set(s: &Store, key: &str, value: &str) {
        s.write(|db| set_state(db, key, value)).unwrap();
    }
    fn dirty(s: &Store, id: &str) -> bool {
        s.read(|db| {
            sql(db.query_row(
                "SELECT EXISTS(SELECT 1 FROM inbox_dirty WHERE id=?1)",
                [id],
                |r| r.get(0),
            ))
        })
        .unwrap()
    }
    fn history(s: &Store, events: Value) {
        sync::apply_history(s, &json!({"historyId":"200","history":events}), "").unwrap();
    }
    fn health(s: &Store) -> Value {
        s.status().unwrap()["health"].clone()
    }

    #[test]
    fn inbox_completes_while_missing_archive_and_metadata_are_counted_separately() {
        let f = Fixture::new();
        let s = &f.1;
        s.put(&message("inbox", "saved"), 1).unwrap();
        apply_page(s, &json!({"messages":[{"id":"inbox"}]}), "", 1).unwrap();
        assert_eq!(health(s)["inboxKnown"], false);
        history(s, json!([]));
        assert_eq!(health(s)["inboxComplete"], false);
        s.metadata(&json!({"id":"inbox","labelIds":["INBOX"]}))
            .unwrap();
        set(s, "inventoryComplete", "true");
        let mut archived = message("saved-archive", "saved");
        archived["labelIds"] = json!([]);
        s.put(&archived, 1).unwrap();
        s.write(|db|{sql(db.execute_batch("INSERT INTO jobs(id) VALUES('missing-archive');INSERT INTO jobs(id,kind) VALUES('saved-archive','metadata');"))?;Ok(())}).unwrap();
        let h = health(s);
        assert_eq!(h["inboxComplete"], true);
        assert_eq!(h["missing"], 1);
        assert_eq!(h["otherMissing"], 1);
        assert_eq!(h["metadataPending"], 1);
        assert_eq!(h["lastChecked"], Value::Null);
    }
    #[test]
    fn history_dirty_ids_survive_fetches_until_scan_finishes_and_requeues_them() {
        let f = Fixture::new();
        let s = &f.1;
        apply_page(
            s,
            &json!({"messages":[{"id":"one"}],"nextPageToken":"p2"}),
            "",
            1,
        )
        .unwrap();
        history(s, json!([{"messagesAdded":[{"message":{"id":"arrived"}}]}]));
        s.put(&message("arrived", "new body"), 1).unwrap();
        assert!(dirty(s, "arrived"));
        apply_page(s, &json!({"messages":[]}), "p2", 1).unwrap();
        assert!(dirty(s, "arrived"));
        assert_eq!(health(s)["inboxKnown"], false);
        s.put(&message("one", "body"), 1).unwrap();
        sync::apply_history(s, &json!({"historyId":"201","nextPageToken":"h2"}), "").unwrap();
        assert_eq!(health(s)["inboxKnown"], false);
        sync::apply_history(s, &json!({"historyId":"202"}), "h2").unwrap();
        assert_eq!(health(s)["inboxKnown"], true);
        assert_eq!(health(s)["inboxComplete"], false);
        s.metadata(&json!({"id":"arrived","labelIds":["INBOX"]}))
            .unwrap();
        assert!(!dirty(s, "arrived"));
        assert_eq!(health(s)["inboxComplete"], true);
    }
    #[test]
    fn cached_reads_do_not_confirm_unknown_history_membership() {
        let f = Fixture::new();
        let s = &f.1;
        apply_page(s, &json!({"messages":[]}), "", 1).unwrap();
        history(s, json!([{"messagesAdded":[{"message":{"id":"unknown"}}]}]));
        s.put_cached(&message("unknown", "cached"), 1).unwrap();
        assert!(dirty(s, "unknown"));
        assert_eq!(health(s)["inboxComplete"], false);
        s.metadata(&json!({"id":"unknown","labelIds":[]})).unwrap();
        assert!(!dirty(s, "unknown"));
        assert_eq!(health(s)["inboxComplete"], true);
    }
    #[test]
    fn stale_inbox_members_are_refreshed_and_deletions_cannot_complete_early() {
        let f = Fixture::new();
        let s = &f.1;
        s.put(&message("stale", "body"), 0).unwrap();
        apply_page(s, &json!({"messages":[]}), "", 1).unwrap();
        history(s, json!([]));
        assert_eq!(health(s)["inboxComplete"], false);
        s.metadata(&json!({"id":"stale","labelIds":[]})).unwrap();
        assert_eq!(health(s)["inboxComplete"], true);
        history(s, json!([{"messagesAdded":[{"message":{"id":"deleted"}}]}]));
        s.delete("deleted").unwrap();
        assert!(!dirty(s, "deleted"));
        assert_eq!(health(s)["inboxComplete"], true);
    }
    #[test]
    fn malformed_or_repeated_pages_do_not_publish_an_inbox() {
        let f = Fixture::new();
        let s = &f.1;
        assert_eq!(
            apply_page(s, &json!({}), "", 1),
            Err("gmail_invalid_response")
        );
        assert_eq!(
            apply_page(s, &json!({"messages":[{"id":"ok"},{"id":"bad\n"}]}), "", 1),
            Err("gmail_invalid_response")
        );
        assert_eq!(health(s)["missing"], 0);
        apply_page(s, &json!({"messages":[],"nextPageToken":"p2"}), "", 1).unwrap();
        apply_page(s, &json!({"messages":[],"nextPageToken":"p3"}), "p2", 1).unwrap();
        assert_eq!(
            apply_page(s, &json!({"messages":[],"nextPageToken":"p2"}), "p3", 1),
            Err("gmail_invalid_response")
        );
        assert_eq!(health(s)["inboxKnown"], false);
    }
    #[test]
    fn stale_scan_and_inventory_replies_after_reset_are_no_ops() {
        let f = Fixture::new();
        let s = &f.1;
        apply_page(s, &json!({"messages":[],"nextPageToken":"old"}), "", 1).unwrap();
        sync::restart_inventory(s).unwrap();
        apply_page(s, &json!({"messages":[{"id":"stale"}]}), "old", 1).unwrap();
        sync::apply_inventory(s, &json!({"messages":[{"id":"stale"}]}), "", 1).unwrap();
        assert_eq!(health(s)["missing"], 0);
        assert_eq!(health(s)["inboxKnown"], false);
        assert_eq!(s.status().unwrap()["inventoryComplete"], false);
    }
    #[test]
    fn reopening_does_not_trust_readiness_maintained_by_an_older_engine() {
        let path = directory();
        {
            let s = Store::open(open_directory(&path)).unwrap();
            apply_page(&s, &json!({"messages":[]}), "", 1).unwrap();
            history(&s, json!([]));
            assert_eq!(health(&s)["inboxComplete"], true);
        }
        let s = Store::open(open_directory(&path)).unwrap();
        assert_eq!(health(&s)["inboxKnown"], false);
        drop(s);
        std::fs::remove_dir_all(path).unwrap();
    }
    #[test]
    fn reset_invalidates_inbox_and_download_counter_counts_real_completion_only() {
        let f = Fixture::new();
        let s = &f.1;
        apply_page(s, &json!({"messages":[]}), "", 1).unwrap();
        history(s, json!([]));
        let mut m = message("archive", "body");
        m["labelIds"] = json!([]);
        s.put(&m, 1).unwrap();
        s.put(&m, 1).unwrap();
        assert_eq!(health(s)["otherDownloaded"], 1);
        s.delete("archive").unwrap();
        assert_eq!(health(s)["otherDownloaded"], 1);
        sync::restart_inventory(s).unwrap();
        assert_eq!(health(s)["inboxKnown"], false);
    }
}
