//! OpenAI's image API for sender pictures. The key travels only in a sensitive Authorization
//! header to the fixed OpenAI origin; requests never follow redirects or use a proxy.
use crate::credentials::Secret;
use base64::{Engine, engine::general_purpose::STANDARD};
use serde_json::{Value, json};
use std::time::Duration;

#[cfg_attr(test, allow(dead_code))]
const ORIGIN: &str = "https://api.openai.com";
/// The size and quality Marmalade paints its avatars at (`OpenAI::ImageClient`, `ImageCodec`).
const SIZE: &str = "1024x1024";
const QUALITY: &str = "medium";
const REPLY_LIMIT: usize = 24 * 1024 * 1024;
/// One picture can take more than two minutes; Marmalade waits 300 seconds.
const TIMEOUT: Duration = Duration::from_secs(300);
/// Reserved before each request, and charged when a reply gives no usage. A generous bound:
/// Marmalade estimated 7 cents for one medium 1024 picture with gpt-image-2, and Sunburst's
/// reported usage came to 1.4 cents for a monogram and 2.3 cents for a logo on 2 November 2026.
pub(super) const ESTIMATE_CENTS: i64 = 7;

pub(super) enum Request {
    Generate { prompt: String },
    Edit { prompt: String, reference: Vec<u8> },
}

