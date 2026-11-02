//! Magpie for iPhone writes mail descriptions with its own Claude API key.
//! Invariant: the key lives only in the device Keychain. It is read for each batch of messages, sent
//! only to api.anthropic.com in a sensitive header, and never returned, logged or stored elsewhere.
#![cfg_attr(not(feature = "mobile"), allow(dead_code))]
use super::{INTERRUPTED, describe, now, store};
use crate::credentials::{self, CredentialKey, CredentialKind, Secret};
use serde_json::{Value, json};
use std::time::Duration;

#[path = "claude_diagnostics.rs"]
pub(crate) mod diagnostics;

const ORIGIN: &str = "https://api.anthropic.com";
const VERSION: &str = "2026-10-21";
// Haiku is used because descriptions are short and its cost is low; DAILY_SPEND caps what a day can cost.
pub(crate) const MODEL: &str = "claude-haiku-5-5";
const REPLY_LIMIT: usize = 8 * 1024 * 1024;
pub(crate) const REQUEST_LIMIT: usize = 30 * 1024 * 1024;
// Q-005: Dave chose Sonnet 5.5 for the assistant, with a daily limit of its own (assistant.rs).
pub(crate) const ASSISTANT_MODEL: &str = "claude-sonnet-5-5";
// Invariant: spending stops for the day at about $0.50. Each message is counted before it is sent and
// stays below PROMPT_LIMIT tokens; with the rules and earlier answers a request stays below 100,000
// tokens, where Haiku 5.5 bills $0.10 per million input and $0.50 per million output tokens.
const DAILY_SPEND: u64 = 500_000_000;
const DAILY_CALLS: u64 = 1_500;
const PROMPT_LIMIT: u64 = 80_000;
const PAUSE: i64 = 5 * 60_000;
// Invariant: a request that failed for a reason that says nothing about it (a lost connection, a
// timeout, 408, 409, 429 or 5xx, 529 included, or a reply that says to retry) is asked again up to
// RETRIES times, after about 1, 2 and 4 seconds or the shorter wait Claude asks for, and only
// while RETRY_WINDOW has not passed. A longer wait Claude asks for is kept by the shared backoff.
const RETRIES: u32 = 3;
const FIRST_WAIT: Duration = Duration::from_secs(1);
const LONGEST_WAIT: Duration = Duration::from_secs(30);
const RETRY_WINDOW: Duration = Duration::from_secs(90);
// After a request still fails, descriptions wait 15 seconds, then twice as long after each further
// failure up to PAUSE, or longer when Claude asks for it. A request that succeeds resets the wait.
const BACKOFF_FIRST: i64 = 15_000;
// The longest wait Claude can ask for that descriptions keep: an hour, so one reply cannot stop them for a day.
const LONGEST_ASKED: i64 = 3_600_000;
// Problems that clear by themselves; descriptions wait for them without telling Dave.
pub(crate) const TRANSIENT: [&str; 3] = ["ai_unreachable", "ai_rate_limited", "ai_unavailable"];
// A Fault with this class was refused before anything was sent.
const REFUSED: &str = "refused";
/// The class of a fault from an attempt during which the app left the foreground.
const SUSPENDED: &str = "suspended";
// Raised when Claude refuses a request that carries a PDF; the message is then described without its PDFs.
const DOCUMENT_REFUSED: &str = "overview_document_refused";
const INVALID: &str = "overview_invalid_response";
// Problems that stop every request until Dave acts in Settings or the Claude Console.
const BLOCKING: [&str; 4] = ["ai_key_invalid", "ai_key_refused", "ai_key_workspace", "ai_model_unavailable"];
// The key's own problems. Unlike BLOCKING, they leave out the description model being unavailable.
/// Key problems that hold for every model: a key Claude does not know, and one a mail-free probe
/// confirmed is not tied to one workspace. A refusal (403) can be for one model only.
const KEY_PROBLEMS: [&str; 2] = ["ai_key_invalid", "ai_key_workspace"];

fn slot() -> CredentialKey {
    CredentialKey {
        provider: "anthropic".into(),
        account_id: "default".into(),
        kind: CredentialKind::ClaudeApiKey,
    }
}

/// The Claude Console's API keys: personal (`sk-ant-usr…`), service account (`sk-ant-svc…`) and
/// older (`sk-ant-api…`) keys. The two newer prefixes are known from third-party reports, not from
/// Anthropic's documentation, which says only that keys start with `sk-ant-`.
const KEY_PREFIXES: [&str; 3] = ["sk-ant-api", "sk-ant-usr", "sk-ant-svc"];

