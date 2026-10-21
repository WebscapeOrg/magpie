//! Native, pooled HTTP to fixed Google origins. Errors never include request data.
use serde_json::Value;
use std::{
    sync::{
        Arc, OnceLock,
        atomic::{AtomicU64, Ordering},
    },
    time::Duration,
};

#[path = "gmail_diagnostics.rs"]
mod diagnostics;

pub(crate) async fn flush_diagnostics() {
    diagnostics::flush().await;
}
#[path = "gmail_quota.rs"]
mod quota;
pub use quota::{Budget, Lane};

#[cfg(test)]
#[path = "gmail_http_runtime_tests.rs"]
mod runtime_tests;

#[derive(Clone)]
struct Request {
    url: String,
    method: reqwest::Method,
    content_type: &'static str,
    authorization: Option<reqwest::header::HeaderValue>,
    body: Option<String>,
    operation: &'static str,
    cost: u32,
    budget: Option<(Arc<Budget>, Lane)>,
    response_limit: usize,
}

const MAX_INPUT: usize = 64 * 1024;
const MAX_RESPONSE: usize = 16 * 1024 * 1024;
const DEADLINE: Duration = Duration::from_secs(20);
// Invariant: Only an explicit rate-limit refusal is retried; timeouts remain ambiguous.
const RATE_LIMIT_BACKOFF: Duration = Duration::from_secs(1);
const RATE_LIMIT_RETRIES: usize = 3;
static REQUEST_SERIAL: AtomicU64 = AtomicU64::new(0);
static CLIENT: OnceLock<Result<reqwest::Client, &'static str>> = OnceLock::new();

// Invariant: The integration fixture exercises the real dispatcher, credential reader and
// request serializer. This override exists only in test builds and only inside
// its task scope; production has no environment/configuration bypass.
#[cfg(test)]
tokio::task_local! {
    static TEST_TRANSPORT: (reqwest::Client, String);
}

/// The queue drainer runs in its own task and inherits the scope explicitly.
#[cfg(test)]
pub(crate) fn current_test_transport() -> Option<(reqwest::Client, String)> {
    TEST_TRANSPORT.try_with(Clone::clone).ok()
}

#[cfg(test)]
pub(crate) async fn with_test_transport<T>(
    client: reqwest::Client,
    origin: String,
    work: impl std::future::Future<Output = T>,
) -> T {
    TEST_TRANSPORT.scope((client, origin), work).await
}

fn client() -> Result<&'static reqwest::Client, &'static str> {
    CLIENT
        .get_or_init(build_client)
        .as_ref()
        .map_err(|error| *error)
}

fn client_builder() -> reqwest::ClientBuilder {
    reqwest::Client::builder()
        .https_only(true)
        .hickory_dns(true)
        .redirect(reqwest::redirect::Policy::none())
        .no_proxy()
        .connect_timeout(Duration::from_secs(10))
        .timeout(DEADLINE)
}

fn build_client() -> Result<reqwest::Client, &'static str> {
    client_builder().build().map_err(|_| "gmail_http_failed")
}

/// Path entries are individual components, never an arbitrary URL or slash path.
pub async fn get(
    path: &[&str],
    query: &[(String, String)],
    token: &str,
) -> Result<Value, &'static str> {
    let request = prepare_get(path, query, token)?;
    execute(client()?, request, DEADLINE).await
}

pub async fn refresh(id: &str, secret: &str, token: &str) -> Result<Value, &'static str> {
    let request = prepare_refresh(id, secret, token)?;
    execute(client()?, request, DEADLINE).await
}

fn http_error(error: reqwest::Error) -> &'static str {
    if error.is_timeout() {
        "gmail_timeout"
    } else {
        "gmail_http_failed"
    }
}

async fn execute(
    client: &reqwest::Client,
    request: Request,
    deadline: Duration,
) -> Result<Value, &'static str> {
    execute_with_backoff(client, request, deadline, RATE_LIMIT_BACKOFF).await
}

