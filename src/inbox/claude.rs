//! Magpie for iPhone writes mail descriptions with its own Claude API key.
//! Invariant: the key lives only in the device Keychain. It is read for each batch of messages, sent
//! only to api.anthropic.com in a sensitive header, and never returned, logged or stored elsewhere.
#![cfg_attr(not(feature = "mobile"), allow(dead_code))]
use super::{describe, now, store};
use crate::credentials::{self, CredentialKey, CredentialKind, Secret};
use serde_json::{Value, json};
use std::time::Duration;

const ORIGIN: &str = "https://api.anthropic.com";
const VERSION: &str = "2026-10-21";
// Haiku is used because descriptions are short and its cost is low; DAILY_SPEND caps what a day can cost.
pub(crate) const MODEL: &str = "claude-haiku-5-5";
const REPLY_LIMIT: usize = 8 * 1024 * 1024;
const REQUEST_LIMIT: usize = 30 * 1024 * 1024;
// Invariant: spending stops for the day at about $0.50. Each message is counted before it is sent and
// stays below PROMPT_LIMIT tokens; with the rules and earlier answers a request stays below 100,000
// tokens, where Haiku 5.5 bills $0.10 per million input and $0.50 per million output tokens.
const DAILY_SPEND: u64 = 500_000_000;
const DAILY_CALLS: u64 = 1_500;
const PROMPT_LIMIT: u64 = 80_000;
const PAUSE: i64 = 5 * 60_000;
// Raised when Claude refuses a request that carries a PDF; the message is then described without its PDFs.
const DOCUMENT_REFUSED: &str = "overview_document_refused";
const INVALID: &str = "overview_invalid_response";
// Problems that stop every request until Dave acts in Settings or the Claude Console.
const BLOCKING: [&str; 3] = ["ai_key_invalid", "ai_key_refused", "ai_model_unavailable"];

fn slot() -> CredentialKey {
    CredentialKey {
        provider: "anthropic".into(),
        account_id: "default".into(),
        kind: CredentialKind::ClaudeApiKey,
    }
}

/// A standard Claude API key: `sk-ant-api…`, URL-safe characters only. Admin and
/// subscription tokens are refused, so the phone never holds more than it needs.
pub(crate) fn valid_key(key: &str) -> bool {
    (40..=256).contains(&key.len())
        && key.starts_with("sk-ant-api")
        && key
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
}

fn state_name() -> String {
    store::key(&["claude"])
}

fn state() -> Result<Value, &'static str> {
    let saved = store::read(&state_name())?.unwrap_or(json!({}));
    if !saved.is_object() {
        return Err("inbox_storage_invalid");
    }
    Ok(saved)
}

fn today(at: i64) -> String {
    chrono::DateTime::from_timestamp_millis(at)
        .map(|time| time.format("%Y-%m-%d").to_string())
        .unwrap_or_default()
}

fn blocking(saved: &Value) -> Option<&'static str> {
    let problem = saved["problem"].as_str()?;
    BLOCKING.into_iter().find(|known| *known == problem)
}

fn waiting(saved: &Value, at: i64) -> Option<&'static str> {
    if saved["retryAt"].as_i64().is_some_and(|retry| retry > at) {
        return Some(match saved["problem"].as_str() {
            Some("ai_billing") => "ai_billing",
            Some("ai_unreachable") => "ai_unreachable",
            _ => "ai_rate_limited",
        });
    }
    let today = saved["day"].as_str() == Some(today(at).as_str());
    (today
        && (saved["calls"].as_u64().unwrap_or(0) >= DAILY_CALLS
            || saved["spent"].as_u64().unwrap_or(0) >= DAILY_SPEND))
        .then_some("ai_daily_limit")
}

/// Counts one call against today's limits, or refuses it while Claude cannot be asked.
fn admit(at: i64) -> Result<(), &'static str> {
    store::update(&state_name(), |saved| {
        if !saved.is_object() {
            *saved = json!({});
        }
        if let Some(problem) = blocking(saved).or_else(|| waiting(saved, at)) {
            return Err(problem);
        }
        let day = today(at);
        if saved["day"].as_str() != Some(day.as_str()) {
            saved["day"] = json!(day);
            saved["calls"] = json!(0);
            saved["spent"] = json!(0);
        }
        saved["calls"] = json!(saved["calls"].as_u64().unwrap_or(0) + 1);
        Ok(())
    })
}

