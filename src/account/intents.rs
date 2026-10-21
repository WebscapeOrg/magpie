//! Ordered declarative optimistic edits. A late refusal removes only its own effects.
use super::model;
use serde_json::{Value, json};
use std::collections::{HashMap, HashSet};
use std::sync::Mutex;
type Result<T> = std::result::Result<T, &'static str>;
const MAX_CONTEXTS: usize = 32;
const MAX_EDITS: usize = 128;
const MAX_VIEW: usize = 4 * 1024 * 1024;
#[derive(Default)]
pub struct IntentStore {
    state: Mutex<State>,
}
#[derive(Default)]
struct State {
    contexts: HashMap<(String, String), Context>,
    generations: HashMap<String, u64>,
    serial: u64,
}
#[derive(Clone)]
struct Context {
    generation: u64,
    base: Value,
    view: Value,
    edits: Vec<Edit>,
    bytes: usize,
    view_bytes: usize,
}
impl Context {
    fn replace_view(&mut self, view: &Value) -> Result<()> {
        let bytes = serde_json::to_vec(view)
            .map_err(|_| "intent_view_invalid")?
            .len();
        if bytes > MAX_VIEW {
            return Err("intent_limit");
        }
        self.bytes = self.bytes.saturating_sub(self.view_bytes) + bytes;
        self.view_bytes = bytes;
        self.view = view.clone();
        Ok(())
    }
}

impl State {
    fn check_context_bytes(&self, key: &(String, String), bytes: usize) -> Result<()> {
        let retained: usize = self
            .contexts
            .iter()
            .filter(|(existing, _)| *existing != key)
            .map(|(_, context)| context.bytes)
            .sum();
        if retained.saturating_add(bytes) > 32 * 1024 * 1024 {
            return Err("intent_limit");
        }
        Ok(())
    }
}