/// The whole retry budget, waits included, stays inside `deadline`.
async fn execute_with_backoff(
    client: &reqwest::Client,
    request: Request,
    deadline: Duration,
    backoff: Duration,
) -> Result<Value, &'static str> {
    #[cfg(test)]
    let test_transport = TEST_TRANSPORT.try_with(Clone::clone).ok();
    #[cfg(test)]
    let (client, request) = if let Some((ref client, ref origin)) = test_transport {
        let mut request = request;
        let url = reqwest::Url::parse(&request.url).unwrap();
        assert_eq!(url.scheme(), "https");
        assert!(matches!(
            url.host_str(),
            Some("gmail.googleapis.com" | "oauth2.googleapis.com")
        ));
        request.url = format!("{origin}{}", url.path());
        if let Some(query) = url.query() {
            request.url.push('?');
            request.url.push_str(query);
        }
        (client, request)
    } else {
        (client, request)
    };
    let started = tokio::time::Instant::now();
    let request_id = REQUEST_SERIAL.fetch_add(1, Ordering::Relaxed) + 1;
    for retry in 0..=RATE_LIMIT_RETRIES {
        let mut observed = Observation::default();
        let waiting = tokio::time::Instant::now();
        let permit = if let Some((budget, lane)) = &request.budget {
            match budget
                .acquire(request.cost, *lane, started + deadline)
                .await
            {
                Ok(permit) => Some(permit),
                Err(error) => {
                    observed.reason = if error == "gmail_session_invalidated" {
                        "sessionInvalidated"
                    } else {
                        "localBudget"
                    };
                    log_attempt(
                        &request,
                        request_id,
                        retry,
                        &observed,
                        waiting.elapsed(),
                        started.elapsed(),
                        Err(error),
                    )
                    .await;
                    return Err(error);
                }
            }
        } else {
            None
        };
        let waited = waiting.elapsed();
        let remaining = deadline.saturating_sub(started.elapsed());
        let answer = attempt(client, request.clone(), remaining, &mut observed).await;
        drop(permit);
        let jitter = backoff.as_nanos() as u64 / 2;
        let jitter = Duration::from_nanos(
            std::time::SystemTime::UNIX_EPOCH
                .elapsed()
                .map_or(0, |t| t.subsec_nanos() as u64)
                % jitter.max(1),
        );
        let wait = (backoff.saturating_mul(1 << retry) + jitter)
            .max(observed.retry_after.unwrap_or_default());
        if answer == Err("gmail_rate_limited") {
            if let Some((budget, _)) = &request.budget {
                budget.cool_down(wait).await;
            }
        }
        log_attempt(
            &request,
            request_id,
            retry,
            &observed,
            waited,
            started.elapsed(),
            answer.as_ref().map(|_| ()).map_err(|e| *e),
        )
        .await;
        if answer != Err("gmail_rate_limited")
            || retry == RATE_LIMIT_RETRIES
            || started.elapsed() + wait >= deadline
        {
            return answer;
        }
        tokio::time::sleep(wait).await;
    }
    unreachable!()
}

#[derive(Default)]
struct Observation {
    status: Option<u16>,
    reason: &'static str,
    retry_after: Option<Duration>,
}

async fn log_attempt(
    request: &Request,
    serial: u64,
    retry: usize,
    observed: &Observation,
    waited: Duration,
    elapsed: Duration,
    answer: Result<(), &'static str>,
) {
    let (session, lane) = request
        .budget
        .as_ref()
        .map(|(b, l)| (b.id, l.name()))
        .unwrap_or((0, "auth"));
    diagnostics::record(diagnostics::Event {
        time: chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string(),
        process: std::process::id(),
        session,
        request: serial,
        rpc: crate::backend::diagnostics::current(),
        operation: request.operation.into(),
        lane: lane.into(),
        cost: request.cost,
        attempt: retry + 1,
        status: observed.status,
        reason: if observed.reason.is_empty() {
            "unknown"
        } else {
            observed.reason
        }
        .into(),
        retry_after_ms: observed
            .retry_after
            .map(|d| d.as_millis().min(u64::MAX as u128) as u64),
        wait_ms: waited.as_millis().min(u64::MAX as u128) as u64,
        elapsed_ms: elapsed.as_millis().min(u64::MAX as u128) as u64,
        outcome: answer.err().unwrap_or("ok").into(),
    })
    .await;
}