/// A Claude API key, URL-safe characters only. Admin keys and subscription tokens are refused:
/// the Messages API does not take them, and the phone never holds more than it needs.
pub(crate) fn valid_key(key: &str) -> bool {
    (40..=256).contains(&key.len())
        && KEY_PREFIXES.iter().any(|prefix| key.starts_with(prefix))
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
/// Invariant: a failure of Claude or the key, rather than of the message, stops the batch, and so does
/// the app leaving the foreground; the messages after it are returned as not asked ("stage":"batch"),
/// so they are neither sent while Claude cannot answer nor counted against themselves.
/// `left_before` is the count of times the app left the foreground when the request arrived.
pub(crate) async fn generate(messages: &Value, left_before: u64) -> Result<Value, &'static str> {
    let key = key().await?;
    let client = client()?;
    let (client, key) = (&client, &key);
    each_message(messages, |message| async move { describe_one(client, key, &message).await }, diagnostics::suspensions, left_before).await
}

async fn each_message<F, Fut>(messages: &Value, mut describe: F, suspensions: fn() -> u64, started: u64) -> Result<Value, &'static str>
where
    F: FnMut(Value) -> Fut,
    Fut: std::future::Future<Output = Result<Value, &'static str>>,
{
    let mut rows = Vec::new();
    let mut stopped: Option<&'static str> = None;
    for message in messages.as_array().ok_or("overview_input_invalid")? {
        if stopped.is_none() && suspensions() != started {
            stopped = Some(INTERRUPTED);
        }
        if let Some(reason) = stopped {
            rows.push(json!({"id":message["id"],"error":reason,"stage":"batch"}));
            continue;
        }
        let before = suspensions();
        match describe(message.clone()).await {
            Ok(answer) => rows.extend(answer.as_array().cloned().unwrap_or_default()),
            // A request that iOS froze when the app left says nothing about Claude or the message, so
            // the message is described as soon as the app returns.
            Err(error) if TRANSIENT.contains(&error) && suspensions() != before => {
                rows.push(json!({"id":message["id"],"error":INTERRUPTED,"stage":"batch"}));
                stopped = Some(INTERRUPTED);
            }
            Err(error) => {
                rows.push(json!({"id":message["id"],"error":error}));
                if error.starts_with("ai_") {
                    stopped = Some(error);
                }
            }
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

/// The shared wait after the `level`th failure in a row: 15 seconds doubling, at most PAUSE.
fn backoff(level: u64) -> i64 {
    (BACKOFF_FIRST << level.saturating_sub(1).min(10)).min(PAUSE)
}

/// Records a problem that stops describing, and for a passing one how long to wait. It is kept only
/// when the key that failed is still the saved key, so a request made with an old key cannot block a
/// new one. `asked` is the wait Claude asked for, which is kept when it is longer.
async fn remember(error: &'static str, key: &Secret, at: i64, asked: Option<Duration>) -> Result<(), &'static str> {
    let problem = match error {
        "ai_key_invalid" | "ai_key_refused" | "ai_key_workspace" | "ai_model_unavailable" | "ai_billing" | "ai_unreachable" => error,
        "ai_rate_limited" | "ai_unavailable" => "ai_rate_limited",
        _ => return Ok(()),
    };
    if !credentials::get(slot()).await.is_ok_and(|saved| saved.as_slice() == key.as_slice()) {
        return Ok(());
    }
    let asked = asked.map_or(0, |wait| i64::try_from(wait.as_millis()).unwrap_or(i64::MAX).min(LONGEST_ASKED));
    let (level, retry) = store::update(&state_name(), |saved| {
        if !saved.is_object() {
            *saved = json!({});
        }
        let (level, retry) = match error {
            "ai_billing" => (0, Some(at + 12 * PAUSE)),
            _ if TRANSIENT.contains(&error) => {
                let level = (saved["backoff"].as_u64().unwrap_or(0) + 1).min(16);
                saved["backoff"] = json!(level);
                (level, Some(at + backoff(level).max(asked)))
            }
            _ => (0, None),
        };
        saved["problem"] = json!(problem);
        saved["retryAt"] = json!(retry);
        Ok((level, retry))
    })?;
    diagnostics::record(diagnostics::Event {
        outcome: problem.into(),
        level: level as u32,
        wait_ms: retry.map_or(0, |retry| u64::try_from(retry - at).unwrap_or(0)),
        retry_after_ms: (asked > 0).then_some(asked as u64),
        ..diagnostics::event("backoff")
    });
    Ok(())
}

/// A description Claude wrote ends the shared wait and its count of failures in a row.
fn recovered(at: i64) {
    let Ok(saved) = state() else { return };
    let passing = |saved: &Value| {
        matches!(saved["problem"].as_str(), Some("ai_unreachable" | "ai_rate_limited" | "ai_billing"))
            && saved["retryAt"].as_i64().is_none_or(|retry| retry <= at)
    };
    if saved.get("backoff").is_none() && !passing(&saved) {
        return;
    }
    let _ = store::update(&state_name(), |saved| {
        let clear = passing(saved);
        let Some(fields) = saved.as_object_mut() else { return Ok(()) };
        fields.remove("backoff");
        if clear {
            fields.remove("problem");
            fields.remove("retryAt");
        }
        Ok(())
    });
}

/// Checks a key with Anthropic before it is saved, so a mistyped or revoked key is refused at once.
pub(crate) async fn set_key(text: &str) -> Result<Value, &'static str> {
    let text = text.trim();
    if !valid_key(text) {
        return Err("ai_key_format");
    }
    let secret = Secret::new(text.as_bytes().to_vec()).map_err(|_| "ai_key_format")?;
    let client = client()?;
    let path = format!("/v1/models/{MODEL}");
    let reply = exchange(&client, &secret, "keyCheck", reqwest::Method::GET, &path, None, false)
        .await
        .map_err(|fault| fault.code)?;
    if reply.status != 200 {
        return Err(refusal(reply.status, &reply.body));
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
        fields.remove("backoff");
        Ok(())
    })
}

fn client() -> Result<reqwest::Client, &'static str> {
    client_for(Duration::from_secs(90))
}

fn client_for(timeout: Duration) -> Result<reqwest::Client, &'static str> {
    crate::platform::http_client()
        .no_proxy()
        .https_only(true)
        .redirect(reqwest::redirect::Policy::none())
        .connect_timeout(Duration::from_secs(10))
        .timeout(timeout)
        .build()
        .map_err(|_| "ai_unavailable")
}

