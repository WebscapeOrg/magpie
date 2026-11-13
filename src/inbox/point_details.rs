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
        "haiku" | "sonnet" | "opus"
        | "claude-haiku-5-5" | "claude-sonnet-5-5" | "claude-opus-5-5"
        | "gpt-6-luna" | "gpt-6.1-sol" | "gpt-6-astra"
        | "gemini-3.8-flash" | "gemini-3.8-flash-low"
        | "gemini-4-argon" | "gemini-4-argon-low" | "gemini-4-argon-high"))
}

/// The efforts Magpie asks for; anything else is not shown.
pub(crate) fn effort(value: &str) -> bool {
    matches!(value, "low" | "medium" | "high")
}

fn passes(value: &Value) -> Option<Value> {
    let passes: Vec<Value> = value.as_array()?.iter().take(super::context_tokens::PASSES).filter_map(|pass| {
        let model = model(&pass["model"])?;
        let effort = pass["effort"].as_str().filter(|name| self::effort(name))?;
        Some(json!({"model": model, "effort": effort}))
    }).collect();
    (!passes.is_empty()).then(|| json!(passes))
}

pub(crate) fn clean(value: &Value) -> Value {
    let mut details = json!({});
    for key in ["gmailMs", "decideMs", "createMs"] {
        if let Some(ms) = duration(&value[key]) { details[key] = json!(ms); }
    }
    if let Some(tokens) = value["contextTokens"].as_u64().filter(|n| *n <= super::context_tokens::MAX) {
        details["contextTokens"] = json!(tokens);
        if let Some(partial) = value["contextTokensPartial"].as_bool() { details["contextTokensPartial"] = json!(partial); }
    }
    if let Some(cost) = value["costNanos"].as_u64().filter(|n| *n <= super::context_tokens::MAX) {
        details["costNanos"] = json!(cost);
        if let Some(partial) = value["costPartial"].as_bool() { details["costPartial"] = json!(partial); }
    }
    if let Some(cost) = value["decideCostNanos"].as_u64().filter(|n| *n <= super::context_tokens::MAX) {
        details["decideCostNanos"] = json!(cost);
    }
    if let Some(passes) = passes(&value["passes"]) { details["passes"] = passes; }
    for key in ["requestedModel", "model"] {
        if let Some(name) = model(&value[key]) { details[key] = json!(name); }
    }
    for key in ["downloadRun", "createRun"] {
        if let Some(run) = crate::processing::clean(&value[key]) { details[key] = run; }
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
        let value = json!({"gmailMs":0,"decideMs":-1,"createMs":1.5,"requestedModel":"<img>","model":"claude-haiku-5-5","batchSize":200,"choice":"password","secret":"never","contextTokens":-1,"contextTokensPartial":true});
        assert_eq!(clean(&value), json!({"gmailMs":0,"model":"claude-haiku-5-5"}));
        assert_eq!(clean(&json!({"gmailMs":86_400_001,"decideMs":"12","createMs":null})), json!({}));
        for count in [json!(-1), json!(1.5), json!("100"), json!(super::super::context_tokens::MAX + 1), Value::Null] {
            assert_eq!(clean(&json!({"contextTokens":count,"contextTokensPartial":true})), json!({}));
        }
        assert_eq!(clean(&json!({"contextTokens":12345,"contextTokensPartial":true})), json!({"contextTokens":12345,"contextTokensPartial":true}));
        assert_eq!(clean(&json!({"contextTokens":0,"contextTokensPartial":"true"})), json!({"contextTokens":0}));
        assert_eq!(clean(&json!({"costNanos":4200,"costPartial":true,"decideCostNanos":40})), json!({"costNanos":4200,"costPartial":true,"decideCostNanos":40}));
        for cost in [json!(-1), json!(0.5), json!("1"), json!(super::super::context_tokens::MAX + 1)] {
            assert_eq!(clean(&json!({"costNanos":cost,"costPartial":false,"decideCostNanos":cost})), json!({}));
        }
        let passes = json!([{"model":"claude-opus-5-5","effort":"low"},{"model":"<img>","effort":"low"},{"model":"gemini-4-argon","effort":"SECRET"},{"model":"gemini-4-argon","effort":"high","extra":1}]);
        assert_eq!(clean(&json!({"passes":passes})), json!({"passes":[{"model":"claude-opus-5-5","effort":"low"},{"model":"gemini-4-argon","effort":"high"}]}));
        assert_eq!(clean(&json!({"passes":[{"model":"<img>","effort":"low"}]})), json!({}));
        assert_eq!(clean(&json!({"passes":(0..20).map(|_| json!({"model":"haiku","effort":"low"})).collect::<Vec<_>>()}))["passes"].as_array().unwrap().len(), super::super::context_tokens::PASSES);
        for model in ["gpt-6-luna", "gpt-6.1-sol", "gpt-6-astra", "gemini-3.8-flash", "gemini-4-argon"] {
            assert_eq!(clean(&json!({"model":model})), json!({"model":model}));
        }
    }
}