async fn attempt(
    client: &reqwest::Client,
    request: Request,
    deadline: Duration,
    observed: &mut Observation,
) -> Result<Value, &'static str> {
    tokio::time::timeout(deadline, async {
        let empty_success =
            request.authorization.is_some() && request.method != reqwest::Method::GET;
        let empty_post = request.body.is_none()
            && matches!(
                request.method,
                reqwest::Method::POST | reqwest::Method::PUT | reqwest::Method::PATCH
            );
        let mut builder = client.request(request.method, &request.url);
        if let Some(body) = request.body {
            builder = builder
                .header(reqwest::header::CONTENT_TYPE, request.content_type)
                .body(body);
        } else if empty_post {
            // Invariant: Bodyless Gmail trash/untrash requests still need explicit framing.
            // Some gateways reject a POST without Content-Length with HTTP 411.
            builder = builder.header(reqwest::header::CONTENT_LENGTH, "0");
        }
        if let Some(authorization) = request.authorization {
            builder = builder.header(reqwest::header::AUTHORIZATION, authorization);
        }
        let mut response = builder.send().await.map_err(http_error)?;
        let status = response.status().as_u16();
        observed.status = Some(status);
        if !response.status().is_success() {
            observed.retry_after = response
                .headers()
                .get(reqwest::header::RETRY_AFTER)
                .and_then(|v| v.to_str().ok())
                .and_then(retry_after);
            let body = error_body(&mut response).await;
            observed.reason = error_reason(&body);
            observed.retry_after = observed
                .retry_after
                .into_iter()
                .chain(body_retry_after(&body))
                .max();
            return Err(match status {
                401 => "gmail_unauthorized",
                403 if matches!(
                    observed.reason,
                    "rateLimitExceeded" | "userRateLimitExceeded"
                ) =>
                {
                    "gmail_rate_limited"
                }
                403 => "gmail_forbidden",
                404 => "gmail_not_found",
                411 => "gmail_length_required",
                429 => "gmail_rate_limited",
                _ => "gmail_http_failed",
            });
        }
        if response
            .content_length()
            .is_some_and(|size| size > request.response_limit as u64)
        {
            return Err("gmail_response_too_large");
        }
        let mut bytes = Vec::new();
        while let Some(chunk) = response.chunk().await.map_err(http_error)? {
            if chunk.len() > request.response_limit - bytes.len() {
                return Err("gmail_response_too_large");
            }
            bytes.extend_from_slice(&chunk);
        }
        if bytes.is_empty() && empty_success {
            return Ok(serde_json::json!({}));
        }
        let value: Value = serde_json::from_slice(&bytes).map_err(|_| "gmail_invalid_response")?;
        if !value.is_object() {
            return Err("gmail_invalid_response");
        }
        Ok(value)
    })
    .await
    .map_err(|_| "gmail_timeout")?
}

async fn error_body(response: &mut reqwest::Response) -> Value {
    let mut bytes = Vec::new();
    loop {
        match response.chunk().await {
            Ok(Some(chunk)) if chunk.len() <= MAX_INPUT - bytes.len() => {
                bytes.extend_from_slice(&chunk)
            }
            Ok(None) => return serde_json::from_slice(&bytes).unwrap_or(Value::Null),
            _ => return Value::Null,
        }
    }
}

fn error_reason(body: &Value) -> &'static str {
    let errors = body["error"]["errors"].as_array().into_iter().flatten();
    for error in errors {
        match (error["domain"].as_str(), error["reason"].as_str()) {
            (Some("usageLimits"), Some("rateLimitExceeded")) => return "rateLimitExceeded",
            (Some("usageLimits"), Some("userRateLimitExceeded")) => return "userRateLimitExceeded",
            (Some("usageLimits"), Some("dailyLimitExceeded")) => return "dailyLimitExceeded",
            (_, Some("insufficientPermissions")) => return "insufficientPermissions",
            (_, Some("domainPolicy")) => return "domainPolicy",
            (_, Some("authError")) => return "authError",
            _ => (),
        }
    }
    "unknown"
}
fn retry_after(value: &str) -> Option<Duration> {
    if !value.is_empty() && value.bytes().all(|b| b.is_ascii_digit()) {
        return value
            .parse::<u64>()
            .ok()
            .map(|s| Duration::from_secs(s.min(86400)));
    }
    let date = chrono::DateTime::parse_from_rfc2822(value).ok()?;
    Some(Duration::from_millis(
        (date.timestamp_millis() - chrono::Utc::now().timestamp_millis()).clamp(0, 86400000) as u64,
    ))
}
fn body_retry_after(body: &Value) -> Option<Duration> {
    static RETRY_TIME: OnceLock<regex::Regex> = OnceLock::new();
    let pattern = RETRY_TIME.get_or_init(|| {
        regex::Regex::new(r"Retry after (\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d{1,9})?Z)").unwrap()
    });
    let mut wait = None;
    let mut messages = vec![body["error"]["message"].as_str().unwrap_or("")];
    for error in body["error"]["errors"].as_array().into_iter().flatten() {
        messages.push(error["message"].as_str().unwrap_or(""));
    }
    for message in messages {
        let Some(captures) = pattern.captures(message) else {
            continue;
        };
        let Ok(date) = chrono::DateTime::parse_from_rfc3339(&captures[1]) else {
            continue;
        };
        let duration = Duration::from_millis(
            (date.timestamp_millis() - chrono::Utc::now().timestamp_millis()).clamp(0, 86400000)
                as u64,
        );
        wait = wait.into_iter().chain(Some(duration)).max();
    }
    for detail in body["error"]["details"].as_array().into_iter().flatten() {
        if detail["@type"] != "type.googleapis.com/google.rpc.RetryInfo" {
            continue;
        }
        let Some(seconds) = detail["retryDelay"]
            .as_str()
            .and_then(|seconds| seconds.strip_suffix('s'))
            .and_then(|seconds| seconds.parse::<f64>().ok())
            .filter(|seconds| seconds.is_finite() && *seconds >= 0.0)
        else {
            continue;
        };
        wait = wait
            .into_iter()
            .chain(Some(Duration::from_secs_f64(seconds.min(86400.0))))
            .max();
    }
    wait
}