/// The problem that stops every assistant request now, if any.
/// Invariant: the assistant shares the key, the key problems that hold for every model and a
/// billing pause with descriptions, and nothing else. Claude allows and limits each model
/// separately, so a description's refusal, rate limit or unavailable Haiku model never stops a
/// question Dave asks, and the assistant's own refusal, rate limits, unavailable model or lost
/// connection stay on its job instead of pausing descriptions.
fn conversation_problem(saved: &Value, at: i64) -> Option<&'static str> {
    if let Some(problem) = saved["problem"].as_str() {
        if let Some(known) = KEY_PROBLEMS.into_iter().find(|known| *known == problem) {
            return Some(known);
        }
    }
    (saved["problem"] == "ai_billing" && saved["retryAt"].as_i64().is_some_and(|retry| retry > at))
        .then_some("ai_billing")
}

/// Fails before a question is accepted when no assistant request could succeed.
pub(crate) async fn conversation_ready() -> Result<(), &'static str> {
    if let Some(problem) = conversation_problem(&state()?, now()) {
        return Err(problem);
    }
    key().await.map(|_| ())
}

/// Sends one Messages API request for the assistant and returns Claude's reply.
pub(crate) async fn converse(body: Vec<u8>) -> Result<Value, &'static str> {
    if body.len() > REQUEST_LIMIT {
        return Err("ai_request_rejected");
    }
    if let Some(problem) = conversation_problem(&state()?, now()) {
        return Err(problem);
    }
    let key = key().await?;
    // An answer of up to 16,000 tokens, written without streaming, can take several minutes.
    let client = client_for(Duration::from_secs(600))?;
    let (status, reply) = match exchange(&client, &key, "assistant", reqwest::Method::POST, "/v1/messages", Some(body), false).await {
        Ok(sent) => (sent.status, sent.body),
        Err(fault) if fault.code == INVALID => return Err("ai_invalid_response"),
        Err(fault) => return Err(fault.code),
    };
    if status == 200 {
        return serde_json::from_slice(&reply).map_err(|_| "ai_invalid_response");
    }
    // Invariant: as for descriptions, a key is called unscoped only when a request with no mail in
    // it is refused the same way, so text in a message can never stop the key.
    let error = match status {
        400 if unscoped(&reply) && unscoped_key(&client, &key).await => "ai_key_workspace",
        400 | 413 => "ai_request_rejected",
        _ => failure(status),
    };
    if KEY_PROBLEMS.contains(&error) || error == "ai_billing" {
        // A failure to record the problem must not replace the error Claude gave.
        let _ = remember(error, &key, now(), None).await;
    }
    Err(error)
}

