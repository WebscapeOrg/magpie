use super::{fields, storage, text};
use serde_json::{Value, json};
use storage::Result;

const FILE: &str = "notification-history.json";
const LIMIT: usize = 16 * 1024 * 1024;

pub fn retain(pending: &Value) -> Result<()> {
    let alert = &pending["payload"]["aps"]["alert"];
    if !alert.is_object() {
        return Ok(());
    }
    let id = text(pending, "collapse", 64)?;
    let mut history = storage::read_bounded(FILE, LIMIT)?;
    if history.get(id).is_some() {
        return Ok(());
    }
    history[id] = json!({"id":id,"title":alert["title"],"body":alert["body"],"sentAt":crate::inbox::now(),"link":"magpie://inbox","unread":true,"accounts":pending["historyAccounts"]});
    storage::write_bounded(FILE, &history, LIMIT)
}

fn visible(row: &Value, accounts: &[Value]) -> bool {
    row["accounts"].as_array().is_some_and(|ids| {
        !ids.is_empty()
            && ids
                .iter()
                .all(|id| accounts.iter().any(|account| account["id"] == *id))
    })
}

fn response(history: &mut Value, p: &Value, accounts: &[Value]) -> Result<Value> {
    fields(p, &["id", "read", "after"])?;
    if p.get("id").is_some() {
        if p.get("after").is_some() {
            return Err("phone_invalid_request");
        }
        let id = text(p, "id", 64)?;
        let mark = match p.get("read") {
            None => false,
            Some(value) => value.as_bool().ok_or("phone_invalid_request")?,
        };
        let row = history
            .get_mut(id)
            .filter(|row| visible(row, accounts))
            .ok_or("notification_not_found")?;
        if mark {
            row["unread"] = json!(false);
            row["readAt"] = json!(crate::inbox::now());
        }
        return Ok(json!({"notification":row}));
    }
    if p.get("read").is_some() {
        return Err("phone_invalid_request");
    }
    let mut rows: Vec<_> = history
        .as_object()
        .ok_or("phone_storage_invalid")?
        .values()
        .filter(|row| visible(row, accounts))
        .cloned()
        .collect();
    rows.sort_by(|a, b| {
        b["sentAt"]
            .as_i64()
            .cmp(&a["sentAt"].as_i64())
            .then_with(|| b["id"].as_str().cmp(&a["id"].as_str()))
    });
    let start = if p.get("after").is_some() {
        let after = text(p, "after", 64)?;
        rows.iter()
            .position(|row| row["id"] == after)
            .ok_or("notification_not_found")?
            + 1
    } else {
        0
    };
    let page: Vec<_> = rows.iter().skip(start).take(200).cloned().collect();
    let next = if rows.len() > start + page.len() {
        page.last()
            .map(|row| row["id"].clone())
            .unwrap_or(Value::Null)
    } else {
        Value::Null
    };
    Ok(json!({"notifications":page,"empty":"No notifications yet.","next":next}))
}

pub fn request(p: &Value, accounts: &[Value]) -> Result<Value> {
    let mut history = storage::read_bounded(FILE, LIMIT)?;
    let answer = response(&mut history, p, accounts)?;
    if p["read"] == true {
        storage::write_bounded(FILE, &history, LIMIT)?;
    }
    Ok(answer)
}

#[cfg(test)]
mod tests {
    use super::*;
    fn history() -> Value {
        json!({"a":{"id":"a","accounts":["a@example.test"],"sentAt":1,"unread":true},"b":{"id":"b","accounts":["b@example.test"],"sentAt":2,"unread":true},"both":{"id":"both","accounts":["a@example.test","b@example.test"],"sentAt":3,"unread":true}})
    }
    #[test]
    fn unauthorized_reads_have_no_mutation_and_no_disclosure() {
        let mut history = history();
        let before = history.clone();
        let accounts = vec![json!({"id":"a@example.test"})];
        assert_eq!(
            response(&mut history, &json!({"id":"both","read":true}), &accounts),
            Err("notification_not_found")
        );
        assert_eq!(
            response(&mut history, &json!({"id":"b","read":true}), &accounts),
            Err("notification_not_found")
        );
        assert_eq!(history, before);
        let answer = response(&mut history, &json!({}), &accounts).unwrap();
        assert_eq!(answer["notifications"].as_array().unwrap().len(), 1);
        assert_eq!(answer["notifications"][0]["id"], "a");
        assert!(
            response(&mut history, &json!({}), &[]).unwrap()["notifications"]
                .as_array()
                .unwrap()
                .is_empty()
        );
    }
    #[test]
    fn reading_is_shared_and_pagination_is_newest_first() {
        let mut history = history();
        let accounts = vec![
            json!({"id":"a@example.test"}),
            json!({"id":"b@example.test"}),
        ];
        assert_eq!(
            response(&mut history, &json!({}), &accounts).unwrap()["notifications"][0]["id"],
            "both"
        );
        response(&mut history, &json!({"id":"both","read":true}), &accounts).unwrap();
        assert_eq!(
            response(&mut history, &json!({"id":"both"}), &accounts).unwrap()["notification"]["unread"],
            false
        );
        assert_eq!(
            response(&mut history, &json!({"after":"both"}), &accounts).unwrap()["notifications"]
                [0]["id"],
            "b"
        );
    }
}