/// What a reply cost in billionths of a dollar, from the token counts Claude reports.
fn cost(reply: &Value) -> u64 {
    let usage = &reply["usage"];
    let tokens = |key: &str| usage[key].as_u64().unwrap_or(0);
    let (fresh, written, read, output) = (
        tokens("input_tokens"),
        tokens("cache_creation_input_tokens"),
        tokens("cache_read_input_tokens"),
        tokens("output_tokens"),
    );
    let tier = if fresh + written + read > 100_000 { 5 } else { 1 };
    tier * (fresh * 100 + written * 125 + read * 10 + output * 500)
}

fn spend(reply: &Value, at: i64) -> Result<(), &'static str> {
    let amount = cost(reply);
    store::update(&state_name(), |saved| {
        if !saved.is_object() {
            *saved = json!({});
        }
        let day = today(at);
        if saved["day"].as_str() != Some(day.as_str()) {
            saved["day"] = json!(day);
            saved["calls"] = json!(0);
            saved["spent"] = json!(0);
        }
        saved["spent"] = json!(saved["spent"].as_u64().unwrap_or(0).saturating_add(amount));
        Ok(())
    })
}

async fn key() -> Result<Secret, &'static str> {
    match credentials::get(slot()).await {
        Ok(secret) => Ok(secret),
        Err(credentials::Error::Missing) => Err("ai_key_missing"),
        Err(_) => Err("ai_key_storage"),
    }
}

/// Fails before any message is claimed when no request could succeed, so mail is not marked failed.
pub(crate) async fn ready() -> Result<(), &'static str> {
    let saved = state()?;
    if let Some(problem) = blocking(&saved).or_else(|| waiting(&saved, now())) {
        return Err(problem);
    }
    key().await.map(|_| ())
}

/// Describes each message in its own request, so one message Claude cannot describe never fails another.
/// A message that fails carries its own error code, which decides whether it counts as an attempt.
pub(crate) async fn generate(messages: &Value) -> Result<Value, &'static str> {
    let key = key().await?;
    let client = client()?;
    let mut rows = Vec::new();
    for message in messages.as_array().ok_or("overview_input_invalid")? {
        match describe_one(&client, &key, message).await {
            Ok(answer) => rows.extend(answer.as_array().cloned().unwrap_or_default()),
            Err(error) => rows.push(json!({"id":message["id"],"error":error})),
        }
    }
    Ok(json!(rows))
}

async fn describe_one(client: &reqwest::Client, key: &Secret, message: &Value) -> Result<Value, &'static str> {
    let batch = fit(client, key, json!([message])).await?;
    match passes(client, key, &batch).await {
        Err(DOCUMENT_REFUSED) => passes(client, key, &without_documents(&batch).ok_or(INVALID)?).await,
        result => result,
    }
}

async fn passes(client: &reqwest::Client, key: &Secret, batch: &Value) -> Result<Value, &'static str> {
    describe::generate_with(batch, |prompt| async move { complete(client, key, &prompt, batch).await }).await
}

/// Counts every message, then drops PDFs and pictures until it fits below PROMPT_LIMIT, so no message
/// can move a request into the dearer long-prompt price. A message too long without them fails alone.
async fn fit(client: &reqwest::Client, key: &Secret, mut batch: Value) -> Result<Value, &'static str> {
    loop {
        let fits = match count(client, key, &batch).await {
            Ok(tokens) => tokens <= PROMPT_LIMIT,
            Err(DOCUMENT_REFUSED) => false,
            Err(error) => return Err(error),
        };
        if fits {
            return Ok(batch);
        }
        batch = without_documents(&batch)
            .or_else(|| without_images(&batch))
            .ok_or("overview_media_limit")?;
    }
}

