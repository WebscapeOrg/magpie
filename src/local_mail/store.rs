use super::{content, search, vfs};
use crate::{message::content::header, platform::private_fs as fs};
use rusqlite::{Connection, OptionalExtension, params, params_from_iter};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::io::Read;
use std::{
    fs::File,
    sync::{
        Arc, Mutex,
        atomic::{AtomicUsize, Ordering},
    },
};
type Result<T> = std::result::Result<T, &'static str>;

pub(super) struct ClaimedChanges {
    pub sequence: i64,
    pub additions: Vec<String>,
    pub removals: Vec<String>,
}
impl ClaimedChanges {
    pub(super) fn satisfied_by(&self, resource: &Value) -> Result<bool> {
        let current = server_labels(resource)?;
        Ok(self
            .additions
            .iter()
            .all(|label| current.iter().any(|value| value == label))
            && self
                .removals
                .iter()
                .all(|label| !current.iter().any(|value| value == label)))
    }
}

pub(super) struct Store {
    writer: Mutex<vfs::Database>,
    readers: Vec<Mutex<vfs::Database>>,
    next_reader: AtomicUsize,
    vfs: Arc<vfs::Vfs>,
    pub(super) listener: Mutex<Option<tokio::task::JoinHandle<()>>>,
    fetches: Mutex<std::collections::HashMap<String, std::sync::Weak<tokio::sync::Mutex<()>>>>,
}
pub(super) fn sql<T>(value: rusqlite::Result<T>) -> Result<T> {
    value.map_err(|error| match error.sqlite_error_code() {
        Some(rusqlite::ErrorCode::DiskFull) => "local_disk_full",
        Some(rusqlite::ErrorCode::DatabaseCorrupt | rusqlite::ErrorCode::NotADatabase) => {
            "local_storage_corrupt"
        }
        _ => "local_storage_unavailable",
    })
}
pub(super) fn state(db: &Connection, key: &str) -> Result<String> {
    Ok(sql(db
        .query_row("SELECT value FROM state WHERE key=?1", [key], |row| {
            row.get(0)
        })
        .optional())?
    .unwrap_or_default())
}
pub(super) fn set_state(db: &Connection, key: &str, value: &str) -> Result<()> {
    sql(db.execute("INSERT INTO state VALUES(?1,?2) ON CONFLICT(key) DO UPDATE SET value=excluded.value WHERE state.value!=excluded.value", [key, value]))?;
    Ok(())
}
fn decode(value: &str) -> Result<Value> {
    serde_json::from_str(value).map_err(|_| "local_storage_corrupt")
}
fn server_labels(resource: &Value) -> Result<&[Value]> {
    match resource.get("labelIds") {
        None => Ok(&[]),
        Some(Value::Array(labels))
            if labels.iter().all(|label| {
                label.as_str().is_some_and(|label| {
                    !label.is_empty() && label.len() <= 1024 && !label.chars().any(char::is_control)
                })
            }) =>
        {
            Ok(labels)
        }
        _ => Err("gmail_invalid_response"),
    }
}
fn labels(value: &Value) -> Vec<String> {
    value
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(Value::as_str)
        .map(str::to_owned)
        .collect()
}
pub(super) fn replace_labels(db: &Connection, id: &str, base: &Value) -> Result<()> {
    let mut effective = labels(base);
    let mut edits = sql(db.prepare("SELECT additions,removals FROM edits WHERE id=?1 AND state IN ('queued','sending') ORDER BY sequence"))?;
    let changes = sql(edits.query_map([id], |row| {
        Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
    }))?;
    for change in changes {
        let (add, remove) = sql(change)?;
        let remove = labels(&decode(&remove)?);
        effective.retain(|label| !remove.contains(label));
        for label in labels(&decode(&add)?) {
            if !effective.contains(&label) {
                effective.push(label);
            }
        }
    }
    sql(db.execute("DELETE FROM labels WHERE message_id=?1", [id]))?;
    for label in effective {
        sql(db.execute("INSERT INTO labels VALUES(?1,?2)", params![id, label]))?;
    }
    Ok(())
}
fn current_labels(db: &Connection, id: &str) -> Result<Value> {
    let mut statement =
        sql(db.prepare("SELECT label FROM labels WHERE message_id=?1 ORDER BY label"))?;
    let rows = sql(statement.query_map([id], |row| row.get::<_, String>(0)))?;
    Ok(json!(sql(rows.collect::<rusqlite::Result<Vec<_>>>())?))
}
fn update_summary(mut summary: Value, labels: Value) -> Value {
    let ids = super::store::labels(&labels);
    summary["labelIds"] = labels;
    summary["unread"] = json!(ids.iter().any(|l| l == "UNREAD"));
    summary["starred"] = json!(ids.iter().any(|l| l == "STARRED"));
    summary["inInbox"] = json!(ids.iter().any(|l| l == "INBOX"));
    summary
}
fn label_names(db: &Connection) -> Result<std::collections::HashMap<String, String>> {
    let mut statement = sql(db.prepare("SELECT id,name FROM label_names"))?;
    sql(sql(statement.query_map([], |row| {
        Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
    }))?
    .collect::<rusqlite::Result<_>>())
}
fn cached_summary(db: &Connection, id: &str, raw: &str) -> Result<Value> {
    let mut summary = update_summary(decode(raw)?, current_labels(db, id)?);
    let pending: bool = sql(db.query_row(
        "SELECT EXISTS(SELECT 1 FROM edits WHERE id=?1 AND state IN ('queued','sending'))",
        [id],
        |row| row.get(0),
    ))?;
    summary["pendingEdit"] = json!(pending);
    summary["pendingLabelMatch"] = Value::Null;
    Ok(summary)
}
fn decode_cursor<T: serde::de::DeserializeOwned>(token: &str) -> Result<Option<T>> {
    use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
    if token.is_empty() {
        return Ok(None);
    }
    if token.len() > 4096 {
        return Err("invalid_params");
    }
    let bytes = URL_SAFE_NO_PAD
        .decode(token)
        .map_err(|_| "invalid_params")?;
    serde_json::from_slice(&bytes)
        .map(Some)
        .map_err(|_| "invalid_params")
}
fn search_anchor(requested: Option<i64>, stored: Option<i64>) -> Result<i64> {
    if requested.zip(stored).is_some_and(|(a, b)| a != b) {
        return Err("invalid_params");
    }
    let anchor = requested
        .or(stored)
        .unwrap_or_else(|| chrono::Utc::now().timestamp_millis());
    if !(0..=9_007_199_254_740_991).contains(&anchor) {
        return Err("invalid_params");
    }
    Ok(anchor)
}
fn search_fingerprint(input: &str, account: &str, anchor: i64) -> String {
    let encoded = json!([input, account, anchor]).to_string();
    format!("{:x}", Sha256::digest(encoded.as_bytes()))
}
impl Store {
    pub(super) fn open(directory: File) -> Result<Arc<Self>> {
        if rusqlite::version_number() < 3_051_003 {
            return Err("local_sqlite_update_required");
        }
        let vfs = vfs::Vfs::new(directory)?;
        let mut writer = vfs.connect()?;
        let version: i64 = sql(writer
            .connection
            .pragma_query_value(None, "user_version", |r| r.get(0)))?;
        if version > 1 {
            return Err("local_schema_newer");
        }
        let transaction = sql(writer.connection.transaction())?;
        sql(transaction.execute_batch(include_str!("schema.sql")))?;
        sql(transaction.commit())?;
        let readers = (0..2)
            .map(|_| vfs.connect().map(Mutex::new))
            .collect::<Result<Vec<_>>>()?;
        Ok(Arc::new(Self {
            writer: Mutex::new(writer),
            readers,
            next_reader: AtomicUsize::new(0),
            vfs,
            listener: Mutex::new(None),
            fetches: Mutex::new(Default::default()),
        }))
    }
    pub(super) fn fetch_gate(&self, id: &str) -> Result<Arc<tokio::sync::Mutex<()>>> {
        let mut fetches = self
            .fetches
            .lock()
            .map_err(|_| "local_storage_unavailable")?;
        fetches.retain(|_, gate| gate.strong_count() > 0);
        if let Some(gate) = fetches.get(id).and_then(std::sync::Weak::upgrade) {
            return Ok(gate);
        }
        let gate = Arc::new(tokio::sync::Mutex::new(()));
        fetches.insert(id.to_owned(), Arc::downgrade(&gate));
        Ok(gate)
    }
    pub(super) fn read<T>(&self, call: impl FnOnce(&Connection) -> Result<T>) -> Result<T> {
        let reader = self.next_reader.fetch_add(1, Ordering::Relaxed) % self.readers.len();
        let reader = self.readers[reader]
            .lock()
            .map_err(|_| "local_storage_unavailable")?;
        call(&reader.connection)
    }
    pub(super) fn write<T>(&self, call: impl FnOnce(&Connection) -> Result<T>) -> Result<T> {
        let mut writer = self
            .writer
            .lock()
            .map_err(|_| "local_storage_unavailable")?;
        let tx = sql(writer.connection.transaction())?;
        let answer = call(&tx)?;
        sql(tx.commit())?;
        Ok(answer)
    }
    pub(super) fn directory(&self) -> &File {
        self.vfs.directory()
    }
    #[cfg(target_os = "linux")]
    pub(super) fn notification_snapshot(&self) -> Result<Value> {
        self.read(|db| {
            let transaction=sql(db.unchecked_transaction())?;
            let db=&transaction;
            let waiting:i64=sql(db.query_row("SELECT (SELECT count(*) FROM jobs)+(SELECT count(*) FROM messages WHERE text_complete=0)",[],|r|r.get(0)))?;
            if state(db,"inventoryComplete")?!="true" || waiting!=0 || state(db,"paused")?=="true" || !state(db,"error")?.is_empty() { return Err("local_snapshot_incomplete"); }
            let mut query=sql(db.prepare("SELECT id FROM messages ORDER BY id LIMIT 500001"))?;
            let ids:Vec<String>=sql(query.query_map([],|r|r.get(0)))?.map(sql).collect::<Result<_>>()?;
            if ids.len()>500_000 { return Err("local_snapshot_too_large"); }
            let mut query=sql(db.prepare("SELECT a.message_id FROM labels a JOIN labels b ON a.message_id=b.message_id AND b.label='UNREAD' WHERE a.label='INBOX' ORDER BY a.message_id"))?;
            let unread:Vec<String>=sql(query.query_map([],|r|r.get(0)))?.map(sql).collect::<Result<_>>()?;
            Ok(json!({"ids":ids,"unread":unread}))
        })
    }
    pub(super) fn status(&self) -> Result<Value> {
        self.read(|db| {
            let (stored, complete): (i64,i64) = sql(db.query_row("SELECT (SELECT count(*) FROM messages),(SELECT count(*) FROM messages WHERE text_complete=1)", [], |r| Ok((r.get(0)?,r.get(1)?))))?;
            let pending: i64 = sql(db.query_row("SELECT count(*) FROM jobs", [], |r| r.get(0)))?;
            let failed: i64 = sql(db.query_row("SELECT count(*) FROM jobs WHERE error NOT IN ('','gmail_request_deferred')", [], |r| r.get(0)))?;
            let edits: i64 = sql(db.query_row("SELECT count(DISTINCT ticket) FROM edits WHERE state IN ('queued','sending')", [], |r| r.get(0)))?;
            let conflicts: i64 = sql(db.query_row("SELECT count(DISTINCT ticket) FROM edits WHERE state='conflict'",[],|r|r.get(0)))?;
            let inventory = state(db,"inventoryComplete")? == "true";
            Ok(json!({"stored":stored,"textComplete":complete,"pending":pending,"failed":failed,
                "pendingEdits":edits,"editConflicts":conflicts,"inventoryComplete":inventory,"complete":inventory && pending==0 && stored==complete,
                "paused":state(db,"paused")?=="true","error":state(db,"error")?,"updated":state(db,"updated")?,
                "estimatedTotal":state(db,"estimate")?.parse::<u64>().unwrap_or(0)}))
        })
    }
    pub(super) fn label_counts(&self, id: &str) -> Result<Value> {
        self.read(|db| {
            let total:i64=sql(db.query_row("SELECT count(*) FROM labels WHERE label=?1",[id],|r|r.get(0)))?;
            let unread:i64=sql(db.query_row("SELECT count(*) FROM labels a JOIN labels b ON a.message_id=b.message_id AND b.label='UNREAD' WHERE a.label=?1",[id],|r|r.get(0)))?;
            Ok(json!({"total":total,"unread":unread}))
        })
    }
    pub(super) fn overview(&self) -> Result<Value> {
        let mut result = self.list(
            "in:inbox is:unread -category:social -category:promotions -category:forums",
            3,
            "",
        )?;
        let query = search::parse(
            "in:inbox is:unread -category:social -category:promotions -category:forums",
        )?;
        self.read(|db| {
            result["unread"] = json!(sql(db.query_row(
                &format!("SELECT count(*) FROM messages m WHERE {}", query.sql),
                params_from_iter(query.values.iter()),
                |r| r.get::<_, i64>(0)
            ))?);
            result["labels"] =
                serde_json::from_str::<Value>(&state(db, "labels")?).unwrap_or(json!([]));
            result["profile"] =
                serde_json::from_str::<Value>(&state(db, "profile")?).unwrap_or(Value::Null);
            Ok(())
        })?;
        Ok(result)
    }
    pub(super) fn dismiss_conflict(&self, ticket: &str) -> Result<()> {
        self.write(|db| {
            sql(db.execute(
                "UPDATE edits SET state='dismissed' WHERE ticket=?1 AND state='conflict'",
                [ticket],
            ))?;
            Ok(())
        })
    }
    #[cfg(feature = "mobile")]
    pub(super) fn phone_summaries(&self, thread: Option<&str>) -> Result<Value> {
        self.read(|db| {
            let mut statement=sql(db.prepare("SELECT id,summary FROM messages WHERE (?1 IS NULL OR thread_id=?1) ORDER BY date DESC,id DESC LIMIT 2000"))?;
            let rows=sql(statement.query_map([thread],|row|Ok((row.get::<_,String>(0)?,row.get::<_,String>(1)?))))?;
            let mut summaries=Vec::new();let mut bytes=0;
            for row in rows {
                let (id,raw)=sql(row)?;
                bytes+=raw.len(); if bytes>8*1024*1024 {return Err("local_response_too_large");}
                summaries.push(cached_summary(db,&id,&raw)?);
            }
            Ok(json!({"summaries":summaries}))
        })
    }
    pub(super) fn list(&self, input: &str, limit: usize, cursor: &str) -> Result<Value> {
        self.list_at(input, limit, cursor, "", None)
    }
    pub(super) fn list_at(
        &self,
        input: &str,
        limit: usize,
        cursor: &str,
        account: &str,
        as_of: Option<i64>,
    ) -> Result<Value> {
        use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
        let cursor: Option<(i64, String, i64, String)> = decode_cursor(cursor)?;
        let anchor = search_anchor(as_of, cursor.as_ref().map(|(_, _, anchor, _)| *anchor))?;
        let fingerprint = search_fingerprint(input, account, anchor);
        let mut query = search::parse_with_context(input, account, anchor)?;
        if let Some((date, id, _, owner)) = cursor {
            if owner != fingerprint {
                return Err("invalid_params");
            }
            query.values.push(rusqlite::types::Value::Integer(date));
            let n = query.values.len();
            query.values.push(rusqlite::types::Value::Text(id));
            query
                .sql
                .push_str(&format!(" AND (m.date,m.id)<(?{n},?{})", n + 1));
        }
        let (rows, more) = self.read(|db| {
            query.choose_plan(db)?;
            let statement = format!("SELECT m.id,m.summary,m.date,m.text_complete FROM messages m WHERE {} ORDER BY m.date DESC,m.id DESC LIMIT {}", query.sql, limit+1);
            let mut statement = sql(db.prepare(&statement))?;
            let rows = sql(statement.query_map(params_from_iter(query.values.iter()), |r| Ok((r.get::<_,String>(0)?,r.get::<_,String>(1)?,r.get::<_,i64>(2)?,r.get::<_,bool>(3)?))))?;
            let mut values = Vec::new();
            let mut size = 0;
            let mut more = false;
            let mut names = None;
            for row in rows {
                let (id, summary, date, complete) = sql(row)?;
                let mut summary = cached_summary(db, &id, &summary)?;
                let matched = if complete { Some(true) } else {
                    if names.is_none() { names = Some(label_names(db)?); }
                    let label_match = search::pending_match(input, account, anchor, &labels(&summary["labelIds"]), names.as_ref().unwrap());
                    summary["pendingLabelMatch"] = json!(label_match);
                    label_match
                };
                summary["matchesQuery"] = json!(matched);
                let bytes = serde_json::to_vec(&summary).map_err(|_| "local_storage_corrupt")?.len();
                if values.len() == limit || size + bytes > 16 * 1024 * 1024 {
                    if values.is_empty() { return Err("local_content_too_large"); }
                    more = true;
                    break;
                }
                size += bytes;
                values.push((summary,date,id));
            }
            Ok((values, more))
        })?;
        let next = if more {
            let (_, date, id) = rows.last().ok_or("local_content_invalid")?;
            URL_SAFE_NO_PAD.encode(
                serde_json::to_vec(&(date, id, anchor, &fingerprint))
                    .map_err(|_| "invalid_params")?,
            )
        } else {
            String::new()
        };
        Ok(json!({
            "summaries":rows.into_iter().take(limit).map(|(summary,_,_)|summary).collect::<Vec<_>>(),
            "nextPageToken":next,"coverage":self.status()?,"asOf":anchor
        }))
    }
    pub(super) fn summaries(
        &self,
        account: &str,
        ids: &[String],
        input: Option<&str>,
        as_of: Option<i64>,
        include_pending: bool,
        pending_cursor: &str,
    ) -> Result<Value> {
        use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
        let cursor: Option<(String, i64, String)> = decode_cursor(pending_cursor)?;
        let anchor = search_anchor(as_of, cursor.as_ref().map(|(_, anchor, _)| *anchor))?;
        let fingerprint = search_fingerprint(input.unwrap_or(""), account, anchor);
        if cursor
            .as_ref()
            .is_some_and(|(_, _, owner)| owner != &fingerprint)
        {
            return Err("invalid_params");
        }
        let mut query = match input.map(|input| search::parse_with_context(input, account, anchor))
        {
            Some(Ok(query)) => Some(query),
            Some(Err("local_search_unsupported")) | None => None,
            Some(Err(error)) => return Err(error),
        };
        self.read(|db| {
            let mut wanted = ids.to_vec();
            let mut pending_next = String::new();
            if include_pending {
                let after = cursor.as_ref().map(|(id, _, _)| id.as_str()).unwrap_or("");
                let mut statement = sql(db.prepare("SELECT DISTINCT id FROM edits WHERE state IN ('queued','sending') AND id>?1 ORDER BY id LIMIT 101"))?;
                let pending = sql(sql(statement.query_map([after], |row| row.get::<_, String>(0)))?.collect::<rusqlite::Result<Vec<_>>>())?;
                if pending.len() > 100 {
                    pending_next = URL_SAFE_NO_PAD.encode(serde_json::to_vec(&(&pending[99], anchor, &fingerprint)).map_err(|_| "invalid_params")?);
                }
                for id in pending.into_iter().take(100) {
                    if !wanted.contains(&id) { wanted.push(id); }
                }
            }
            if let Some(query) = &mut query { query.choose_plan(db)?; }
            let names = if input.is_some() { label_names(db)? } else { Default::default() };
            let mut summaries = Vec::new();
            let mut missing = Vec::new();
            let mut size = 0;
            for id in wanted {
                let raw: Option<(String, bool)> = sql(db.query_row("SELECT summary,text_complete FROM messages WHERE id=?1", [&id], |row| Ok((row.get(0)?, row.get(1)?))).optional())?;
                let Some((raw, complete)) = raw else {
                    if ids.contains(&id) { missing.push(id); }
                    continue;
                };
                let mut summary = cached_summary(db, &id, &raw)?;
                let label_match = input.and_then(|input| search::pending_match(input, account, anchor, &labels(&summary["labelIds"]), &names));
                summary["pendingLabelMatch"] = json!(label_match);
                let matched = if let Some(query) = query.as_ref().filter(|_| complete) {
                    let mut values = query.values.clone();
                    values.push(rusqlite::types::Value::Text(id.clone()));
                    let statement = format!("SELECT EXISTS(SELECT 1 FROM messages m WHERE m.id=?{} AND ({}))", values.len(), query.sql);
                    Some(sql(db.query_row(&statement, params_from_iter(values.iter()), |row| row.get::<_, bool>(0)))?)
                } else { label_match };
                summary["matchesQuery"] = json!(matched);
                size += serde_json::to_vec(&summary).map_err(|_| "local_storage_corrupt")?.len();
                if size > 16 * 1024 * 1024 { return Err("local_content_too_large"); }
                summaries.push(summary);
            }
            let response = json!({"summaries":summaries,"missingIds":missing,"asOf":anchor,"pendingNextPageToken":pending_next});
            if serde_json::to_vec(&response).map_err(|_| "local_storage_corrupt")?.len() > 16 * 1024 * 1024 {
                return Err("local_content_too_large");
            }
            Ok(response)
        })
    }
    fn blob_dir(&self, hash: &str, create: bool) -> Result<Option<File>> {
        if hash.len() != 64 || !hash.bytes().all(|b| b.is_ascii_hexdigit()) {
            return Err("local_storage_corrupt");
        }
        let Some(blobs) = fs::open_dir(self.directory(), "blobs".as_ref(), create, true)? else {
            return Ok(None);
        };
        fs::open_dir(&blobs, hash[..2].as_ref(), create, true)
    }
    pub(super) fn resource(&self, id: &str) -> Result<Option<Value>> {
        let row = self.read(|db| {
            let hash: Option<String> = sql(db
                .query_row("SELECT blob FROM messages WHERE id=?1", [id], |r| r.get(0))
                .optional())?;
            hash.map(|hash| Ok((hash, current_labels(db, id)?)))
                .transpose()
        })?;
        let Some((hash, labels)) = row else {
            return Ok(None);
        };
        let directory = self
            .blob_dir(&hash, false)?
            .ok_or("local_content_missing")?;
        let file = fs::regular(&directory, &hash, false)?.ok_or("local_content_missing")?;
        let mut bytes = Vec::new();
        file.take(128 * 1024 * 1024 + 1)
            .read_to_end(&mut bytes)
            .map_err(|_| "local_content_missing")?;
        if bytes.len() > 128 * 1024 * 1024 || format!("{:x}", Sha256::digest(&bytes)) != hash {
            return Err("local_content_invalid");
        }
        let resource: Value =
            serde_json::from_slice(&bytes).map_err(|_| "local_content_invalid")?;
        if resource["id"] != id {
            return Err("local_content_invalid");
        }
        let mut resource = resource;
        resource["labelIds"] = labels;
        Ok(Some(resource))
    }
    pub(super) fn complete_resource(&self, id: &str) -> Result<Option<Value>> {
        let complete = self.read(|db| {
            sql(db.query_row(
                "SELECT EXISTS(SELECT 1 FROM messages WHERE id=?1 AND text_complete=1)",
                [id],
                |r| r.get::<_, bool>(0),
            ))
        })?;
        if !complete {
            return Ok(None);
        }
        self.resource(id)
    }
    pub(super) fn revision(&self, id: &str) -> Result<Option<String>> {
        self.read(|db| {
            let hash: Option<String> = sql(db
                .query_row("SELECT blob FROM messages WHERE id=?1", [id], |r| r.get(0))
                .optional())?;
            hash.map(|hash| Ok(format!("{hash}:{}", current_labels(db, id)?)))
                .transpose()
        })
    }
    pub(super) fn put(&self, resource: &Value, generation: i64) -> Result<()> {
        self.save(resource, generation, true)
    }
    pub(super) fn put_cached(&self, resource: &Value, generation: i64) -> Result<()> {
        self.save(resource, generation, false)
    }
    fn save(&self, resource: &Value, generation: i64, authoritative: bool) -> Result<()> {
        let id = resource["id"].as_str().ok_or("local_content_invalid")?;
        if id.is_empty() || !resource["payload"].is_object() {
            return Err("local_content_invalid");
        }
        let bytes = serde_json::to_vec(resource).map_err(|_| "local_content_invalid")?;
        if bytes.len() > 128 * 1024 * 1024 {
            return Err("local_content_too_large");
        }
        if fs::available_bytes(self.directory())? < 1024 * 1024 * 1024 + bytes.len() as u64 {
            return Err("local_disk_low");
        }
        let hash = format!("{:x}", Sha256::digest(&bytes));
        let directory = self
            .blob_dir(&hash, true)?
            .ok_or("local_storage_unavailable")?;
        if fs::regular(&directory, &hash, false)?.is_none() {
            fs::atomic_replace(&directory, &hash, &bytes)?;
        }
        let summary =
            crate::message::content::summarize(resource, chrono::Utc::now().timestamp_millis())?;
        let text = content::extract(resource);
        let sender = header(resource, "from");
        let recipients = header(resource, "to");
        let copied = header(resource, "cc");
        let subject = header(resource, "subject");
        self.write(|db| {
            if sql(db.query_row("SELECT EXISTS(SELECT 1 FROM deleted_messages WHERE id=?1)", [id], |row| row.get::<_,bool>(0)))? {
                return Err("gmail_not_found");
            }
            let mut base = json!(server_labels(resource)?);
            if !authoritative {
                let previous: Option<String> = sql(db.query_row("SELECT server_labels FROM messages WHERE id=?1", [id], |row| row.get(0)).optional())?;
                if let Some(previous) = previous { base = decode(&previous)?; }
            }
            sql(db.execute("INSERT INTO messages(id,thread_id,date,summary,blob,server_labels,sender,recipients,copied,subject,filenames,has_attachment,text_complete,generation) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14) ON CONFLICT(id) DO UPDATE SET thread_id=excluded.thread_id,date=excluded.date,summary=excluded.summary,blob=excluded.blob,server_labels=excluded.server_labels,sender=excluded.sender,recipients=excluded.recipients,copied=excluded.copied,subject=excluded.subject,filenames=excluded.filenames,has_attachment=excluded.has_attachment,text_complete=excluded.text_complete,generation=max(messages.generation,excluded.generation)",
                params![id,resource["threadId"].as_str().unwrap_or(""),resource["internalDate"].as_str().and_then(|v|v.parse::<i64>().ok()).unwrap_or(0),
                    summary.to_string(),hash,base.to_string(),sender.to_lowercase(),recipients.to_lowercase(),copied.to_lowercase(),subject,text.filenames.to_lowercase(),summary["hasAttachments"]==true,text.complete,generation]))?;
            replace_labels(db,id,&base)?;
            sql(db.execute("DELETE FROM search WHERE rowid=(SELECT rowid FROM messages WHERE id=?1)",[id]))?;
            sql(db.execute("INSERT INTO search(rowid,id,subject,sender,recipients,copied,filenames,body) VALUES((SELECT rowid FROM messages WHERE id=?1),?1,?2,?3,?4,?5,?6,?7)",
                params![id,subject,sender,recipients,copied,text.filenames,text.body]))?;
            if text.complete && authoritative {sql(db.execute("DELETE FROM jobs WHERE id=?1",[id]))?;}
            else if text.complete {sql(db.execute("INSERT INTO jobs(id,kind,priority,generation) VALUES(?1,'metadata',50,?2) ON CONFLICT(id) DO UPDATE SET kind='metadata',retry_at=0,generation=max(jobs.generation,excluded.generation)",params![id,generation]))?;}
            else {sql(db.execute("INSERT INTO jobs(id,error,retry_at,generation) VALUES(?1,'local_text_incomplete',?2,?3) ON CONFLICT(id) DO UPDATE SET error=excluded.error,retry_at=excluded.retry_at,kind='content',generation=max(jobs.generation,excluded.generation)",params![id,chrono::Utc::now().timestamp_millis()+300_000,generation]))?;}
            Ok(())
        })
    }
    pub(super) fn metadata(&self, resource: &Value) -> Result<()> {
        let id = resource["id"].as_str().ok_or("local_content_invalid")?;
        let labels = server_labels(resource)?;
        self.write(|db| {
            let changed = sql(db.execute(
                "UPDATE messages SET server_labels=?2 WHERE id=?1",
                params![id, json!(labels).to_string()],
            ))?;
            if changed > 0 {
                replace_labels(db, id, &json!(labels))?;
            }
            sql(db.execute("DELETE FROM jobs WHERE id=?1 AND kind='metadata'", [id]))?;
            Ok(())
        })
    }
    pub(super) fn delete(&self, id: &str) -> Result<()> {
        self.write(|db| delete(db, id))
    }
    pub(super) fn edits(&self) -> Result<Value> {
        self.read(|db| {
            let mut statement = sql(db.prepare("SELECT ticket,state,error,count(*) FROM edits GROUP BY ticket,state,error ORDER BY min(sequence)"))?;
            let rows = sql(statement.query_map([], |r| Ok(json!({"ticket":r.get::<_,String>(0)?,"state":r.get::<_,String>(1)?,"error":r.get::<_,String>(2)?,"count":r.get::<_,i64>(3)?}))))?;
            Ok(json!(sql(rows.collect::<rusqlite::Result<Vec<_>>>())?))
        })
    }
    pub(super) fn edit(
        &self,
        ticket: &str,
        ids: &[String],
        add: &[String],
        remove: &[String],
    ) -> Result<Value> {
        self.write(|db| {
            let exists: bool = sql(db.query_row("SELECT EXISTS(SELECT 1 FROM edits WHERE ticket=?1)",[ticket],|r|r.get(0)))?;
            if exists {
                let mut statement=sql(db.prepare("SELECT id,additions,removals FROM edits WHERE ticket=?1 ORDER BY sequence"))?;
                let rows=sql(sql(statement.query_map([ticket],|r|Ok((r.get::<_,String>(0)?,r.get::<_,String>(1)?,r.get::<_,String>(2)?))))?.collect::<rusqlite::Result<Vec<_>>>())?;
                if rows.len()!=ids.len() || rows.iter().zip(ids).any(|((id,a,r),expected)| id!=expected || *a!=json!(add).to_string() || *r!=json!(remove).to_string()) {
                    return Err("local_edit_id_conflict");
                }
                return Ok(json!({"ticket":ticket,"queued":true}));
            }
            for id in ids {
                let base: Option<String> = sql(db.query_row("SELECT server_labels FROM messages WHERE id=?1",[id],|r|r.get(0)).optional())?;
                let before = current_labels(db,id)?;
                sql(db.execute("INSERT INTO edits(ticket,id,additions,removals,before_labels) VALUES(?1,?2,?3,?4,?5)",
                    params![ticket,id,json!(add).to_string(),json!(remove).to_string(),before.to_string()]))?;
                if let Some(base)=base {replace_labels(db,id,&decode(&base)?)?;}
                else {sql(db.execute("INSERT INTO jobs(id,priority,generation) VALUES(?1,1000,0) ON CONFLICT(id) DO UPDATE SET priority=1000,retry_at=0",[id]))?;}
            }
            Ok(json!({"ticket":ticket,"queued":true}))
        })
    }
    pub(super) fn cancel_edit(&self, ticket: &str) -> Result<()> {
        self.write(|db| {
            let active: bool = sql(db.query_row(
                "SELECT EXISTS(SELECT 1 FROM edits WHERE ticket=?1 AND state!='queued')",
                [ticket],
                |r| r.get(0),
            ))?;
            if active {
                return Err("local_edit_already_started");
            }
            let mut statement = sql(db.prepare("SELECT DISTINCT id FROM edits WHERE ticket=?1"))?;
            let ids = sql(
                sql(statement.query_map([ticket], |r| r.get::<_, String>(0)))?
                    .collect::<rusqlite::Result<Vec<_>>>(),
            )?;
            sql(db.execute("DELETE FROM edits WHERE ticket=?1", [ticket]))?;
            for id in ids {
                let base: Option<String> = sql(db
                    .query_row(
                        "SELECT server_labels FROM messages WHERE id=?1",
                        [&id],
                        |r| r.get(0),
                    )
                    .optional())?;
                if let Some(base) = base {
                    replace_labels(db, &id, &decode(&base)?)?;
                }
            }
            Ok(())
        })
    }
    pub(super) fn claim_changes(&self, id: &str) -> Result<Option<ClaimedChanges>> {
        self.write(|db| {
            let mut statement=sql(db.prepare("SELECT sequence,additions,removals FROM edits WHERE id=?1 AND state IN ('queued','sending') ORDER BY sequence"))?;
            let rows=sql(sql(statement.query_map([id],|r|Ok((r.get::<_,i64>(0)?,r.get::<_,String>(1)?,r.get::<_,String>(2)?))))?.collect::<rusqlite::Result<Vec<_>>>())?;
            let Some((last,_,_))=rows.last() else {return Ok(None)};
            let mut target=std::collections::BTreeMap::new();
            for (_,add,remove) in &rows {
                for value in labels(&decode(add)?) {target.insert(value,true);}
                for value in labels(&decode(remove)?) {target.insert(value,false);}
            }
            let add=target.iter().filter(|(_,add)|**add).map(|(label,_)|label.clone()).collect::<Vec<_>>();
            let remove=target.iter().filter(|(_,add)|!**add).map(|(label,_)|label.clone()).collect::<Vec<_>>();
            sql(db.execute("UPDATE edits SET state='sending' WHERE id=?1 AND sequence<=?2 AND state='queued'",params![id,last]))?;
            Ok(Some(ClaimedChanges { sequence: *last, additions: add, removals: remove }))
        })
    }
}
impl Drop for Store {
    fn drop(&mut self) {
        if let Ok(listener) = self.listener.get_mut() {
            if let Some(task) = listener.take() {
                task.abort();
            }
        }
    }
}
pub(super) fn delete(db: &Connection, id: &str) -> Result<()> {
    sql(db.execute("INSERT OR IGNORE INTO deleted_messages VALUES(?1)", [id]))?;
    sql(db.execute("UPDATE edits SET state='conflict',error='message_deleted' WHERE id=?1 AND state IN ('queued','sending')",[id]))?;
    sql(db.execute(
        "DELETE FROM search WHERE rowid=(SELECT rowid FROM messages WHERE id=?1)",
        [id],
    ))?;
    sql(db.execute("DELETE FROM messages WHERE id=?1", [id]))?;
    sql(db.execute("DELETE FROM jobs WHERE id=?1", [id]))?;
    Ok(())
}
