//! When a Point still in the Inbox is written again because something it was read against has
//! changed. Each Point keeps a `contextKey` taken when it was written: a hash of the newest message
//! the owner had sent in the email's thread, and of the owner's Atlas todos linked to the email (by
//! its thread or its Gmail id) with their status. A check compares that with the present at most
//! once a minute per account and marks a Point whose key no longer matches (`contextChanged`); the
//! writer then takes it like a Point written under earlier rules, keeping the old text until the new
//! one is ready.
//!
//! Invariant: only those two changes count, so the cost stays bounded. Any other change to the
//! todos, the calendar or other mail never marks a Point, a list of todos that cannot be read is
//! never a change, and only mail still in the Inbox is checked. Keys hold hashes, never text.
use super::{now, store};
use serde_json::{Value, json};
use std::collections::HashMap;

/// How often one account's Points are checked.
const EVERY: i64 = 60_000;

pub(super) fn hash(text: &str) -> String {
    use sha2::{Digest, Sha256};
    Sha256::digest(text.as_bytes()).iter().take(8).map(|byte| format!("{byte:02x}")).collect()
}

/// The key of one email: the newest message the owner sent in its thread (if any), and its linked
/// todos when the owner's todos are known.
fn key(sent: Option<&str>, todos: Option<&[String]>) -> Value {
    let mut key = json!({"sent": hash(sent.unwrap_or(""))});
    if let Some(todos) = todos {
        key["todos"] = json!(hash(&todos.join("\n")));
    }
    key
}

/// The todos linked to an email, by its thread or its own Gmail id, sorted and once each.
fn linked(links: &Value, id: &str, thread: &str) -> Vec<String> {
    let mut todos: Vec<String> = [format!("t:{thread}"), format!("g:{id}")]
        .iter()
        .flat_map(|name| links[name.as_str()].as_array().cloned().unwrap_or_default())
        .filter_map(|todo| todo.as_str().map(str::to_owned))
        .collect();
    todos.sort();
    todos.dedup();
    todos
}

/// The keys of the present for `ids` in the account; an email the local copy does not have has none.
pub(crate) async fn keys(account: &str, ids: &[String], local_mail: &crate::local_mail::LocalMail) -> HashMap<String, Value> {
    let Ok(rows) = local_mail.replies(account, ids.to_vec()).await else {
        return HashMap::new();
    };
    let links = super::todos::links(now());
    rows.into_iter()
        .map(|(id, thread, sent)| {
            let todos = links.as_ref().map(|links| linked(links, &id, &thread));
            let key = key(sent.as_deref(), todos.as_deref());
            (id, key)
        })
        .collect()
}

/// Whether the present differs from what a Point was written against. Todos count only when they
/// are known now; a Point written while they were not known changes only if the email now has one.
fn changed(written: &Value, present: &Value) -> bool {
    let Some(sent) = written["sent"].as_str() else {
        return false;
    };
    if present["sent"].as_str().is_some_and(|now| now != sent) {
        return true;
    }
    match (written["todos"].as_str(), present["todos"].as_str()) {
        (Some(then), Some(now)) => then != now,
        (None, Some(now)) => now != hash(""),
        (_, None) => false,
    }
}

/// Marks the current Points whose key no longer matches the present; returns how many.
fn mark(saved: &mut Value, present: &HashMap<String, Value>, at: i64) -> usize {
    let mut marked = 0;
    for (id, now) in present {
        let Some(row) = saved.get_mut(id.as_str()) else { continue };
        if super::overview_current(row, at) && row["contextChanged"] != true && changed(&row["contextKey"], now) {
            row["contextChanged"] = json!(true);
            marked += 1;
        }
    }
    marked
}

static CHECKED: std::sync::Mutex<Option<HashMap<String, i64>>> = std::sync::Mutex::new(None);

/// Marks the account's Inbox Points whose thread or linked todos changed since they were written;
/// at most once every EVERY per account.
pub(crate) async fn check(account: &str, local_mail: &crate::local_mail::LocalMail) -> Result<usize, &'static str> {
    let at = now();
    {
        let mut checked = CHECKED.lock().map_err(|_| "inbox_storage_invalid")?;
        let checked = checked.get_or_insert_with(HashMap::new);
        if checked.get(account).is_some_and(|last| *last <= at && at - *last < EVERY) {
            return Ok(0);
        }
        checked.insert(account.to_owned(), at);
    }
    check_now(account, local_mail).await
}