pub(super) struct Painted {
    pub png: Vec<u8>,
    /// What the picture cost in whole cents, rounded up, as the daily limit counts it.
    pub cents: i64,
    /// What the picture cost in millionths of a dollar, as the spending page counts it.
    pub micro_dollars: i64,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Fault {
    /// OpenAI does not accept the key, or the key may not use this model.
    Key(&'static str),
    /// The key's account has no credit left.
    Billing,
    /// Too many requests; the wait OpenAI asked for, if any, in milliseconds.
    RateLimited(Option<i64>),
    /// OpenAI does not offer the model to this key.
    Model,
    /// OpenAI refused this picture, for example by its safety system, or could not read its
    /// reference. Asking again would get the same answer.
    Refused,
    /// OpenAI rejected the shape of the request (an unknown or missing parameter) or a setting
    /// every picture shares, such as the model, size or quality. Every picture would get the same
    /// answer.
    Rejected,
    /// No answer: lost connection, timeout or a server error. `charged` is true when the request
    /// may have been billed before the answer was lost.
    Lost { charged: bool },
}

#[cfg(test)]
tokio::task_local! {
    static TEST_TRANSPORT: (reqwest::Client, String);
}

/// Sends this future's OpenAI requests to a local test server instead of OpenAI.
#[cfg(test)]
pub(super) async fn with_test_transport<T>(
    client: reqwest::Client,
    origin: String,
    work: impl std::future::Future<Output = T>,
) -> T {
    TEST_TRANSPORT.scope((client, origin), work).await
}

#[cfg_attr(test, allow(dead_code))]
fn client() -> Result<reqwest::Client, Fault> {
    static CLIENT: std::sync::OnceLock<Option<reqwest::Client>> = std::sync::OnceLock::new();
    CLIENT
        .get_or_init(|| {
            crate::platform::http_client()
                .no_proxy()
                .https_only(true)
                .redirect(reqwest::redirect::Policy::none())
                .connect_timeout(Duration::from_secs(10))
                .timeout(TIMEOUT)
                .build()
                .ok()
        })
        .clone()
        .ok_or(Fault::Lost { charged: false })
}

/// Carries the caller's test transport into a spawned task; outside tests it returns `work`.
#[cfg(test)]
pub(super) fn inherit<F: std::future::Future>(work: F) -> impl std::future::Future<Output = F::Output> {
    let transport = TEST_TRANSPORT.try_with(Clone::clone).ok();
    async move {
        match transport {
            Some(transport) => TEST_TRANSPORT.scope(transport, work).await,
            None => work.await,
        }
    }
}
#[cfg(not(test))]
pub(super) fn inherit<F: std::future::Future>(work: F) -> F {
    work
}

/// Invariant: a test without a local test server never reaches OpenAI; it fails as unreachable.
fn transport() -> Result<(reqwest::Client, String), Fault> {
    #[cfg(test)]
    return TEST_TRANSPORT
        .try_with(Clone::clone)
        .map_err(|_| Fault::Lost { charged: false });
    #[cfg(not(test))]
    Ok((client()?, ORIGIN.to_owned()))
}

fn authorization(key: &Secret) -> Result<reqwest::header::HeaderValue, Fault> {
    let text = key.text().map_err(|_| Fault::Key("pictures_key_invalid"))?;
    let mut value = reqwest::header::HeaderValue::from_str(&format!("Bearer {text}"))
        .map_err(|_| Fault::Key("pictures_key_invalid"))?;
    value.set_sensitive(true);
    Ok(value)
}

/// An OpenAI secret key: `sk-` and URL-safe characters only. A Claude key (`sk-ant-`) is refused,
/// so a key pasted in the wrong place is never sent to OpenAI.
pub(super) fn valid_key(key: &str) -> bool {
    (20..=512).contains(&key.len())
        && key.starts_with("sk-")
        && !key.starts_with("sk-ant-")
        && key
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
}

/// Asks whether the key may use the model, without painting anything.
pub(super) async fn check(key: &Secret, model: &str) -> Result<(), Fault> {
    let (client, origin) = transport()?;
    let response = client
        .get(format!("{origin}/v1/models/{model}"))
        .header(reqwest::header::AUTHORIZATION, authorization(key)?)
        .timeout(Duration::from_secs(30))
        .send()
        .await
        .map_err(|_| Fault::Lost { charged: false })?;
    let status = response.status().as_u16();
    let retry = retry_after(response.headers());
    let body = read(response).await.map_err(|_| Fault::Lost { charged: false })?;
    if status == 200 {
        return Ok(());
    }
    Err(classify(status, &body, retry))
}

pub(super) async fn paint(key: &Secret, model: &str, request: &Request) -> Result<Painted, Fault> {
    let (client, origin) = transport()?;
    let builder = match request {
        Request::Generate { prompt } => client
            .post(format!("{origin}/v1/images/generations"))
            .header(reqwest::header::CONTENT_TYPE, "application/json")
            .body(
                serde_json::to_vec(&json!({"model":model,"prompt":prompt,"size":SIZE,"quality":QUALITY,"n":1}))
                    .map_err(|_| Fault::Refused)?,
            ),
        Request::Edit { prompt, reference } => {
            let boundary = boundary();
            let body = multipart(
                &boundary,
                &[("model", model), ("prompt", prompt), ("size", SIZE), ("quality", QUALITY), ("n", "1")],
                reference,
            );
            client
                .post(format!("{origin}/v1/images/edits"))
                .header(
                    reqwest::header::CONTENT_TYPE,
                    format!("multipart/form-data; boundary={boundary}"),
                )
                .body(body)
        }
    };
    let response = builder
        .header(reqwest::header::AUTHORIZATION, authorization(key)?)
        .send()
        .await
        .map_err(|error| Fault::Lost { charged: !error.is_connect() })?;
    let status = response.status().as_u16();
    let retry = retry_after(response.headers());
    let body = read(response).await.map_err(|_| Fault::Lost { charged: true })?;
    if status != 200 {
        return Err(classify(status, &body, retry));
    }
    parse(&body)
}

async fn read(mut response: reqwest::Response) -> Result<Vec<u8>, ()> {
    let mut body = Vec::new();
    while let Some(chunk) = response.chunk().await.map_err(|_| ())? {
        if body.len() + chunk.len() > REPLY_LIMIT {
            return Err(());
        }
        body.extend_from_slice(&chunk);
    }
    Ok(body)
}

fn boundary() -> String {
    use sha2::{Digest, Sha256};
    let mut hash = Sha256::new();
    hash.update(super::super::now().to_le_bytes());
    hash.update(std::process::id().to_le_bytes());
    static COUNTER: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    hash.update(COUNTER.fetch_add(1, std::sync::atomic::Ordering::Relaxed).to_le_bytes());
    format!("----MagpieBoundary{:x}", hash.finalize())
}

/// A multipart body with text fields and one PNG named `image`, as Marmalade sends edits.
/// Invariant: field values are Magpie's own prompt text and constants; the boundary is a hash, so
/// it cannot occur in them by accident, and the image is the only binary part.
fn multipart(boundary: &str, fields: &[(&str, &str)], image: &[u8]) -> Vec<u8> {
    let mut body = Vec::with_capacity(image.len() + 4096);
    for (name, value) in fields {
        body.extend_from_slice(format!("--{boundary}\r\nContent-Disposition: form-data; name=\"{name}\"\r\n\r\n{value}\r\n").as_bytes());
    }
    body.extend_from_slice(
        format!("--{boundary}\r\nContent-Disposition: form-data; name=\"image\"; filename=\"reference.png\"\r\nContent-Type: image/png\r\n\r\n").as_bytes(),
    );
    body.extend_from_slice(image);
    body.extend_from_slice(format!("\r\n--{boundary}--\r\n").as_bytes());
    body
}

fn retry_after(headers: &reqwest::header::HeaderMap) -> Option<i64> {
    let text = |name: &str| headers.get(name).and_then(|value| value.to_str().ok()).map(str::trim);
    let millis = if let Some(ms) = text("retry-after-ms").and_then(|value| value.parse::<f64>().ok()) {
        ms
    } else {
        text("retry-after").and_then(|value| value.parse::<f64>().ok())? * 1000.0
    };
    (millis.is_finite() && millis > 0.0).then(|| millis.min(3_600_000.0) as i64)
}

/// Whether a refusal is about the request's shape (an unknown or missing parameter, whichever
/// field it names) or a setting every picture shares, rather than this picture's prompt or
/// reference, or no setting at all as with the safety system's refusals.
fn setting(reply: &Value) -> bool {
    let error = &reply["error"];
    matches!(error["code"].as_str(), Some("unknown_parameter" | "missing_required_parameter"))
        || matches!(error["param"].as_str(), Some("model" | "size" | "quality" | "n"))
}

/// What a refused request means for the painter. Only OpenAI's error code and type are read; the
/// message text is never shown or stored.
fn classify(status: u16, body: &[u8], retry: Option<i64>) -> Fault {
    let reply: Value = serde_json::from_slice(body).unwrap_or(Value::Null);
    let code = reply["error"]["code"].as_str().unwrap_or("");
    let kind = reply["error"]["type"].as_str().unwrap_or("");
    let billing = matches!(code, "insufficient_quota" | "billing_hard_limit_reached" | "billing_not_active")
        || kind == "insufficient_quota";
    match status {
        _ if billing => Fault::Billing,
        401 => Fault::Key("pictures_key_invalid"),
        403 => Fault::Key("pictures_key_refused"),
        404 => Fault::Model,
        429 => Fault::RateLimited(retry),
        400 | 413 | 415 | 422 if setting(&reply) && code != "moderation_blocked" => Fault::Rejected,
        400 | 413 | 415 | 422 => Fault::Refused,
        _ => Fault::Lost { charged: false },
    }
}

/// The first picture of a 200 reply and what it cost, from the reply's usage at gpt-image-2.5
/// Sunburst's list prices (text in $5, image in $8, image out $30 per million tokens), or the estimate.
fn parse(body: &[u8]) -> Result<Painted, Fault> {
    let reply: Value = serde_json::from_slice(body).map_err(|_| Fault::Lost { charged: true })?;
    let encoded = reply["data"][0]["b64_json"]
        .as_str()
        .filter(|text| !text.is_empty())
        .ok_or(Fault::Lost { charged: true })?;
    let png = STANDARD
        .decode(encoded)
        .map_err(|_| Fault::Lost { charged: true })?;
    let usage = &reply["usage"];
    Ok(Painted { png, cents: cents(usage), micro_dollars: micro_dollars(usage) })
}

/// What a reply's usage cost in millionths of a dollar, or the estimate when it gives no usage.
fn micro_dollars(usage: &Value) -> i64 {
    let count = |value: &Value| value.as_i64().filter(|n| *n >= 0);
    let Some(output) = count(&usage["output_tokens"]) else {
        return ESTIMATE_CENTS * 10_000;
    };
    let details = &usage["input_tokens_details"];
    let (text, image) = match (count(&details["text_tokens"]), count(&details["image_tokens"])) {
        (Some(text), Some(image)) => (text, image),
        _ => (count(&usage["input_tokens"]).unwrap_or(0), 0),
    };
    // A million tokens at $1 is one micro-dollar per token.
    text.saturating_mul(5).saturating_add(image.saturating_mul(8)).saturating_add(output.saturating_mul(30))
}

fn cents(usage: &Value) -> i64 {
    // A cent is 10,000 micro-dollars.
    (micro_dollars(usage).saturating_add(9_999) / 10_000).max(1)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn tests_without_a_local_server_send_nothing() {
        let key = Secret::new(b"sk-synthetic-test-key-0000000000".to_vec()).unwrap();
        let request = Request::Generate { prompt: "x".into() };
        assert!(matches!(paint(&key, "gpt-image-2.5-sunburst", &request).await, Err(Fault::Lost { charged: false })));
        assert_eq!(check(&key, "gpt-image-2.5-sunburst").await.unwrap_err(), Fault::Lost { charged: false });
    }

    #[test]
    fn refusals_are_sorted_by_who_can_fix_them() {
        let body = |code: &str| format!(r#"{{"error":{{"code":"{code}","type":"x","message":"secret text"}}}}"#).into_bytes();
        assert_eq!(classify(401, b"", None), Fault::Key("pictures_key_invalid"));
        assert_eq!(classify(403, &body("x"), None), Fault::Key("pictures_key_refused"));
        assert_eq!(classify(429, &body("insufficient_quota"), Some(5)), Fault::Billing);
        assert_eq!(classify(400, &body("billing_hard_limit_reached"), None), Fault::Billing);
        assert_eq!(classify(429, &body("rate_limit_exceeded"), Some(2000)), Fault::RateLimited(Some(2000)));
        assert_eq!(classify(400, &body("moderation_blocked"), None), Fault::Refused);
        let named = |code: &str, param: &str| {
            format!(r#"{{"error":{{"code":"{code}","type":"invalid_request_error","param":"{param}","message":"secret"}}}}"#).into_bytes()
        };
        assert_eq!(classify(400, &named("invalid_value", "quality"), None), Fault::Rejected);
        assert_eq!(classify(400, &named("unknown_parameter", "n"), None), Fault::Rejected);
        assert_eq!(classify(400, &named("unknown_parameter", "image"), None), Fault::Rejected);
        assert_eq!(classify(422, &named("missing_required_parameter", "prompt"), None), Fault::Rejected);
        assert_eq!(classify(400, &named("moderation_blocked", "prompt"), None), Fault::Refused);
        assert_eq!(classify(400, &named("moderation_blocked", "quality"), None), Fault::Refused);
        assert_eq!(classify(400, &named("content_policy_violation", "prompt"), None), Fault::Refused);
        assert_eq!(classify(400, &named("invalid_image_file", "image"), None), Fault::Refused);
        assert_eq!(classify(400, &named("invalid_value", "prompt"), None), Fault::Refused);
        assert_eq!(classify(400, &named("x", ""), None), Fault::Refused);
        // A safety refusal that names no parameter.
        let safety = br#"{"error":{"message":"Your request was rejected by the safety system.","type":"image_generation_user_error","param":null,"code":"moderation_blocked"}}"#;
        assert_eq!(classify(400, safety, None), Fault::Refused);
        assert_eq!(classify(404, &body("model_not_found"), None), Fault::Model);
        assert_eq!(classify(500, b"<html>", None), Fault::Lost { charged: false });
        assert_eq!(classify(503, b"", None), Fault::Lost { charged: false });
    }

    #[test]
    fn cost_comes_from_usage_or_the_estimate() {
        assert_eq!(cents(&Value::Null), ESTIMATE_CENTS);
        let usage = json!({"input_tokens":1300,"input_tokens_details":{"text_tokens":300,"image_tokens":1000},"output_tokens":2000});
        // 300 × 5 + 1000 × 8 + 2000 × 30 = 69,500 micro-dollars, 7 cents rounded up.
        assert_eq!(cents(&usage), 7);
        assert_eq!(cents(&json!({"input_tokens":200,"output_tokens":0})), 1);
        assert_eq!(cents(&json!({"output_tokens":-5})), ESTIMATE_CENTS);
    }

    #[test]
    fn keys_are_openai_secret_keys_only() {
        assert!(valid_key("sk-proj-abcdefghijklmnopqrstuvwxyz0123456789"));
        assert!(valid_key("sk-svcacct-ABCDEFGHIJKLMNOPQRSTUVWXYZ_-12"));
        for key in ["", "sk-short", "pk-abcdefghijklmnopqrstuvwxyz", "sk-abc def ghijklmnopqrstuvwxyz", "sk-abcdefghijklmnopqrstuvwxyz\n", "sk-abcdefghijklmnopqrstu\"vwxyz"] {
            assert!(!valid_key(key), "{key:?}");
        }
        assert!(!valid_key(&format!("sk-{}", "a".repeat(510))));
        assert!(!valid_key("sk-ant-api03-abcdefghijklmnopqrstuvwxyz0123456789"), "a Claude key is never sent to OpenAI");
    }

    #[test]
    fn edits_send_fields_then_one_png() {
        let body = multipart("--b", &[("model", "gpt-image-2.5-sunburst"), ("prompt", "line one\nline two")], b"\x89PNG");
        let text = String::from_utf8_lossy(&body);
        assert!(text.starts_with("----b\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\ngpt-image-2.5-sunburst\r\n"));
        assert!(text.contains("name=\"prompt\"\r\n\r\nline one\nline two\r\n"));
        assert!(text.contains("name=\"image\"; filename=\"reference.png\"\r\nContent-Type: image/png\r\n\r\n\u{FFFD}PNG\r\n----b--\r\n"));
        assert_ne!(boundary(), boundary());
    }

    #[test]
    fn replies_without_a_picture_are_not_pictures() {
        assert!(parse(br#"{"data":[]}"#).is_err());
        assert!(parse(br#"{"data":[{"b64_json":"!!"}]}"#).is_err());
        let painted = parse(br#"{"data":[{"b64_json":"iVBORw=="}],"usage":{"output_tokens":2000,"input_tokens":10}}"#).unwrap();
        assert_eq!(painted.png, b"\x89PNG");
        assert_eq!(painted.cents, 7);
        // Sunburst's reply shape from a test request on 2026-11-02, with a stand-in picture. The
        // output details split the same output tokens and are not counted again.
        let sunburst = br#"{"background":"opaque","created":1,"data":[{"b64_json":"iVBORw==","generation_id":"g"}],"output_format":"png","quality":"medium","size":"1024x1024","usage":{"input_tokens":1246,"input_tokens_details":{"image_tokens":1024,"text_tokens":222},"output_tokens":439,"output_tokens_details":{"image_tokens":439,"text_tokens":0},"total_tokens":1685}}"#;
        let painted = parse(sunburst).unwrap();
        assert_eq!(painted.png, b"\x89PNG");
        // 222 x $5 + 1,024 x $8 + 439 x $30 per million tokens is 2.25 cents, rounded up.
        assert_eq!(painted.cents, 3);
    }
}