async fn complete(
    client: &reqwest::Client,
    key: &Secret,
    prompt: &str,
    messages: &Value,
) -> Result<Value, &'static str> {
    let reply = call(client, key, "describe", "/v1/messages", request(prompt, messages)?, messages).await?;
    let value: Value = serde_json::from_slice(&reply).map_err(|_| INVALID)?;
    spend(&value, now())?;
    // Invariant: only a description Claude wrote ends the shared wait; a token count can succeed
    // while every description request fails, and must not keep the wait at its first step.
    recovered(now());
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
    let reply = call(client, key, "count", "/v1/messages/count_tokens", body, messages).await?;
    let value: Value = serde_json::from_slice(&reply).map_err(|_| INVALID)?;
    // The rules sent with the real request add a few thousand tokens; PROMPT_LIMIT leaves room for them.
    value["input_tokens"].as_u64().ok_or(INVALID)
}

async fn call(
    client: &reqwest::Client,
    key: &Secret,
    operation: &'static str,
    path: &str,
    body: Vec<u8>,
    messages: &Value,
) -> Result<Vec<u8>, &'static str> {
    let reply = match exchange(client, key, operation, reqwest::Method::POST, path, Some(body), true).await {
        Ok(reply) => reply,
        Err(fault) if fault.class == REFUSED => return Err(fault.code),
        // A connection lost while iOS froze the app says nothing about Claude, so it starts no wait.
        Err(fault) if fault.class == SUSPENDED => return Err(fault.code),
        Err(fault) => {
            // A failure to record the pause must not replace the error Claude gave.
            let _ = remember(fault.code, key, now(), None).await;
            return Err(fault.code);
        }
    };
    let status = reply.status;
    // Invariant: describing stops for a key not scoped to a workspace only when a request that
    // carries no mail is refused the same way, so text in a message can never stop it.
    let workspace = status == 400 && unscoped(&reply.body) && unscoped_key(client, key).await;
    if status == 400 && !workspace && without_documents(messages).is_some() {
        return Err(DOCUMENT_REFUSED);
    }
    if status != 200 {
        let error = if workspace {
            "ai_key_workspace"
        } else {
            failure(status)
        };
        // A failure to record the pause must not replace the error Claude gave.
        let _ = remember(error, key, now(), reply.retry_after).await;
        return Err(error);
    }
    Ok(reply.body)
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

/// One answer from Claude, with what it said about asking again.
struct Reply {
    status: u16,
    body: Vec<u8>,
    retry_after: Option<Duration>,
    should_retry: Option<bool>,
}

/// A request that got no usable answer: the error code and, for the record, what kind of failure.
#[derive(Clone, Copy, Debug, PartialEq)]
struct Fault {
    code: &'static str,
    class: &'static str,
}

/// Sends one request, asking again after a failure that says nothing about the request.
/// With `counted`, each attempt is first admitted against today's limits and the shared wait.
/// Without it (the assistant, the key check and the workspace probe, which keep their own limits or
/// cost nothing), only a request Claude never received (no connection) or refused with an error
/// status, neither of which is billed, is sent again; one cut off after it was sent is not.
#[allow(clippy::too_many_arguments)]
async fn exchange(
    client: &reqwest::Client,
    key: &Secret,
    operation: &'static str,
    method: reqwest::Method,
    path: &str,
    body: Option<Vec<u8>>,
    counted: bool,
) -> Result<Reply, Fault> {
    let request = build(client, key, method, path, body)?;
    let serial = diagnostics::serial();
    let mut started = std::time::Instant::now();
    let mut attempt = 0;
    // One count carried through the loop, so a leave at any moment between two checks is seen.
    let mut seen = diagnostics::suspensions();
    loop {
        attempt += 1;
        if counted {
            admit(now()).map_err(|code| Fault { code, class: REFUSED })?;
        }
        let mut event = diagnostics::event("attempt");
        let sent = std::time::Instant::now();
        let answer = match request.try_clone() {
            Some(request) => send(client, request).await,
            None => Err(Fault { code: "ai_unavailable", class: "request" }),
        };
        let count = diagnostics::suspensions();
        let suspended = count != seen;
        seen = count;
        if suspended {
            // Time the app spent frozen in the background does not use up the retry window.
            started = std::time::Instant::now();
        }
        let wait = resend_wait(&answer, attempt, started.elapsed(), jitter(), counted, suspended && !diagnostics::active());
        event.operation = operation.into();
        event.request = serial;
        event.attempt = attempt;
        event.elapsed_ms = millis(sent.elapsed());
        event.wait_ms = wait.map_or(0, millis);
        event.suspended = suspended;
        match &answer {
            Ok(reply) => {
                event.status = Some(reply.status);
                event.class = "http".into();
                event.retry_after_ms = reply.retry_after.map(millis);
                event.outcome = if reply.status == 200 { "ok" } else { failure(reply.status) }.into();
            }
            Err(fault) => {
                event.class = fault.class.into();
                event.outcome = diagnostics::outcome(fault.code);
            }
        }
        diagnostics::record(event);
        let Some(wait) = wait else { return marked(answer, suspended) };
        tokio::time::sleep(wait).await;
        let count = diagnostics::suspensions();
        if count != seen {
            // The app left while this request waited to be sent again, so it is not sent from the
            // background; the failure keeps the class of the attempt it came from.
            if !diagnostics::active() {
                return marked(answer, suspended);
            }
            // It left and came back during the wait, which says nothing about the next attempt.
            seen = count;
            started = std::time::Instant::now();
        }
    }
}