/// Undoes a pause only when the key that failed is still the saved key, so a request made with an
/// old key cannot block a new one.
async fn remember(error: &'static str, key: &Secret, at: i64) -> Result<(), &'static str> {
    let (problem, retry) = match error {
        "ai_key_invalid" | "ai_key_refused" | "ai_model_unavailable" => (error, None),
        "ai_billing" => (error, Some(at + 12 * PAUSE)),
        "ai_unreachable" => (error, Some(at + PAUSE)),
        "ai_rate_limited" | "ai_unavailable" => ("ai_rate_limited", Some(at + PAUSE)),
        _ => return Ok(()),
    };
    if !credentials::get(slot()).await.is_ok_and(|saved| saved.as_slice() == key.as_slice()) {
        return Ok(());
    }
    store::update(&state_name(), |saved| {
        if !saved.is_object() {
            *saved = json!({});
        }
        saved["problem"] = json!(problem);
        saved["retryAt"] = json!(retry);
        Ok(())
    })
}

/// Checks a key with Anthropic before it is saved, so a mistyped or revoked key is refused at once.
pub(crate) async fn set_key(text: &str) -> Result<Value, &'static str> {
    let text = text.trim();
    if !valid_key(text) {
        return Err("ai_key_format");
    }
    let secret = Secret::new(text.as_bytes().to_vec()).map_err(|_| "ai_key_format")?;
    let client = client()?;
    let (status, _) = send(
        &client,
        &secret,
        reqwest::Method::GET,
        &format!("/v1/models/{MODEL}"),
        None,
    )
    .await?;
    if status != 200 {
        return Err(failure(status));
    }
    credentials::put(slot(), secret)
        .await
        .map_err(|_| "ai_key_storage")?;
    clear()?;
    status_now(true)
}

pub(crate) async fn remove_key() -> Result<Value, &'static str> {
    match credentials::delete(slot()).await {
        Ok(()) | Err(credentials::Error::Missing) => {}
        Err(_) => return Err("ai_key_storage"),
    }
    clear()?;
    status_now(false)
}

pub(crate) async fn key_status() -> Result<Value, &'static str> {
    let present = match credentials::get(slot()).await {
        Ok(_) => true,
        Err(credentials::Error::Missing) => false,
        Err(_) => return Err("ai_key_storage"),
    };
    status_now(present)
}

fn status_now(present: bool) -> Result<Value, &'static str> {
    let saved = state()?;
    let at = now();
    let problem = present
        .then(|| blocking(&saved).or_else(|| waiting(&saved, at)))
        .flatten();
    Ok(json!({"present":present,"model":MODEL,"problem":problem}))
}

fn clear() -> Result<(), &'static str> {
    store::update(&state_name(), |saved| {
        if !saved.is_object() {
            *saved = json!({});
        }
        let fields = saved.as_object_mut().ok_or("inbox_storage_invalid")?;
        fields.remove("problem");
        fields.remove("retryAt");
        Ok(())
    })
}

fn client() -> Result<reqwest::Client, &'static str> {
    crate::platform::http_client()
        .no_proxy()
        .https_only(true)
        .redirect(reqwest::redirect::Policy::none())
        .connect_timeout(Duration::from_secs(10))
        .timeout(Duration::from_secs(90))
        .build()
        .map_err(|_| "ai_unavailable")
}

async fn complete(
    client: &reqwest::Client,
    key: &Secret,
    prompt: &str,
    messages: &Value,
) -> Result<Value, &'static str> {
    let reply = call(client, key, "/v1/messages", request(prompt, messages)?, messages).await?;
    let value: Value = serde_json::from_slice(&reply).map_err(|_| INVALID)?;
    spend(&value, now())?;
    answer(&reply)
}

