use super::*;
const MAX_STORE: usize = 4 * 1024 * 1024;

pub(super) fn empty() -> Value {
    json!({"version":2,"account":"","profile":null,"labels":[],"queries":{},"session":null})
}

pub(super) fn normalize_store(value: &Value) -> Value {
    if !value.is_object() || value["version"].as_u64() != Some(2) {
        return empty();
    }
    let mut out = empty();
    out.as_object_mut()
        .unwrap()
        .extend(value.as_object().unwrap().clone());
    out["account"] = json!(js_string(&value["account"]));
    out["profile"] = value["profile"]
        .as_object()
        .cloned()
        .map(Value::Object)
        .unwrap_or(Value::Null);
    out["labels"] = value["labels"]
        .as_array()
        .cloned()
        .map(Value::Array)
        .unwrap_or(json!([]));
    out["queries"] = json!({});
    if let Some(queries) = value["queries"].as_object() {
        let mut entries: Vec<_> = queries.iter().collect();
        entries.sort_by(|a, b| {
            b.1["at"]
                .as_f64()
                .unwrap_or(0.0)
                .total_cmp(&a.1["at"].as_f64().unwrap_or(0.0))
        });
        for (key, entry) in entries.into_iter().take(12) {
            let summaries = entry["summaries"].as_array().cloned().unwrap_or_default();
            let token = if summaries.len() > 100 {
                String::new()
            } else {
                js_string(&entry["nextPageToken"])
            };
            out["queries"][key] = json!({"summaries":summaries.into_iter().take(100).map(|mut row| { if row.is_object() { row["subjectDirection"] = json!(crate::message::direction::resolve_subject(row["subject"].as_str().unwrap_or(""), crate::message::direction::AUTO)); } row }).collect::<Vec<_>>(),"nextPageToken":token,"estimate":entry["estimate"].as_f64().unwrap_or(0.0).floor().max(0.0),"at":entry["at"].as_f64().unwrap_or(0.0)});
        }
    }
    out
}

pub(super) fn call_at(root: &Path, method: &str, params: &Value) -> Result<Value> {
    let normalize = normalize_store;
    let empty = || normalize(&Value::Null);
    validate_params(params, false)?;
    let name = format!("{}.json", account_name(field(params, "accountId")?)?);
    let _lock = OPERATIONS.lock().map_err(|_| "cache_unavailable")?;
    let writing = method == "cache.storePut";
    let value = normalize(&params["store"]);
    let bytes = if writing {
        let bytes = serde_json::to_vec(&value).map_err(|_| "cache_store_invalid")?;
        if bytes.len() > MAX_STORE {
            return Err("cache_store_too_large");
        }
        bytes
    } else {
        Vec::new()
    };
    let Some(dir) = directories(root, &["omamail"], writing)? else {
        return Ok(empty());
    };
    let existing = regular(&dir, &name, false)?;
    if !writing {
        let Some(mut file) = existing else {
            return Ok(empty());
        };
        if file.metadata().map_err(|_| "cache_unavailable")?.len() > MAX_STORE as u64 {
            return Ok(empty());
        }
        let mut bytes = Vec::new();
        (&mut file)
            .take(MAX_STORE as u64 + 1)
            .read_to_end(&mut bytes)
            .map_err(|_| "cache_unavailable")?;
        if bytes.len() > MAX_STORE {
            return Ok(empty());
        }
        return Ok(serde_json::from_slice(&bytes)
            .map(|v| normalize(&v))
            .unwrap_or_else(|_| empty()));
    }
    atomic_replace(&dir, &name, &bytes)?;
    Ok(json!({"stored":true}))
}