fn read_operation(path: &[&str], query: &[(String, String)]) -> (&'static str, u32) {
    let full = !query
        .iter()
        .any(|(k, v)| k == "format" && matches!(v.as_str(), "metadata" | "minimal"));
    match path {
        ["profile"] => ("getProfile", 1),
        ["history"] => ("history.list", 2),
        ["labels"] => ("labels.list", 1),
        ["labels", _] => ("labels.get", 1),
        ["settings", "sendAs"] => ("settings.sendAs.list", 1),
        ["messages"] => ("messages.list", 5),
        ["messages", _] if full => ("messages.get.full", 60),
        ["messages", _] => ("messages.get.metadata", 20),
        ["messages", _, "attachments", _] => ("messages.attachments.get", 20),
        ["threads", _] if full => ("threads.get.full", 120),
        ["threads", _] => ("threads.get.metadata", 40),
        ["drafts"] => ("drafts.list", 5),
        _ => ("gmail.request", 100),
    }
}
fn write_operation(method: &reqwest::Method, path: &[&str]) -> (&'static str, u32) {
    match (method.as_str(), path) {
        ("POST", ["messages", "send"]) => ("messages.send", 100),
        ("POST", ["messages", "batchModify"]) => ("messages.batchModify", 50),
        ("POST", ["messages", _, "modify"]) => ("messages.modify", 5),
        ("POST", ["messages", _, "trash"]) => ("messages.trash", 20),
        ("POST", ["messages", _, "untrash"]) => ("messages.untrash", 5),
        ("POST", ["labels"]) => ("labels.create", 5),
        ("PATCH", ["labels", _]) => ("labels.update", 5),
        ("DELETE", ["labels", _]) => ("labels.delete", 5),
        ("POST", ["drafts"]) => ("drafts.create", 10),
        ("PUT", ["drafts", _]) => ("drafts.update", 15),
        ("DELETE", ["drafts", _]) => ("drafts.delete", 10),
        _ => ("gmail.request", 100),
    }
}

pub async fn get_paced(
    path: &[&str],
    query: &[(String, String)],
    token: &str,
    budget: &Arc<Budget>,
    lane: Lane,
) -> Result<Value, &'static str> {
    let mut request = prepare_get(path, query, token)?;
    request.budget = Some((Arc::clone(budget), lane));
    execute(client()?, request, DEADLINE).await
}

pub(crate) async fn get_replica(
    path: &[&str],
    query: &[(String, String)],
    token: &str,
    budget: &Arc<Budget>,
) -> Result<Value, &'static str> {
    static SLOTS: tokio::sync::Semaphore = tokio::sync::Semaphore::const_new(2);
    let _slot = SLOTS
        .acquire()
        .await
        .map_err(|_| "gmail_session_invalidated")?;
    let mut request = prepare_get(path, query, token)?;
    request.budget = Some((budget.clone(), Lane::Background));
    request.response_limit = 128 * 1024 * 1024;
    execute(client()?, request, Duration::from_secs(60)).await
}
pub async fn write_paced(
    method: reqwest::Method,
    path: &[&str],
    body: Option<&Value>,
    token: &str,
    budget: &Arc<Budget>,
    lane: Lane,
) -> Result<Value, &'static str> {
    let mut request = prepare_write(method, path, body, token)?;
    request.budget = Some((Arc::clone(budget), lane));
    execute(client()?, request, DEADLINE).await
}