/// Counts the tokens of a message's first request, which Anthropic does without charge.
async fn count(client: &reqwest::Client, key: &Secret, messages: &Value) -> Result<u64, &'static str> {
    let text = serde_json::to_string(&describe::text_context(messages)).map_err(|_| "overview_input_invalid")?;
    let mut content = describe::media(messages)?;
    content.push(json!({"type":"text","text":text}));
    let body = serde_json::to_vec(&json!({"model": MODEL, "messages": [{"role": "user", "content": content}]}))
        .map_err(|_| "overview_input_invalid")?;
    if body.len() > REQUEST_LIMIT {
        return Err("overview_input_invalid");
    }
    let reply = call(client, key, "/v1/messages/count_tokens", body, messages).await?;
    let value: Value = serde_json::from_slice(&reply).map_err(|_| INVALID)?;
    // The rules sent with the real request add a few thousand tokens; PROMPT_LIMIT leaves room for them.
    value["input_tokens"].as_u64().ok_or(INVALID)
}

async fn call(
    client: &reqwest::Client,
    key: &Secret,
    path: &str,
    body: Vec<u8>,
    messages: &Value,
) -> Result<Vec<u8>, &'static str> {
    admit(now())?;
    let (status, reply) = match send(client, key, reqwest::Method::POST, path, Some(body)).await {
        Ok(sent) => sent,
        Err(error) => {
            // A failure to record the pause must not replace the error Claude gave.
            let _ = remember(error, key, now()).await;
            return Err(error);
        }
    };
    if status == 400 && without_documents(messages).is_some() {
        return Err(DOCUMENT_REFUSED);
    }
    if status != 200 {
        let error = failure(status);
        // A failure to record the pause must not replace the error Claude gave.
        let _ = remember(error, key, now()).await;
        return Err(error);
    }
    Ok(reply)
}

/// The same messages with their PDFs marked unreadable, or None when there were none.
fn without_documents(messages: &Value) -> Option<Value> {
    without(messages, "document")
}

fn without_images(messages: &Value) -> Option<Value> {
    without(messages, "image")
}

fn without(messages: &Value, kind: &str) -> Option<Value> {
    let mut plain = messages.clone();
    let mut removed = false;
    for file in plain.as_array_mut()?.iter_mut().flat_map(|message| message["files"].as_array_mut().into_iter().flatten()) {
        let Some(blocks) = file.get_mut("content").and_then(Value::as_array_mut) else { continue };
        let before = blocks.len();
        blocks.retain(|block| block["type"] != kind);
        if blocks.len() != before {
            removed = true;
            file["status"] = json!("Content could not be read");
        }
    }
    removed.then_some(plain)
}

/// Media first and the instructions last, so the second and third passes reuse the cached media.
fn request(prompt: &str, messages: &Value) -> Result<Vec<u8>, &'static str> {
    let mut content = describe::media(messages)?;
    if let Some(last) = content.last_mut() {
        last["cache_control"] = json!({"type": "ephemeral"});
    }
    content.push(json!({"type": "text", "text": prompt}));
    let body = json!({
        "model": MODEL,
        "max_tokens": 8000,
        "output_config": {"effort": "low"},
        "messages": [{"role": "user", "content": content}],
    });
    let bytes = serde_json::to_vec(&body).map_err(|_| "overview_input_invalid")?;
    if bytes.len() > REQUEST_LIMIT {
        return Err("overview_input_invalid");
    }
    Ok(bytes)
}

async fn send(
    client: &reqwest::Client,
    key: &Secret,
    method: reqwest::Method,
    path: &str,
    body: Option<Vec<u8>>,
) -> Result<(u16, Vec<u8>), &'static str> {
    let mut header =
        reqwest::header::HeaderValue::from_bytes(key.as_slice()).map_err(|_| "ai_key_format")?;
    header.set_sensitive(true);
    let mut request = client
        .request(method, format!("{ORIGIN}{path}"))
        .header("x-api-key", header)
        .header("anthropic-version", VERSION);
    if let Some(body) = body {
        request = request.header("content-type", "application/json").body(body);
    }
    let mut response = request.send().await.map_err(|_| "ai_unreachable")?;
    let status = response.status().as_u16();
    let mut bytes = Vec::new();
    while let Some(chunk) = response.chunk().await.map_err(|_| "ai_unreachable")? {
        if bytes.len() + chunk.len() > REPLY_LIMIT {
            return Err(INVALID);
        }
        bytes.extend_from_slice(&chunk);
    }
    Ok((status, bytes))
}