/// The check itself, without waiting for its minute.
pub(super) async fn check_now(account: &str, local_mail: &crate::local_mail::LocalMail) -> Result<usize, &'static str> {
    let at = now();
    let name = store::key(&["overviews", account]);
    let Some(saved) = store::read(&name)? else {
        return Ok(0);
    };
    let inbox: std::collections::HashSet<String> = local_mail.overview_candidates(account).await?.into_iter().collect();
    let ids: Vec<String> = saved
        .as_object()
        .ok_or("inbox_storage_invalid")?
        .iter()
        .filter(|(id, row)| inbox.contains(*id) && row["contextKey"].is_object() && row["contextChanged"] != true && super::overview_current(row, at))
        .map(|(id, _)| id.clone())
        .collect();
    if ids.is_empty() {
        return Ok(0);
    }
    let present = keys(account, &ids, local_mail).await;
    if present.is_empty() {
        return Ok(0);
    }
    store::update(&name, |saved| Ok(mark(saved, &present, now())))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn todos(list: &[&str]) -> Vec<String> {
        list.iter().map(|todo| todo.to_string()).collect()
    }

    #[test]
    fn a_reply_or_a_linked_todo_changes_the_key_and_nothing_else_does() {
        let links = json!({"t:th1":["7:open"],"g:m1":["9:open","7:open"],"t:other":["8:open"]});
        let written = key(None, Some(&linked(&links, "m1", "th1")));
        assert_eq!(linked(&links, "m1", "th1"), todos(&["7:open", "9:open"]), "by thread and by Gmail id, once each");
        assert!(!changed(&written, &key(None, Some(&linked(&links, "m1", "th1")))));

        let replied = key(Some("sent-2"), Some(&linked(&links, "m1", "th1")));
        assert!(changed(&written, &replied), "the owner answered in the thread");

        let mut done = links.clone();
        done["t:th1"] = json!(["7:done"]);
        assert!(changed(&written, &key(None, Some(&linked(&done, "m1", "th1")))), "a linked todo was done");

        let mut unrelated = links.clone();
        unrelated["t:other"] = json!(["8:done"]);
        unrelated["t:new"] = json!(["10:open"]);
        assert!(!changed(&written, &key(None, Some(&linked(&unrelated, "m1", "th1")))), "another email's todos never count");
    }

    #[test]
    fn todos_that_cannot_be_read_are_never_a_change() {
        let known = key(Some("s"), Some(&todos(&["7:open"])));
        assert!(!changed(&known, &key(Some("s"), None)), "Atlas not read for a day, or disconnected");
        let unknown = key(Some("s"), None);
        assert!(!changed(&unknown, &key(Some("s"), Some(&[]))), "connected later, nothing linked");
        assert!(changed(&unknown, &key(Some("s"), Some(&todos(&["7:open"])))), "connected later, and the email has a todo");
        assert!(!changed(&json!(null), &key(Some("s"), None)), "a Point written before keys is never marked");
        assert!(!key(Some("an id"), Some(&todos(&["7:open"]))).to_string().contains("an id"), "keys hold hashes only");
    }

    #[test]
    fn only_current_points_whose_key_changed_are_marked() {
        let at = 1_000_000;
        let point = |key: Value| json!({"state":"ready","text":"Maeve needs your receipts by Sunday.","version":2,"promptRevision":super::super::POINT_REVISION,"updated":at - 10,"expiresAt":0,"contextKey":key});
        let then = key(None, Some(&todos(&["7:open"])));
        let now = key(None, Some(&todos(&["7:done"])));
        let mut saved = json!({
            "same": point(then.clone()),
            "moved": point(then.clone()),
            "expired": {"state":"ready","text":"Old.","version":2,"expiresAt":at - 1,"contextKey":then.clone()},
            "failed": {"state":"failed","version":2,"updated":at},
        });
        let present = HashMap::from([
            ("same".to_owned(), then.clone()),
            ("moved".to_owned(), now.clone()),
            ("expired".to_owned(), now.clone()),
            ("failed".to_owned(), now.clone()),
        ]);
        assert_eq!(mark(&mut saved, &present, at), 1);
        assert_eq!(saved["moved"]["contextChanged"], true);
        assert!(saved["same"].get("contextChanged").is_none());
        assert!(saved["expired"].get("contextChanged").is_none(), "an expired Point is written again anyway");
        assert!(saved["failed"].get("contextChanged").is_none());
        assert_eq!(mark(&mut saved, &present, at), 0, "marked once");
    }
}