/// A failed answer from a request the app left during is marked SUSPENDED, so it starts no shared wait.
fn marked(answer: Result<Reply, Fault>, suspended: bool) -> Result<Reply, Fault> {
    match answer {
        Err(fault) if suspended && fault.class != REFUSED => Err(Fault { code: fault.code, class: SUSPENDED }),
        answer => answer,
    }
}

/// How long to wait before sending a request again, or None to return its answer now.
/// Invariant: a request is never sent again while the app is in the background after leaving during
/// it (`away`), where iOS can freeze it again; the message is asked when the app returns. Without
/// `counted`, only a request Claude never received (no connection) or refused with an error status,
/// neither of which is billed, is sent again; one cut off after it was sent is not.
fn resend_wait(answer: &Result<Reply, Fault>, attempt: u32, elapsed: Duration, jitter: f64, counted: bool, away: bool) -> Option<Duration> {
    let resendable = counted || !matches!(answer, Err(fault) if fault.class != "connect");
    retry_wait(answer, attempt, elapsed, jitter).filter(|_| resendable && !away)
}

fn millis(duration: Duration) -> u64 {
    u64::try_from(duration.as_millis()).unwrap_or(u64::MAX)
}

/// A number from 0 to 1 that spreads retries from many phones apart.
fn jitter() -> f64 {
    let nanos = std::time::SystemTime::UNIX_EPOCH.elapsed().map_or(0, |time| time.subsec_nanos());
    f64::from(nanos % 1_000_000) / 1_000_000.0
}

/// How long to wait before asking again after this attempt, or None when its answer stands.
fn retry_wait(answer: &Result<Reply, Fault>, attempt: u32, elapsed: Duration, jitter: f64) -> Option<Duration> {
    let (transient, asked) = match answer {
        Ok(reply) if reply.status >= 400 => (
            reply.should_retry.unwrap_or(matches!(reply.status, 408 | 409 | 429 | 500..=599)),
            reply.retry_after,
        ),
        Ok(_) => (false, None),
        Err(fault) => (fault.code == "ai_unreachable", None),
    };
    if !transient || attempt > RETRIES {
        return None;
    }
    let wait = match asked {
        Some(asked) if asked > LONGEST_WAIT => return None,
        Some(asked) => asked,
        None => FIRST_WAIT.saturating_mul(1 << (attempt - 1)).mul_f64(1.0 - 0.25 * jitter.clamp(0.0, 1.0)),
    };
    (elapsed + wait <= RETRY_WINDOW).then_some(wait)
}

fn build(
    client: &reqwest::Client,
    key: &Secret,
    method: reqwest::Method,
    path: &str,
    body: Option<Vec<u8>>,
) -> Result<reqwest::Request, Fault> {
    let mut header = reqwest::header::HeaderValue::from_bytes(key.as_slice())
        .map_err(|_| Fault { code: "ai_key_format", class: REFUSED })?;
    header.set_sensitive(true);
    let mut request = client
        .request(method, format!("{ORIGIN}{path}"))
        .header("x-api-key", header)
        .header("anthropic-version", VERSION);
    if let Some(body) = body {
        request = request.header("content-type", "application/json").body(body);
    }
    request.build().map_err(|_| Fault { code: "ai_unavailable", class: REFUSED })
}

async fn send(client: &reqwest::Client, request: reqwest::Request) -> Result<Reply, Fault> {
    let lost = |error: reqwest::Error| Fault { code: "ai_unreachable", class: class(&error) };
    let mut response = client.execute(request).await.map_err(lost)?;
    let status = response.status().as_u16();
    let headers = response.headers();
    let retry_after = retry_after(headers, now());
    let should_retry = match headers.get("x-should-retry").map(|value| value.as_bytes()) {
        Some(b"true") => Some(true),
        Some(b"false") => Some(false),
        _ => None,
    };
    let mut body = Vec::new();
    while let Some(chunk) = response.chunk().await.map_err(lost)? {
        if body.len() + chunk.len() > REPLY_LIMIT {
            return Err(Fault { code: INVALID, class: "tooLarge" });
        }
        body.extend_from_slice(&chunk);
    }
    Ok(Reply { status, body, retry_after, should_retry })
}