fn failure(status: u16) -> &'static str {
    match status {
        401 => "ai_key_invalid",
        402 => "ai_billing",
        403 => "ai_key_refused",
        404 => "ai_model_unavailable",
        400 | 413 => "overview_input_invalid",
        429 => "ai_rate_limited",
        _ => "ai_unavailable",
    }
}

/// Reads text blocks by type: Haiku may think first, and a refusal or a cut-off answer is never parsed.
fn answer(reply: &[u8]) -> Result<Value, &'static str> {
    let value: Value = serde_json::from_slice(reply).map_err(|_| INVALID)?;
    match value["stop_reason"].as_str() {
        Some("end_turn" | "stop_sequence") => {}
        Some("refusal") => return Err("overview_ai_refused"),
        _ => return Err(INVALID),
    }
    let text = value["content"]
        .as_array()
        .ok_or(INVALID)?
        .iter()
        .filter(|block| block["type"] == "text")
        .filter_map(|block| block["text"].as_str())
        .collect::<String>();
    let text = text.trim();
    let text = text
        .strip_prefix("```json")
        .or_else(|| text.strip_prefix("```"))
        .unwrap_or(text)
        .trim();
    serde_json::from_str(text.strip_suffix("```").unwrap_or(text).trim()).map_err(|_| INVALID)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn synthetic_key() -> String {
        format!("sk-ant-api03-{}", "A1b2_C3d4-".repeat(8))
    }

    #[test]
    fn pdfs_then_pictures_are_dropped_when_a_message_is_too_long_or_refused() {
        let messages = json!([
            {"id":"a","files":[{"name":"r.pdf","status":"Content supplied","content":[{"type":"document","source":{"type":"base64","media_type":"application/pdf","data":"JVBERi0="}}]},
                               {"name":"p.png","status":"Content supplied","content":[{"type":"image","source":{"type":"base64","media_type":"image/png","data":"AA=="}}]}]}
        ]);
        let plain = without_documents(&messages).unwrap();
        assert_eq!(plain[0]["files"][0]["content"], json!([]));
        assert_eq!(plain[0]["files"][0]["status"], "Content could not be read");
        assert_eq!(plain[0]["files"][1], messages[0]["files"][1]);
        assert!(without_documents(&plain).is_none(), "a message without PDFs is not asked twice");
        let bare = without_images(&plain).unwrap();
        assert_eq!(bare[0]["files"][1]["content"], json!([]));
        assert!(without_documents(&bare).or_else(|| without_images(&bare)).is_none(), "fitting stops when nothing is left to drop");
    }

    #[test]
    fn spending_is_priced_from_reported_tokens_and_stops_the_day() {
        let reply = |input: u64, output: u64| json!({"usage":{"input_tokens":input,"output_tokens":output,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}});
        assert_eq!(cost(&reply(50_000, 0)), 5_000_000, "input costs $0.10 a million tokens");
        assert_eq!(cost(&reply(0, 10_000)), 5_000_000, "output costs $0.50 a million tokens");
        assert_eq!(cost(&reply(200_000, 0)), 5 * 20_000_000, "a long prompt is billed at five times the rate");
        assert_eq!(cost(&json!({"usage":{"cache_read_input_tokens":50_000}})), 500_000, "cached media costs a tenth");
        assert_eq!(cost(&json!({})), 0);
        let at = 1_800_000_000_000;
        assert_eq!(waiting(&json!({"day":today(at),"spent":DAILY_SPEND}), at), Some("ai_daily_limit"));
        assert_eq!(waiting(&json!({"day":today(at),"calls":DAILY_CALLS}), at), Some("ai_daily_limit"));
        assert_eq!(waiting(&json!({"day":today(at),"spent":DAILY_SPEND - 1,"calls":DAILY_CALLS - 1}), at), None);
        assert_eq!(waiting(&json!({"day":"2000-01-01","spent":DAILY_SPEND}), at), None);
        assert_eq!(waiting(&json!({"retryAt":at + 1,"problem":"ai_unreachable"}), at), Some("ai_unreachable"));
    }

    #[test]
    fn only_standard_api_keys_are_accepted() {
        assert!(valid_key(&synthetic_key()));
        for refused in [
            String::new(),
            "sk-ant-api03-short".into(),
            format!("sk-ant-admin01-{}", "A".repeat(60)),
            format!("sk-ant-oat01-{}", "A".repeat(60)),
            format!("{} ", synthetic_key()),
            format!("{}\n", synthetic_key()),
            format!("{}é", synthetic_key()),
            format!("sk-ant-api03-{}", "A".repeat(300)),
        ] {
            assert!(!valid_key(&refused), "accepted {refused:?}");
        }
    }

    #[test]
    fn requests_use_haiku_low_effort_and_put_cached_media_before_the_instructions() {
        let messages = json!([{"id":"a","body":"Invoice attached","files":[{"name":"scan.png","content":[{"type":"image","source":{"type":"base64","media_type":"image/png","data":"iVBORw0KGgo="}},{"type":"text","text":"ignored here"}]}]}]);
        let body: Value = serde_json::from_slice(&request("RULES", &messages).unwrap()).unwrap();
        assert_eq!(body["model"], "claude-haiku-5-5");
        assert_eq!(body["output_config"]["effort"], "low");
        for removed in ["temperature", "top_p", "top_k", "system", "thinking"] {
            assert!(body.get(removed).is_none(), "{removed} must not be sent");
        }
        let content = body["messages"][0]["content"].as_array().unwrap();
        assert_eq!(body["messages"].as_array().unwrap().len(), 1);
        assert_eq!(body["messages"][0]["role"], "user");
        assert!(content[0]["text"].as_str().unwrap().contains("message \"a\" file:0"));
        assert_eq!(content[1]["type"], "image");
        assert_eq!(content[1]["cache_control"], json!({"type":"ephemeral"}));
        assert_eq!(content[2], json!({"type":"text","text":"RULES"}));
        assert_eq!(content.len(), 3);
        let plain: Value = serde_json::from_slice(&request("RULES", &json!([{"id":"b","body":"Hello"}])).unwrap()).unwrap();
        assert_eq!(plain["messages"][0]["content"], json!([{"type":"text","text":"RULES"}]), "text-only mail sets no cache point");
    }

    #[test]
    fn answers_are_read_by_block_type_and_refusals_or_cut_offs_fail() {
        let reply = |stop: &str, text: &str| {
            serde_json::to_vec(&json!({"stop_reason":stop,"content":[{"type":"thinking","thinking":"","signature":"x"},{"type":"text","text":text}]})).unwrap()
        };
        assert_eq!(
            answer(&reply("end_turn", "```json\n{\"overviews\":[]}\n```")).unwrap(),
            json!({"overviews":[]})
        );
        assert_eq!(answer(&reply("refusal", "{}")).unwrap_err(), "overview_ai_refused");
        assert_eq!(answer(&reply("max_tokens", "{\"overv")).unwrap_err(), INVALID);
        assert_eq!(answer(&reply("end_turn", "not json")).unwrap_err(), INVALID);
        assert_eq!(answer(b"<html>").unwrap_err(), INVALID);
    }

    #[test]
    fn http_failures_map_to_fixed_codes_and_key_problems_block_requests() {
        assert_eq!(failure(401), "ai_key_invalid");
        assert_eq!(failure(402), "ai_billing");
        assert_eq!(failure(403), "ai_key_refused");
        assert_eq!(failure(429), "ai_rate_limited");
        assert_eq!(failure(529), "ai_unavailable");
        assert_eq!(failure(500), "ai_unavailable");
        let at = 1_800_000_000_000;
        assert_eq!(blocking(&json!({"problem":"ai_key_invalid"})), Some("ai_key_invalid"));
        assert_eq!(blocking(&json!({"problem":"anything else"})), None);
        assert_eq!(waiting(&json!({"retryAt":at + 1}), at), Some("ai_rate_limited"));
        assert_eq!(waiting(&json!({"retryAt":at + 1,"problem":"ai_billing"}), at), Some("ai_billing"));
        assert_eq!(waiting(&json!({"retryAt":at - 1}), at), None);
    }
}