fn valid(value: &str) -> Result<(), &'static str> {
    if value.len() > MAX_INPUT || value.bytes().any(|b| b < 32 || b == 127) {
        return Err("gmail_invalid_input");
    }
    Ok(())
}

pub(super) fn validate_path_part(value: &str) -> Result<(), &'static str> {
    valid(value)?;
    if value.is_empty() || matches!(value, "." | "..") {
        return Err("gmail_invalid_input");
    }
    Ok(())
}

fn encode(value: &str) -> String {
    const HEX: &[u8] = b"0123456789ABCDEF";
    let mut result = String::new();
    for byte in value.bytes() {
        if byte.is_ascii_alphanumeric() || b"-._~".contains(&byte) {
            result.push(byte as char);
        } else {
            result.push('%');
            result.push(HEX[(byte >> 4) as usize] as char);
            result.push(HEX[(byte & 15) as usize] as char);
        }
    }
    result
}

fn prepare_get(
    path: &[&str],
    query: &[(String, String)],
    token: &str,
) -> Result<Request, &'static str> {
    valid(token)?;
    if token.is_empty() || path.is_empty() || path.len() > 16 || query.len() > 100 {
        return Err("gmail_invalid_input");
    }
    let mut url = String::from("https://gmail.googleapis.com/gmail/v1/users/me/");
    for (index, part) in path.iter().enumerate() {
        validate_path_part(part)?;
        if index != 0 {
            url.push('/');
        }
        url.push_str(&encode(part));
    }
    for (index, (key, value)) in query.iter().enumerate() {
        valid(key)?;
        valid(value)?;
        url.push(if index == 0 { '?' } else { '&' });
        url.push_str(&encode(key));
        url.push('=');
        url.push_str(&encode(value));
        if url.len() > MAX_INPUT {
            return Err("gmail_invalid_input");
        }
    }
    if url.len() > MAX_INPUT {
        return Err("gmail_invalid_input");
    }
    let mut authorization = reqwest::header::HeaderValue::from_str(&format!("Bearer {token}"))
        .map_err(|_| "gmail_invalid_input")?;
    authorization.set_sensitive(true);
    let (operation, cost) = read_operation(path, query);
    Ok(Request {
        url,
        method: reqwest::Method::GET,
        content_type: "application/json",
        authorization: Some(authorization),
        body: None,
        operation,
        cost,
        budget: None,
        response_limit: MAX_RESPONSE,
    })
}

fn prepare_refresh(id: &str, secret: &str, token: &str) -> Result<Request, &'static str> {
    for value in [id, secret, token] {
        valid(value)?;
        if value.is_empty() {
            return Err("gmail_invalid_input");
        }
    }
    let body = format!(
        "grant_type=refresh_token&client_id={}&client_secret={}&refresh_token={}",
        encode(id),
        encode(secret),
        encode(token)
    );
    if body.len() > MAX_INPUT {
        return Err("gmail_invalid_input");
    }
    Ok(Request {
        url: "https://oauth2.googleapis.com/token".into(),
        method: reqwest::Method::POST,
        content_type: "application/x-www-form-urlencoded",
        authorization: None,
        body: Some(body),
        operation: "oauth.refresh",
        cost: 0,
        budget: None,
        response_limit: MAX_RESPONSE,
    })
}

/// Only rate-limit refusals are retried. A timeout leaves completion unknown.
pub async fn write(
    method: reqwest::Method,
    path: &[&str],
    body: Option<&Value>,
    token: &str,
) -> Result<Value, &'static str> {
    let request = prepare_write(method, path, body, token)?;
    execute(client()?, request, DEADLINE).await
}

fn prepare_write(
    method: reqwest::Method,
    path: &[&str],
    body: Option<&Value>,
    token: &str,
) -> Result<Request, &'static str> {
    if !matches!(
        method,
        reqwest::Method::POST
            | reqwest::Method::PUT
            | reqwest::Method::PATCH
            | reqwest::Method::DELETE
    ) {
        return Err("gmail_invalid_input");
    }
    let mut request = prepare_get(path, &[], token)?;
    (request.operation, request.cost) = write_operation(&method, path);
    request.method = method;
    if let Some(body) = body {
        let body = serde_json::to_string(body).map_err(|_| "gmail_invalid_input")?;
        if body.len() > 48 * 1024 * 1024 {
            return Err("gmail_invalid_input");
        }
        request.body = Some(body);
    }
    Ok(request)
}