/// What kind of failure lost the answer, for the record; the request is asked again the same way.
fn class(error: &reqwest::Error) -> &'static str {
    if error.is_timeout() {
        "timeout"
    } else if error.is_connect() {
        "connect"
    } else if error.is_body() || error.is_decode() {
        "body"
    } else if error.is_request() {
        "request"
    } else {
        "other"
    }
}

/// The wait Claude asked for, from `retry-after-ms` or `retry-after` (seconds or an HTTP date), at
/// most LONGEST_ASKED. A wait of nothing or a time already past is ignored, so the request waits
/// its own backoff instead of being sent again at once.
fn retry_after(headers: &reqwest::header::HeaderMap, at: i64) -> Option<Duration> {
    let text = |name: &str| headers.get(name).and_then(|value| value.to_str().ok()).map(str::trim);
    let millis = if let Some(ms) = text("retry-after-ms").and_then(|value| value.parse::<f64>().ok()) {
        if !ms.is_finite() {
            return None;
        }
        ms.min(LONGEST_ASKED as f64) as i64
    } else {
        let value = text("retry-after")?;
        match value.parse::<u64>() {
            Ok(seconds) => i64::try_from(seconds.saturating_mul(1000)).unwrap_or(i64::MAX),
            Err(_) => chrono::DateTime::parse_from_rfc2822(value).ok()?.timestamp_millis().saturating_sub(at),
        }
    };
    (millis > 0).then(|| Duration::from_millis(millis.min(LONGEST_ASKED) as u64))
}

/// True when Claude refused the request because the key is not scoped to one workspace, so every
/// request would need a workspace the phone does not know.
fn unscoped(reply: &[u8]) -> bool {
    let value: Value = serde_json::from_slice(reply).unwrap_or(Value::Null);
    value["error"]["type"] == "invalid_request_error"
        && value["error"]["message"]
            .as_str()
            .is_some_and(|message| message.contains("anthropic-workspace-id"))
}

/// Asks Claude about the model alone, a request with no mail in it, whether the key is refused
/// for not being scoped to a workspace.
async fn unscoped_key(client: &reqwest::Client, key: &Secret) -> bool {
    let path = format!("/v1/models/{MODEL}");
    let probe = exchange(client, key, "workspaceProbe", reqwest::Method::GET, &path, None, false).await;
    matches!(probe, Ok(reply) if reply.status == 400 && unscoped(&reply.body))
}