#[derive(Clone)]
struct Edit {
    token: u64,
    descriptor: Value,
    items: Vec<Item>,
    settled: bool,
    bytes: usize,
}
#[derive(Clone)]
struct Item {
    id: String,
    row: String,
    failed: bool,
    targets: Vec<Value>,
}
fn field(params: &Value, key: &str) -> Result<String> {
    let value = params[key].as_str().ok_or("intent_invalid")?;
    if value.is_empty() || value.len() > 8192 || value.contains('\0') {
        return Err("intent_invalid");
    }
    Ok(value.to_owned())
}
fn list(v: &Value) -> Vec<Value> {
    v.as_array().cloned().unwrap_or_default()
}
fn id(v: &Value) -> &str {
    v.as_str().unwrap_or("")
}
fn invoke(operation: &str, args: Value) -> Result<Value> {
    model::apply(&json!({"operation":operation,"args":args}))
}
fn validate_view(view: &Value) -> Result<()> {
    if !view.is_object() || !view["messages"].is_array() || !view["previewMessages"].is_array() {
        return Err("intent_view_invalid");
    }
    if serde_json::to_vec(view)
        .map_err(|_| "intent_view_invalid")?
        .len()
        > MAX_VIEW
    {
        return Err("intent_limit");
    }
    Ok(())
}
fn descriptor(p: &Value) -> Value {
    let mut out = json!({});
    for k in [
        "action",
        "quiet",
        "memberOnly",
        "oneMessage",
        "mailboxKey",
        "rawQuery",
        "hasLabels",
        "sourceLabelId",
        "capabilities",
        "opaqueQuery",
    ] {
        out[k] = p[k].clone();
    }
    out["readerThread"] = p["view"]["selectedThread"].clone();
    if p["allRead"] == true {
        out["action"] = json!("markRead");
    }
    out
}
fn same_descriptor(first: &Value, second: &Value) -> bool {
    let mut first = first.clone();
    let mut second = second.clone();
    first.as_object_mut().unwrap().remove("readerThread");
    second.as_object_mut().unwrap().remove("readerThread");
    first == second
}
fn selected(view: &mut Value, current: &Value) {
    if current.get("selectedId").is_none() {
        return;
    }
    let wanted = current["selectedId"].clone();
    if view["selectedId"] == wanted {
        return;
    }
    view["selectedId"] = wanted.clone();
    view["selectedMessage"] = if id(&wanted).is_empty() {
        Value::Null
    } else {
        let found = invoke(
            "messageById",
            json!([view["messages"], view["previewMessages"], wanted]),
        )
        .unwrap_or(Value::Null);
        let summary = if found.is_object() {
            found
        } else {
            view["memberSummaries"]
                .get(id(&wanted))
                .cloned()
                .unwrap_or(Value::Null)
        };
        let mut detail = current["selectedMessage"].clone();
        if !detail.is_object() {
            detail = summary.clone();
        }
        if detail.is_object() && summary.is_object() {
            for key in [
                "labelIds", "unread", "starred", "inInbox", "inTrash", "inSpam", "isSent",
                "isDraft", "thread",
            ] {
                if let Some(value) = summary.get(key) {
                    detail[key] = value.clone();
                }
            }
        }
        detail
    };
}
fn apply_one(view: &mut Value, desc: &Value, message: &str) -> Result<Value> {
    let mut p = desc.clone();
    p["operation"] = json!("action");
    p["messageId"] = json!(message);
    let outcome = match model::action_view(&p, view, true) {
        Ok(v) => v,
        Err("model_message_missing") => {
            let change = model::changes(id(&desc["action"]), id(&desc["sourceLabelId"]));
            if change.is_null()
                || !list(&desc["readerThread"]["memberIds"]).contains(&json!(message))
            {
                return Err("model_message_missing");
            }
            if let Some(held) = view["memberSummaries"].get(message).cloned() {
                view["memberSummaries"][message] =
                    model::label_change(&held, id(&desc["action"]), "", &Value::Null);
            }
            if view["selectedId"] == message && view["selectedMessage"].is_object() {
                view["selectedMessage"] = model::label_change(
                    &view["selectedMessage"],
                    id(&desc["action"]),
                    "",
                    &Value::Null,
                );
            }
            return Ok(
                json!({"rowId":message,"targets":[message],"change":change,"removed":false,"survives":true,"detached":true}),
            );
        }
        Err(error) => return Err(error),
    };
    if outcome["refused"] == true {
        return Ok(outcome);
    }
    let selected_id = view["selectedId"].clone();
    let before = &outcome["before"];
    let row = id(&outcome["rowId"]);
    let member_existed = view["memberSummaries"].get(row).is_some();
    for (key, removed) in [
        ("messages", outcome["removed"] == true),
        ("previewMessages", outcome["updated"]["unread"] != true),
    ] {
        let Some(list) = view[key].as_array_mut() else {
            continue;
        };
        if removed {
            list.retain(|entry| entry["id"] != outcome["rowId"]);
            continue;
        }
        for entry in list
            .iter_mut()
            .filter(|entry| entry["id"] == outcome["rowId"])
        {
            *entry = outcome["updated"].clone();
        }
    }
    if !view["memberSummaries"].is_object() {
        view["memberSummaries"] = json!({});
    }
    if let Some(updates) = outcome["memberSummaries"].as_object() {
        for (key, value) in updates {
            view["memberSummaries"][key] = value.clone();
        }
    }
    if member_existed {
        view["memberSummaries"][row] = outcome["updated"].clone();
    }
    let action = id(&desc["action"]);
    let before_unread = before["unread"] == true;
    let unread = outcome["updated"]["unread"] == true;
    let count = view["inboxUnread"].as_u64().unwrap_or(0);
    if action == "markRead" && before_unread && !unread {
        view["inboxUnread"] = json!(count.saturating_sub(1));
    }
    if action == "markUnread" && !before_unread && unread {
        view["inboxUnread"] = json!(count.saturating_add(1));
    }
    let holds = invoke("rowHoldsMember", json!([before, selected_id]))? == true;
    if holds {
        if outcome["removed"] == true {
            view["selectedId"] = json!("");
            view["selectedMessage"] = Value::Null;
        } else if selected_id == outcome["rowId"] && view["selectedMessage"].is_object() {
            view["selectedMessage"] = model::label_change(
                &view["selectedMessage"],
                action,
                id(&desc["sourceLabelId"]),
                &outcome["updated"]["thread"],
            );
        } else if list(&outcome["targets"]).contains(&selected_id)
            && view["selectedMessage"].is_object()
        {
            view["selectedMessage"] = model::label_change(
                &view["selectedMessage"],
                action,
                id(&desc["sourceLabelId"]),
                &Value::Null,
            );
        }
    }
    Ok(outcome)
}
fn replay(context: &Context) -> Result<Value> {
    let mut view = context.base.clone();
    for edit in &context.edits {
        for item in edit.items.iter().filter(|i| !i.failed) {
            match apply_one(&mut view, &edit.descriptor, &item.id) {
                Ok(_) => (),
                Err("model_message_missing") => (),
                Err(error) => return Err(error),
            }
        }
    }
    Ok(view)
}
impl IntentStore {
    pub fn call(&self, params: &Value) -> Result<Value> {
        let account = field(params, "accountId")?;
        let operation = id(&params["operation"]);
        let mut state = self.state.lock().map_err(|_| "intent_unavailable")?;
        if operation == "reset" {
            if !state.generations.contains_key(&account) && state.generations.len() >= 1024 {
                return Err("intent_limit");
            }
            let generation = state
                .generations
                .get(&account)
                .copied()
                .unwrap_or(0)
                .checked_add(1)
                .ok_or("intent_limit")?;
            state
                .contexts
                .retain(|(account_id, _), _| account_id != &account);
            state.generations.insert(account, generation);
            return Ok(json!({"generation":generation,"cleared":true}));
        }
        if operation == "clear" {
            let generation = state.generations.get(&account).copied().unwrap_or(0);
            if params["generation"].as_u64().ok_or("intent_invalid")? != generation {
                return Err("intent_stale");
            }
            state.contexts.retain(|(account_id, query_key), _| {
                account_id != &account
                    || params["query"]
                        .as_str()
                        .is_some_and(|wanted| wanted != query_key)
            });
            return Ok(json!({"cleared":true,"generation":generation}));
        }
        let query = field(params, "query")?;
        let key = (account.clone(), query);
        let generation = params["generation"].as_u64().ok_or("intent_invalid")?;
        let prior = state.generations.get(&account).copied().unwrap_or(0);
        if state.generations.contains_key(&account) && generation != prior {
            return Err("intent_stale");
        }
        if operation == "coalesce" {
            let newer = params["token"].as_u64().ok_or("intent_invalid")?;
            let older = params["intoToken"].as_u64().ok_or("intent_invalid")?;
            let mut context = state.contexts.get(&key).ok_or("intent_unknown")?.clone();
            if context.generation != generation {
                return Err("intent_stale");
            }
            let old = context
                .edits
                .iter()
                .position(|edit| edit.token == older)
                .ok_or("intent_unknown")?;
            let new = context
                .edits
                .iter()
                .position(|edit| edit.token == newer)
                .ok_or("intent_unknown")?;
            let ids: Vec<_> = context.edits[old]
                .items
                .iter()
                .map(|item| item.id.as_str())
                .collect();
            if old >= new
                || context.edits[old].settled
                || context.edits[new].settled
                || !same_descriptor(
                    &context.edits[old].descriptor,
                    &context.edits[new].descriptor,
                )
                || ids
                    != context.edits[new]
                        .items
                        .iter()
                        .map(|item| item.id.as_str())
                        .collect::<Vec<_>>()
                || context.edits[old + 1..new].iter().any(|edit| {
                    edit.items
                        .iter()
                        .any(|item| ids.contains(&item.id.as_str()))
                })
            {
                return Err("intent_coalesce_invalid");
            }
            let removed = context.edits.remove(new);
            context.bytes = context.bytes.saturating_sub(removed.bytes);
            let mut view = replay(&context)?;
            selected(&mut view, &context.view);
            context.replace_view(&view)?;
            state.check_context_bytes(&key, context.bytes)?;
            state.contexts.insert(key, context);
            return Ok(json!({"view":view,"token":older,"generation":generation}));
        }
        if operation == "settle" {
            if serde_json::to_vec(&params["view"])
                .map_err(|_| "intent_view_invalid")?
                .len()
                > MAX_VIEW
            {
                return Err("intent_limit");
            }
            let token = params["token"].as_u64().ok_or("intent_invalid")?;
            let mut context = state.contexts.get(&key).ok_or("intent_unknown")?.clone();
            if context.generation != generation {
                return Err("intent_stale");
            }
            let edit = context
                .edits
                .iter_mut()
                .find(|edit| edit.token == token)
                .ok_or("intent_unknown")?;
            if edit.settled {
                return Err("intent_already_settled");
            }
            let failed = list(&params["failedIds"]);
            if failed
                .iter()
                .any(|failed_row| !edit.items.iter().any(|item| json!(item.row) == *failed_row))
            {
                return Err("intent_invalid");
            }
            edit.settled = true;
            for item in &mut edit.items {
                item.failed = failed.contains(&json!(item.row));
            }
            let targets: Vec<_> = edit
                .items
                .iter()
                .filter(|item| !item.failed)
                .flat_map(|item| item.targets.clone())
                .collect();
            let mut view = replay(&context)?;
            selected(
                &mut view,
                if params["view"].is_object() {
                    &params["view"]
                } else {
                    &context.view
                },
            );
            context.replace_view(&view)?;
            state.check_context_bytes(&key, context.bytes)?;
            // Invariant: Settled successors remain ordered until every predecessor settles.
            if context.edits.iter().all(|edit| edit.settled) {
                state.contexts.remove(&key);
            } else {
                state.contexts.insert(key, context);
            }
            return Ok(json!({"view":view,"targets":targets,"generation":generation}));
        }
        if operation != "begin" {
            return Err("intent_invalid");
        }
        validate_view(&params["view"])?;
        if !state.generations.contains_key(&account) && state.generations.len() >= 1024 {
            return Err("intent_limit");
        }
        if !state.contexts.contains_key(&key) && state.contexts.len() >= MAX_CONTEXTS {
            return Err("intent_limit");
        }
        if state
            .contexts
            .get(&key)
            .is_some_and(|context| context.edits.len() >= MAX_EDITS)
        {
            return Err("intent_limit");
        }
        let action_descriptor = descriptor(params);
        let action = id(&action_descriptor["action"]);
        let capability = model::capability(action);
        if !capability.is_empty() && action_descriptor["capabilities"][capability] != true {
            return Ok(json!({"refused":true,"capability":capability}));
        }
        if model::changes(action, id(&action_descriptor["sourceLabelId"])).is_null()
            && !matches!(action, "trash" | "untrash")
        {
            return Err("intent_invalid");
        }
        let mut ids = if params["allRead"] == true {
            list(&params["view"]["messages"])
                .into_iter()
                .filter(|row| row["unread"] == true)
                .map(|row| row["id"].clone())
                .collect()
        } else {
            list(&params["ids"])
        };
        if ids.len() > 1000
            || ids
                .iter()
                .any(|value| id(value).is_empty() || id(value).len() > 8192)
        {
            return Err("intent_invalid");
        }
        let mut seen = HashSet::new();
        ids.retain(|value| seen.insert(id(value).to_owned()));
        let context = state.contexts.get(&key);
        let mut view = context
            .map(|context| context.view.clone())
            .unwrap_or_else(|| params["view"].clone());
        let mut base = context
            .map(|context| context.base.clone())
            .unwrap_or_else(|| params["view"].clone());
        if let Some(members) = params["view"]["memberSummaries"].as_object() {
            for (key, member) in members {
                if base["memberSummaries"].get(key).is_some() {
                    continue;
                }
                if !base["memberSummaries"].is_object() {
                    base["memberSummaries"] = json!({});
                }
                if !view["memberSummaries"].is_object() {
                    view["memberSummaries"] = json!({});
                }
                base["memberSummaries"][key] = member.clone();
                view["memberSummaries"][key] = member.clone();
            }
        }
        view["selectedThread"] = params["view"]["selectedThread"].clone();
        selected(&mut view, &params["view"]);
        let mut items = Vec::new();
        let mut targets = Vec::new();
        let mut targets_of = json!({});
        let mut rows = Vec::new();
        let mut removed = Vec::new();
        let mut invalidates = action_descriptor["opaqueQuery"] == true;
        for message in ids {
            let outcome = match apply_one(&mut view, &action_descriptor, id(&message)) {
                Ok(value) => value,
                Err("model_message_missing") => continue,
                Err(error) => return Err(error),
            };
            let row = id(&outcome["rowId"]).to_owned();
            if row.is_empty() {
                continue;
            }
            if !rows.contains(&json!(row)) {
                rows.push(json!(row));
            }
            let mut own = list(&targets_of[&row]);
            for target in list(&outcome["targets"]) {
                if !own.contains(&target) {
                    own.push(target.clone());
                }
                if !targets.contains(&target) {
                    targets.push(target);
                }
            }
            targets_of[&row] = json!(own);
            if outcome["removed"] == true && !removed.contains(&json!(row)) {
                removed.push(json!(row));
            }
            invalidates |= outcome["survives"] == false;
            items.push(Item {
                id: id(&message).to_owned(),
                row,
                failed: false,
                targets: list(&outcome["targets"]),
            });
        }
        if items.is_empty() {
            return Ok(json!({"refused":true,"capability":"","targets":[],"rows":[]}));
        }
        let view_bytes = serde_json::to_vec(&view)
            .map_err(|_| "intent_view_invalid")?
            .len();
        if view_bytes > MAX_VIEW {
            return Err("intent_limit");
        }
        let edit_bytes = serde_json::to_vec(&action_descriptor)
            .map_err(|_| "intent_invalid")?
            .len()
            + items
                .iter()
                .map(|item| {
                    item.id.len()
                        + item.row.len()
                        + serde_json::to_vec(&item.targets).map_or(MAX_VIEW, |value| value.len())
                })
                .sum::<usize>();
        let base_bytes = serde_json::to_vec(&base)
            .map_err(|_| "intent_view_invalid")?
            .len();
        if base_bytes > MAX_VIEW {
            return Err("intent_limit");
        }
        let context_bytes = state
            .contexts
            .get(&key)
            .map(|context| context.edits.iter().map(|edit| edit.bytes).sum::<usize>() + base_bytes)
            .unwrap_or(base_bytes)
            + view_bytes
            + edit_bytes;
        state.check_context_bytes(&key, context_bytes)?;
        state.serial = state.serial.checked_add(1).ok_or("intent_limit")?;
        state.generations.insert(account, generation);
        let token = state.serial;
        let context = state.contexts.entry(key).or_insert_with(|| Context {
            generation,
            base: params["view"].clone(),
            view: params["view"].clone(),
            edits: Vec::new(),
            bytes: 0,
            view_bytes: 0,
        });
        context.base = base;
        context.view = view.clone();
        context.bytes = context_bytes;
        context.view_bytes = view_bytes;
        context.edits.push(Edit {
            token,
            descriptor: action_descriptor.clone(),
            items,
            settled: false,
            bytes: edit_bytes,
        });
        Ok(
            json!({"token":token,"generation":generation,"view":view,"targets":targets,"targetsOf":targets_of,"rows":rows,"expanded":targets.len()>rows.len(),"change":model::changes(action,id(&action_descriptor["sourceLabelId"])),"invalidatesPage":invalidates,"removedIds":removed,"refused":false,"capability":capability}),
        )
    }
}
#[cfg(test)]
mod tests;
