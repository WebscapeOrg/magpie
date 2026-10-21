use super::store::{Store, delete, replace_labels, set_state, sql, state};
use crate::providers::gmail;
use rusqlite::{OptionalExtension, params};
use serde_json::{Value, json};
use std::sync::Arc;
type Result<T> = std::result::Result<T, &'static str>;
pub(super) async fn disk<T: Send + 'static>(
    store: &Arc<Store>,
    work: impl FnOnce(&Store) -> Result<T> + Send + 'static,
) -> Result<T> {
    let store = store.clone();
    tokio::task::spawn_blocking(move || work(&store))
        .await
        .map_err(|_| "local_storage_unavailable")?
}
fn valid_id(value: &Value) -> Result<&str> {
    value
        .as_str()
        .filter(|v| !v.is_empty() && v.len() <= 1024 && !v.chars().any(char::is_control))
        .ok_or("gmail_invalid_response")
}
pub(super) async fn step(
    store: &Arc<Store>,
    gmail: &gmail::Session,
    account: &str,
    _tick: u64,
) -> Result<bool> {
    if deliver_edit(store, gmail, account).await? {
        return Ok(true);
    }
    if disk(store, |s| s.read(|db| Ok(state(db, "paused")? == "true"))).await? {
        return Ok(false);
    }
    let legacy = disk(store, |s| {
        s.read(|db| Ok((state(db, "legacyImported")?, state(db, "legacyCursor")?)))
    })
    .await?;
    if legacy.0 != "true" {
        let next = crate::cache::resource::legacy_next(account, &legacy.1).await?;
        disk(store, move |s| {
            if let Some((cursor, resource)) = next {
                if let Some(resource) = resource {
                    if s.revision(resource["id"].as_str().ok_or("local_content_invalid")?)?
                        .is_none()
                    {
                        s.put(&resource, 0)?;
                    }
                }
                s.write(|db| set_state(db, "legacyCursor", &cursor))
            } else {
                s.write(|db| set_state(db, "legacyImported", "true"))
            }
        })
        .await?;
        return Ok(true);
    }
    let mut history = disk(store, |s| s.read(|db| state(db, "history"))).await?;
    if history.is_empty() {
        let profile = gmail.replica_call(account, "profile", &json!({})).await?;
        history = valid_id(&profile["historyId"])?.to_owned();
        let estimate = profile["messagesTotal"].as_u64().unwrap_or(0).to_string();
        let checkpoint = history.clone();
        disk(store, move |s|s.write(|db| {
            set_state(db,"history",&checkpoint)?;
            set_state(db,"estimate",&estimate)?;
            set_state(db,"profile",&json!({"email":profile["emailAddress"],"messagesTotal":profile["messagesTotal"]}).to_string())?;
            if state(db,"generation")?.is_empty() { set_state(db,"generation","1")?; }
            Ok(())
        })).await?;
    }
    let due = disk(store, |s| {
        s.read(|db| {
            Ok(chrono::Utc::now().timestamp_millis()
                - state(db, "lastHistory")?.parse::<i64>().unwrap_or(0)
                >= 30_000)
        })
    })
    .await?;
    if due {
        match changes(store, gmail, account, &history).await {
            Err("gmail_not_found") => {
                disk(store, restart_inventory).await?;
                return Ok(true);
            }
            answer => answer?,
        }
        disk(store, |s| {
            s.write(|db| {
                if state(db, "historyPage")?.is_empty() {
                    set_state(
                        db,
                        "lastHistory",
                        &chrono::Utc::now().timestamp_millis().to_string(),
                    )
                } else {
                    Ok(())
                }
            })
        })
        .await?;
        let labels = gmail.replica_call(account, "labels", &json!({})).await?;
        disk(store,move|s|s.write(|db| {
            if !labels["labels"].is_array() {return Err("gmail_invalid_response");}
            sql(db.execute("DELETE FROM label_names",[]))?;
            set_state(db,"labels",&gmail::normalize_labels(labels.clone()).to_string())?;
            for label in labels["labels"].as_array().into_iter().flatten() {
                let id = valid_id(&label["id"])?;
                let name = label["name"].as_str().unwrap_or(id);
                sql(db.execute("INSERT INTO label_names VALUES(?1,?2) ON CONFLICT(id) DO UPDATE SET name=excluded.name",params![id,name]))?;
            }
            Ok(())
        })).await?;
    }
    let (complete, page, generation) = disk(store, |s| {
        s.read(|db| {
            Ok((
                state(db, "inventoryListed")? == "true",
                state(db, "page")?,
                state(db, "generation")?.parse::<i64>().unwrap_or(1),
            ))
        })
    })
    .await?;
    if !complete {
        let response = gmail
            .replica_call(account, "inventory", &json!({"pageToken":page}))
            .await?;
        disk(store, move |s| {
            apply_inventory(s, &response, &page, generation)
        })
        .await?;
    }
    let job = disk(store,|s|s.read(|db| {
        sql(db.query_row("SELECT id,kind,generation FROM jobs WHERE retry_at<=?1 ORDER BY priority DESC,rowid LIMIT 1",
            [chrono::Utc::now().timestamp_millis()],|r|Ok((r.get::<_,String>(0)?,r.get::<_,String>(1)?,r.get::<_,i64>(2)?))).optional())
    })).await?;
    let Some((id, kind, generation)) = job else {
        return Ok(false);
    };
    let gate = store.fetch_gate(&id)?;
    let _guard = gate.lock().await;
    let pending = id.clone();
    if !disk(store, move |s| {
        s.read(|db| {
            sql(db.query_row(
                "SELECT EXISTS(SELECT 1 FROM jobs WHERE id=?1)",
                [pending],
                |r| r.get::<_, bool>(0),
            ))
        })
    })
    .await?
    {
        return Ok(true);
    }
    if disk(store, |s| {
        crate::platform::private_fs::available_bytes(s.directory())
    })
    .await?
        < 1024 * 1024 * 1024
    {
        return Err("local_disk_low");
    }
    let answer = if kind == "metadata" {
        match gmail
            .replica_call(account, "minimal", &json!({"id":id}))
            .await
        {
            Ok(resource) => disk(store, move |s| s.metadata(&resource)).await,
            Err(error) => Err(error),
        }
    } else {
        let cached = crate::cache::resource::read(account, &id)
            .await
            .ok()
            .flatten();
        let resource = match cached {
            Some(v) => Ok(v),
            None => {
                gmail
                    .replica_call(account, "content", &json!({"id":id}))
                    .await
            }
        };
        match resource {
            Ok(mut resource) => match hydrate_text(gmail, account, &id, &mut resource, false).await
            {
                Ok(()) => disk(store, move |s| s.put(&resource, generation)).await,
                Err(e) => Err(e),
            },
            Err(error) => Err(error),
        }
    };
    match answer {
        Ok(()) => (),
        Err("gmail_not_found") => {
            disk(store, move |s| s.delete(&id)).await?;
        }
        Err(error) => {
            disk(store, move |s| {
                s.write(|db| {
                    sql(db.execute(
                        "UPDATE jobs SET error=?2,retry_at=?3 WHERE id=?1",
                        params![id, error, chrono::Utc::now().timestamp_millis() + 60_000],
                    ))?;
                    Ok(())
                })
            })
            .await?;
            return Err(error);
        }
    }
    Ok(true)
}
pub(super) fn restart_inventory(store: &Store) -> Result<()> {
    store.write(|db| {
        let generation = state(db, "generation")?.parse::<u64>().unwrap_or(0) + 1;
        set_state(db, "generation", &generation.to_string())?;
        set_state(db, "history", "")?;
        set_state(db, "historyPage", "")?;
        sql(db.execute("DELETE FROM history_pages", []))?;
        sql(db.execute("DELETE FROM inventory_pages", []))?;
        set_state(db, "page", "")?;
        set_state(db, "inventoryListed", "false")?;
        set_state(db, "inventoryComplete", "false")
    })
}
pub(super) fn apply_inventory(
    store: &Store,
    response: &Value,
    page: &str,
    generation: i64,
) -> Result<()> {
    if response
        .get("nextPageToken")
        .is_some_and(|token| !token.is_string())
    {
        return Err("gmail_invalid_response");
    }
    let next = response["nextPageToken"].as_str().unwrap_or("");
    if !next.is_empty() && next == page {
        return Err("gmail_invalid_response");
    }
    if !response["messages"].is_array()
        && !(response["messages"].is_null()
            && response["resultSizeEstimate"] == 0
            && next.is_empty())
    {
        return Err("gmail_invalid_response");
    }
    store.write(|db| {
        if !next.is_empty()
            && sql(db.execute(
                "INSERT OR IGNORE INTO inventory_pages VALUES(?1,?2)",
                params![generation, next],
            ))? == 0
        {
            return Err("gmail_invalid_response");
        }
        for message in response["messages"].as_array().into_iter().flatten() {
            let id = valid_id(&message["id"])?;
            let found = sql(db.execute(
                "UPDATE messages SET generation=?2 WHERE id=?1",
                params![id, generation],
            ))?;
            if found == 0 {
                sql(db.execute(
                    "INSERT INTO jobs(id,generation) VALUES(?1,?2) ON CONFLICT(id) DO UPDATE SET generation=excluded.generation",
                    params![id, generation],
                ))?;
            }
        }
        set_state(db, "page", next)?;
        if next.is_empty() {
            set_state(db, "inventoryListed", "true")?;
        }
        Ok(())
    })
}
async fn changes(
    store: &Arc<Store>,
    gmail: &gmail::Session,
    account: &str,
    history: &str,
) -> Result<()> {
    let page = disk(store, |s| s.read(|db| state(db, "historyPage"))).await?;
    let response = gmail
        .replica_call(
            account,
            "history",
            &json!({"historyId":history,"pageToken":page}),
        )
        .await?;
    disk(store, move |s| apply_history(s, &response, &page)).await
}
pub(super) fn apply_history(store: &Store, response: &Value, page: &str) -> Result<()> {
    if !response.is_object()
        || response
            .get("nextPageToken")
            .is_some_and(|v| !v.is_string())
    {
        return Err("gmail_invalid_response");
    }
    let next = response["nextPageToken"].as_str().unwrap_or("").to_owned();
    if !next.is_empty() && next == page {
        return Err("gmail_invalid_response");
    }
    let checkpoint = valid_id(&response["historyId"])?.to_owned();
    store.write(|db| {
        let generation = state(db,"generation")?.parse::<i64>().unwrap_or(1);
        if response.get("history").is_some_and(|v|!v.is_array()) {return Err("gmail_invalid_response");}
        if !next.is_empty() && sql(db.execute("INSERT OR IGNORE INTO history_pages VALUES(?1)",[&next]))?==0 {return Err("gmail_invalid_response");}
        for event in response["history"].as_array().into_iter().flatten() {
            if !event.is_object() {return Err("gmail_invalid_response");}
            for field in ["messagesAdded","messagesDeleted","labelsAdded","labelsRemoved"] {
                if event.get(field).is_some_and(|v|!v.is_array()) {return Err("gmail_invalid_response");}
            }
            for added in event["messagesAdded"].as_array().into_iter().flatten() {
                let id = valid_id(&added["message"]["id"])?;
                sql(db.execute("INSERT INTO jobs(id,priority,generation) VALUES(?1,1000,?2) ON CONFLICT(id) DO UPDATE SET priority=1000,generation=excluded.generation",params![id,generation]))?;
                sql(db.execute("UPDATE messages SET generation=?2 WHERE id=?1",params![id,generation]))?;
            }
            for kind in ["labelsAdded","labelsRemoved"] {
                for changed in event[kind].as_array().into_iter().flatten() {
                    let id = valid_id(&changed["message"]["id"])?;
                    sql(db.execute("INSERT INTO jobs(id,kind,priority,generation) VALUES(?1,CASE WHEN EXISTS(SELECT 1 FROM messages WHERE id=?1) THEN 'metadata' ELSE 'content' END,100,?2) ON CONFLICT(id) DO UPDATE SET priority=max(priority,100),retry_at=0",params![id,generation]))?;
                }
            }
            for removed in event["messagesDeleted"].as_array().into_iter().flatten() {
                delete(db,valid_id(&removed["message"]["id"])?)?;
            }
        }
        set_state(db,"historyPage",&next)?;
        if next.is_empty() {
            set_state(db,"history",&checkpoint)?;
            sql(db.execute("DELETE FROM history_pages",[]))?;
            if state(db,"inventoryListed")?=="true" && state(db,"inventoryComplete")?!="true" {
                let mut statement=sql(db.prepare("SELECT id FROM messages WHERE generation<?1"))?;
                let missing=sql(sql(statement.query_map([generation],|r|r.get::<_,String>(0)))?.collect::<rusqlite::Result<Vec<_>>>())?;
                for id in missing {delete(db,&id)?;}
                set_state(db,"inventoryComplete","true")?;
                sql(db.execute("DELETE FROM inventory_pages",[]))?;
            }
        }
        Ok(())
    })
}
pub(super) async fn hydrate_text(
    gmail: &gmail::Session,
    account: &str,
    id: &str,
    resource: &mut Value,
    foreground: bool,
) -> Result<()> {
    let mut pending = vec!["/payload".to_owned()];
    while let Some(path) = pending.pop() {
        let part = resource.pointer(&path).ok_or("gmail_invalid_response")?;
        for index in 0..part["parts"].as_array().map_or(0, Vec::len) {
            pending.push(format!("{path}/parts/{index}"));
        }
        if super::content::is_attachment(part)
            || !matches!(part["mimeType"].as_str(), Some("text/plain" | "text/html"))
            || part["body"]["data"].is_string()
        {
            continue;
        }
        let Some(attachment) = part["body"]["attachmentId"].as_str() else {
            continue;
        };
        let answer = if foreground {
            gmail
                .call(
                    "gmail.attachment",
                    &json!({"accountId":account,"messageId":id,"attachmentId":attachment}),
                )
                .await?
        } else {
            gmail
                .replica_call(
                    account,
                    "attachment",
                    &json!({"id":id,"attachmentId":attachment}),
                )
                .await?
        };
        let data = answer["data"].as_str().ok_or("gmail_invalid_response")?;
        resource
            .pointer_mut(&path)
            .ok_or("gmail_invalid_response")?["body"]["data"] = json!(data);
    }
    Ok(())
}
async fn deliver_edit(store: &Arc<Store>, gmail: &gmail::Session, account: &str) -> Result<bool> {
    let edit = disk(store,|s|s.read(|db| {
        sql(db.query_row("SELECT id FROM edits WHERE state IN ('queued','sending') ORDER BY sequence LIMIT 1",[],|r|r.get::<_,String>(0)).optional())
    })).await?;
    let Some(id) = edit else { return Ok(false) };
    let gate = store.fetch_gate(&id)?;
    let _guard = gate.lock().await;
    let before = match gmail
        .replica_call(account, "minimal", &json!({"id":id}))
        .await
    {
        Err("gmail_not_found") => {
            disk(store, move |s| s.delete(&id)).await?;
            return Ok(true);
        }
        answer => answer?,
    };
    let claim = id.clone();
    let Some((sequence, add, remove)) = disk(store, move |s| s.claim_changes(&claim)).await? else {
        return Ok(true);
    };
    let current = before["labelIds"]
        .as_array()
        .ok_or("gmail_invalid_response")?;
    let satisfied = add
        .as_array()
        .ok_or("local_storage_corrupt")?
        .iter()
        .all(|v| current.contains(v))
        && remove
            .as_array()
            .ok_or("local_storage_corrupt")?
            .iter()
            .all(|v| !current.contains(v));
    if !satisfied {
        let delivery = gmail
            .call_settled(
                "gmail.modify",
                &json!({"accountId":account,"id":id,"addLabelIds":add,"removeLabelIds":remove}),
            )
            .await;
        if let Err(error @ ("gmail_forbidden" | "invalid_params")) = delivery {
            disk(store,move|s|s.write(|db| {
                sql(db.execute("UPDATE edits SET state='conflict',error=?3 WHERE id=?1 AND sequence<=?2 AND state='sending'",params![id,sequence,error]))?;
                if sql(db.query_row("SELECT EXISTS(SELECT 1 FROM messages WHERE id=?1)",[&id],|r|r.get::<_,bool>(0)))? {
                    replace_labels(db,&id,&before["labelIds"])?;
                }
                Ok(())
            })).await?;
            return Ok(true);
        }
        delivery?;
    }
    let after = if satisfied {
        before
    } else {
        gmail
            .replica_call(account, "minimal", &json!({"id":id}))
            .await?
    };
    let current = after["labelIds"]
        .as_array()
        .ok_or("gmail_invalid_response")?;
    if !add
        .as_array()
        .ok_or("local_storage_corrupt")?
        .iter()
        .all(|v| current.contains(v))
        || !remove
            .as_array()
            .ok_or("local_storage_corrupt")?
            .iter()
            .all(|v| !current.contains(v))
    {
        return Err("local_edit_not_confirmed");
    }
    disk(store,move|s|s.write(|db| {
        sql(db.execute("UPDATE messages SET server_labels=?2 WHERE id=?1",params![id,after["labelIds"].to_string()]))?;
        sql(db.execute("UPDATE edits SET state='done',error='' WHERE id=?1 AND sequence<=?2 AND state='sending'",params![id,sequence]))?;
        if sql(db.query_row("SELECT EXISTS(SELECT 1 FROM messages WHERE id=?1)",[&id],|r|r.get::<_,bool>(0)))? {replace_labels(db,&id,&after["labelIds"])?;}
        Ok(())
    })).await?;
    Ok(true)
}