fn refusal(status: u16, reply: &[u8]) -> &'static str {
    if status == 400 && unscoped(reply) {
        "ai_key_workspace"
    } else {
        failure(status)
    }
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
    fn console_api_keys_are_accepted_and_admin_keys_and_tokens_are_not() {
        assert!(valid_key(&synthetic_key()));
        for kind in ["usr01", "svc01"] {
            assert!(valid_key(&format!("sk-ant-{kind}-{}", "A1b2_C3d4-".repeat(8))), "{kind}");
        }
        for refused in [
            String::new(),
            "sk-ant-api03-short".into(),
            format!("sk-ant-admin01-{}", "A".repeat(60)),
            format!("sk-ant-oat01-{}", "A".repeat(60)),
            format!("sk-ant-user01-{}", "A".repeat(60)),
            format!("sk-ant-{}", "A".repeat(60)),
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
        // A key not scoped to one workspace is refused with this 400 on every request.
        let unscoped = br#"{"type":"error","error":{"type":"invalid_request_error","message":"This API key is not scoped to a workspace, so this request must include the anthropic-workspace-id header with the ID of the workspace to use."}}"#;
        assert_eq!(refusal(400, unscoped), "ai_key_workspace");
        assert_eq!(refusal(400, br#"{"type":"error","error":{"type":"invalid_request_error","message":"messages: too long"}}"#), "overview_input_invalid");
        assert_eq!(refusal(400, b"<html>anthropic-workspace-id</html>"), "overview_input_invalid");
        assert_eq!(refusal(401, unscoped), "ai_key_invalid");
        let at = 1_800_000_000_000;
        assert_eq!(blocking(&json!({"problem":"ai_key_invalid"})), Some("ai_key_invalid"));
        assert_eq!(blocking(&json!({"problem":"ai_key_workspace"})), Some("ai_key_workspace"));
        assert_eq!(blocking(&json!({"problem":"anything else"})), None);
        assert_eq!(waiting(&json!({"retryAt":at + 1}), at), Some("ai_rate_limited"));
        assert_eq!(waiting(&json!({"retryAt":at + 1,"problem":"ai_billing"}), at), Some("ai_billing"));
        assert_eq!(waiting(&json!({"retryAt":at - 1}), at), None);
    }

    #[tokio::test]
    async fn a_failure_of_claude_stops_the_batch_and_the_rest_are_not_asked() {
        static LEFT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
        fn left() -> u64 {
            LEFT.load(std::sync::atomic::Ordering::SeqCst)
        }
        let messages = json!([{"id":"a"},{"id":"b"},{"id":"c"},{"id":"d"}]);
        let asked = std::sync::Mutex::new(Vec::new());
        let script = |outcomes: Vec<Result<&'static str, &'static str>>| {
            let asked = &asked;
            let outcomes = std::sync::Mutex::new(outcomes.into_iter());
            move |message: Value| {
                asked.lock().unwrap().push(message["id"].as_str().unwrap().to_owned());
                let next = outcomes.lock().unwrap().next().unwrap();
                async move { next.map(|text| json!([{"id":message["id"],"text":text}])) }
            }
        };
        let rows = each_message(&messages, script(vec![Ok("Paid"), Err("overview_invalid_response"), Err("ai_unreachable")]), left, left()).await.unwrap();
        assert_eq!(*asked.lock().unwrap(), ["a", "b", "c"], "the message after Claude failed is not sent");
        assert_eq!(rows[0]["text"], "Paid");
        assert_eq!(rows[1], json!({"id":"b","error":"overview_invalid_response"}), "a message's own failure does not stop the others");
        assert_eq!(rows[2], json!({"id":"c","error":"ai_unreachable"}));
        assert_eq!(rows[3], json!({"id":"d","error":"ai_unreachable","stage":"batch"}), "not asked, so not counted");
        asked.lock().unwrap().clear();
        let leaving = |message: Value| {
            LEFT.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            async move { Ok(json!([{"id":message["id"],"text":"Paid"}])) }
        };
        let rows = each_message(&messages, leaving, left, left()).await.unwrap();
        assert_eq!(rows[0]["text"], "Paid", "the message under way when the app left is finished");
        for row in &rows.as_array().unwrap()[1..] {
            assert_eq!((row["error"].as_str(), row["stage"].as_str()), (Some(INTERRUPTED), Some("batch")));
        }
        let rows = each_message(&messages, script(vec![Err("ai_key_invalid")]), left, left()).await.unwrap();
        assert_eq!(rows[3]["stage"], "batch", "a key problem stops the batch too");
        let frozen = |error: &'static str| {
            move |_: Value| {
                LEFT.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
                async move { Err(error) }
            }
        };
        let rows = each_message(&messages, frozen("ai_unreachable"), left, left()).await.unwrap();
        for row in rows.as_array().unwrap() {
            assert_eq!((row["error"].as_str(), row["stage"].as_str()), (Some(INTERRUPTED), Some("batch")), "a request iOS froze is not the message's or Claude's failure");
        }
        let rows = each_message(&messages, frozen("ai_key_invalid"), left, left()).await.unwrap();
        assert_eq!(rows[0], json!({"id":"a","error":"ai_key_invalid"}), "a refused key is reported even when the app left");
    }

    #[test]
    fn only_failures_that_say_nothing_about_the_request_are_asked_again() {
        let reply = |status: u16, retry_after: Option<u64>, should_retry: Option<bool>| -> Result<Reply, Fault> {
            Ok(Reply { status, body: Vec::new(), retry_after: retry_after.map(Duration::from_millis), should_retry })
        };
        let wait = |answer: &Result<Reply, Fault>, attempt: u32| retry_wait(answer, attempt, Duration::ZERO, 0.0);
        for status in [408, 409, 429, 500, 502, 503, 504, 529] {
            assert_eq!(wait(&reply(status, None, None), 1), Some(Duration::from_secs(1)), "{status}");
        }
        for status in [200, 400, 401, 402, 403, 404, 413] {
            assert_eq!(wait(&reply(status, None, None), 1), None, "{status} is never asked again");
        }
        let lost = Err(Fault { code: "ai_unreachable", class: "connect" });
        assert_eq!(wait(&lost, 1), Some(Duration::from_secs(1)));
        assert_eq!(wait(&lost, 2), Some(Duration::from_secs(2)));
        assert_eq!(wait(&lost, 3), Some(Duration::from_secs(4)));
        assert_eq!(wait(&lost, 4), None, "three retries at most");
        assert_eq!(retry_wait(&lost, 3, Duration::ZERO, 1.0), Some(Duration::from_secs(3)), "jitter shortens a wait by up to a quarter");
        assert_eq!(retry_wait(&lost, 1, RETRY_WINDOW, 0.0), None, "no retry once the window has passed");
        assert_eq!(wait(&Err(Fault { code: INVALID, class: "tooLarge" }), 1), None);
        assert_eq!(wait(&Err(Fault { code: "ai_key_format", class: REFUSED }), 1), None);
        assert_eq!(wait(&reply(529, Some(12_000), None), 1), Some(Duration::from_secs(12)), "Claude's wait is kept");
        assert_eq!(wait(&reply(429, Some(31_000), None), 1), None, "a long wait is left to the shared backoff");
        assert_eq!(wait(&reply(500, None, Some(false)), 1), None, "x-should-retry: false is obeyed");
        assert_eq!(wait(&reply(400, None, Some(true)), 1), Some(Duration::from_secs(1)), "x-should-retry: true is obeyed");
        let resend = |answer: &Result<Reply, Fault>, counted: bool, away: bool| resend_wait(answer, 1, Duration::ZERO, 0.0, counted, away);
        assert_eq!(resend(&lost, true, false), Some(Duration::from_secs(1)));
        assert_eq!(resend(&lost, true, true), None, "nothing is sent again while the app is away");
        assert_eq!(resend(&reply(529, None, None), true, true), None);
        assert_eq!(resend(&lost, false, false), Some(Duration::from_secs(1)), "a request never received is sent again uncounted");
        assert_eq!(resend(&Err(Fault { code: "ai_unreachable", class: "timeout" }), false, false), None, "one cut off after it was sent is not");
        assert_eq!(resend(&reply(529, None, None), false, false), Some(Duration::from_secs(1)), "an error status is not billed");
        assert_eq!(marked(Err(Fault { code: "ai_unreachable", class: "connect" }), true).err().map(|fault| fault.class), Some(SUSPENDED));
        assert_eq!(marked(Err(Fault { code: "ai_unreachable", class: "connect" }), false).err().map(|fault| fault.class), Some("connect"));
        let refused = Err(Fault { code: "ai_daily_limit", class: REFUSED });
        assert_eq!(marked(refused, true).err().map(|fault| fault.class), Some(REFUSED), "a refusal stays a refusal");
    }

    #[test]
    fn the_shared_wait_doubles_from_15_seconds_to_5_minutes_and_reads_claudes_headers() {
        let waits: Vec<i64> = (1..=8).map(backoff).collect();
        assert_eq!(waits, [15_000, 30_000, 60_000, 120_000, 240_000, 300_000, 300_000, 300_000]);
        let headers = |pairs: &[(&'static str, &str)]| {
            let mut map = reqwest::header::HeaderMap::new();
            for (name, value) in pairs {
                map.insert(*name, reqwest::header::HeaderValue::from_str(value).unwrap());
            }
            map
        };
        let at = chrono::DateTime::parse_from_rfc2822("Mon, 02 Nov 2026 08:40:14 GMT").unwrap().timestamp_millis();
        assert_eq!(retry_after(&headers(&[("retry-after-ms", "1500"), ("retry-after", "9")]), at), Some(Duration::from_millis(1500)));
        assert_eq!(retry_after(&headers(&[("retry-after", "9")]), at), Some(Duration::from_secs(9)));
        assert_eq!(retry_after(&headers(&[("retry-after", "Mon, 02 Nov 2026 08:41:14 GMT")]), at), Some(Duration::from_secs(60)));
        assert_eq!(retry_after(&headers(&[("retry-after", "Mon, 02 Nov 2026 08:00:00 GMT")]), at), None, "a time already past is ignored");
        assert_eq!(retry_after(&headers(&[("retry-after", "0")]), at), None, "no wait means the request's own backoff");
        assert_eq!(retry_after(&headers(&[("retry-after", "999999999")]), at), Some(Duration::from_secs(3_600)), "at most an hour");
        assert_eq!(retry_after(&headers(&[("retry-after", "soon")]), at), None);
        assert_eq!(retry_after(&headers(&[("retry-after-ms", "-5")]), at), None);
        assert_eq!(retry_after(&headers(&[]), at), None);
        assert_eq!(waiting(&json!({"retryAt":at + 1,"problem":"ai_rate_limited","backoff":2}), at), Some("ai_rate_limited"));
    }

}
