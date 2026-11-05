use serde_json::{Value, json};
use std::time::Instant;

pub(crate) fn elapsed(started: Instant) -> u64 {
    u64::try_from(started.elapsed().as_millis()).unwrap_or(u64::MAX)
}

pub(crate) fn duration(value: &Value) -> Option<u64> {
    value.as_u64().filter(|value| *value <= 86_400_000)
}

pub(crate) fn model(value: &Value) -> Option<&str> {
    value.as_str().filter(|name| matches!(*name,
        "haiku" | "sonnet" | "opus" | "claude-haiku-5-5" | "claude-sonnet-5-5" | "claude-opus-5-5"))
}

pub(crate) fn clean(value: &Value) -> Value {
    let mut details = json!({});
    for key in ["gmailMs", "decideMs", "createMs"] {
        if let Some(ms) = duration(&value[key]) { details[key] = json!(ms); }
    }
    for key in ["requestedModel", "model"] {
        if let Some(name) = model(&value[key]) { details[key] = json!(name); }
    }
    if let Some(size) = value["batchSize"].as_u64().filter(|size| (1..=4).contains(size)) {
        details["batchSize"] = json!(size);
    }
    if let Some(choice) = value["choice"].as_str().filter(|choice| matches!(*choice, "decisions" | "default")) {
        details["choice"] = json!(choice);
    }
    details
}

pub(crate) fn merge(row: &mut Value, extra: &Value) {
    let mut details = clean(&row["details"]);
    for (key, value) in clean(extra).as_object().into_iter().flatten() {
        details[key] = value.clone();
    }
    row["details"] = details;
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn persisted_details_are_bounded_and_do_not_accept_provider_text() {
        let value = json!({"gmailMs":0,"decideMs":-1,"createMs":1.5,"requestedModel":"<img>","model":"claude-haiku-5-5","batchSize":200,"choice":"password","secret":"never"});
        assert_eq!(clean(&value), json!({"gmailMs":0,"model":"claude-haiku-5-5"}));
        assert_eq!(clean(&json!({"gmailMs":86_400_001,"decideMs":"12","createMs":null})), json!({}));
    }
}
