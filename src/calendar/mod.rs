//! Calendar HTTP is owned by the backend; view code receives bounded documents.
use reqwest::{Client, Method, Url};
use serde_json::{Value, json};
use std::{sync::OnceLock, time::Duration};

pub mod attendance;
mod discovery;
pub(crate) mod parse;
pub(crate) mod reads;
pub mod reminders;
pub use discovery::google as discover_google;

const LIMIT: usize = 16 * 1024 * 1024;
static CLIENT: OnceLock<Result<Client, &'static str>> = OnceLock::new();

fn client_builder() -> reqwest::ClientBuilder {
    Client::builder()
        .https_only(true)
        .hickory_dns(true)
        .no_proxy()
        .redirect(reqwest::redirect::Policy::none())
        .connect_timeout(Duration::from_secs(10))
        .timeout(Duration::from_secs(20))
}

pub(super) fn client() -> Result<&'static Client, &'static str> {
    CLIENT
        .get_or_init(|| {
            client_builder()
                .build()
                .map_err(|_| "calendar_network_failed")
        })
        .as_ref()
        .map_err(|e| *e)
}

fn text<'a>(value: &'a Value, key: &str) -> Result<&'a str, &'static str> {
    let s = value[key].as_str().ok_or("calendar_invalid_input")?;
    if s.is_empty() || s.len() > 8192 || s.chars().any(char::is_control) {
        return Err("calendar_invalid_input");
    }
    Ok(s)
}

struct Request {
    url: Url,
    method: Method,
    body: String,
    if_match: Option<String>,
}

fn prepare(params: &Value) -> Result<Request, &'static str> {
    let source = &params["source"];
    if text(source, "kind")? != "google" {
        return Err("calendar_provider_unsupported");
    }
    let op = text(params, "operation")?;
    let method = match op {
        "list" | "get" | "lookup" | "instances" => Method::GET,
        "create" | "move" => Method::POST,
        "update" => Method::PATCH,
        "delete" => Method::DELETE,
        _ => return Err("calendar_invalid_operation"),
    };
    let body = params["body"].as_str().unwrap_or("").to_owned();
    if body.len() > LIMIT {
        return Err("calendar_input_too_large");
    }
    let mut request = Request {
        url: Url::parse("https://www.googleapis.com/calendar/v3/calendars/primary/events").unwrap(),
        method,
        body,
        if_match: params
            .get("ifMatch")
            .map(|_| text(params, "ifMatch").map(str::to_owned))
            .transpose()?,
    };
    let calendar_id = source["calendarId"]
        .as_str()
        .filter(|id| !id.is_empty())
        .unwrap_or("primary");
    if calendar_id == "."
        || calendar_id == ".."
        || calendar_id.len() > 8192
        || calendar_id.chars().any(char::is_control)
    {
        return Err("calendar_invalid_input");
    }
    request.url = Url::parse("https://www.googleapis.com/calendar/v3/calendars").unwrap();
    request
        .url
        .path_segments_mut()
        .unwrap()
        .push(calendar_id)
        .push("events");
    if matches!(op, "get" | "update" | "delete" | "instances" | "move") {
        let id = text(params, "eventId")?;
        if id == "." || id == ".." {
            return Err("calendar_invalid_input");
        }
        request.url.path_segments_mut().unwrap().push(id);
    }
    if op == "instances" {
        request.url.path_segments_mut().unwrap().push("instances");
        request
            .url
            .query_pairs_mut()
            .append_pair("showDeleted", "true");
        if params.get("originalStart").is_some() {
            request
                .url
                .query_pairs_mut()
                .append_pair("originalStart", text(params, "originalStart")?);
        }
    }
    if op == "lookup" {
        request.url.query_pairs_mut().extend_pairs([
            ("iCalUID", text(params, "uid")?),
            ("showHiddenInvitations", "true"),
            ("showDeleted", "true"),
            ("maxResults", "2500"),
        ]);
    }
    if op == "move" {
        request.url.path_segments_mut().unwrap().push("move");
        request
            .url
            .query_pairs_mut()
            .append_pair("destination", text(params, "destination")?);
    }
    if matches!(op, "create" | "update" | "move" | "delete") {
        if let Some(updates) = params["sendUpdates"].as_str() {
            if !["all", "externalOnly", "none"].contains(&updates) {
                return Err("calendar_invalid_input");
            }
            request
                .url
                .query_pairs_mut()
                .append_pair("sendUpdates", updates);
        }
        if matches!(op, "create" | "update") {
            request
                .url
                .query_pairs_mut()
                .append_pair("conferenceDataVersion", "1");
        }
    }
    if op == "list" {
        let start = text(params, "start")?;
        let end = text(params, "end")?;
        let mut query = request.url.query_pairs_mut();
        query.extend_pairs([
            ("singleEvents", "true"),
            ("orderBy", "startTime"),
            ("maxResults", "2500"),
            ("timeMin", start),
            ("timeMax", end),
        ]);
    }
    if op == "create" || op == "update" {
        let value: Value =
            serde_json::from_str(&request.body).map_err(|_| "calendar_invalid_input")?;
        if !value.is_object() {
            return Err("calendar_invalid_input");
        }
    }
    Ok(request)
}

pub fn validate(params: &Value) -> Result<(), &'static str> {
    prepare(params).map(|_| ())
}

/// OAuth tokens remain inside Rust and redirects are never followed.
pub async fn call(params: &Value, token: Option<&str>) -> Result<Value, &'static str> {
    tokio::time::timeout(Duration::from_secs(24), call_inner(params, token))
        .await
        .map_err(|_| "calendar_timeout")?
}

async fn call_inner(params: &Value, token: Option<&str>) -> Result<Value, &'static str> {
    let request = prepare(params)?;
    let paginated = matches!(
        params["operation"].as_str(),
        Some("list" | "lookup" | "instances")
    );
    let origin = request.url.clone();
    let mut result = execute(client()?, request, token).await?;
    if !paginated {
        return Ok(result);
    }
    let mut payload: Value = serde_json::from_str(result["body"].as_str().unwrap_or(""))
        .map_err(|_| "calendar_invalid_response")?;
    let items_key = "items";
    let mut total_bytes = result["body"].as_str().unwrap_or("").len();
    for _ in 0..100 {
        let next = next_page(&origin, &payload)?;
        let Some(next) = next else {
            result["body"] = Value::String(
                serde_json::to_string(&payload).map_err(|_| "calendar_invalid_response")?,
            );
            return Ok(result);
        };
        let mut request = prepare(params)?;
        request.url = next;
        let answer = execute(client()?, request, token).await?;
        let body = answer["body"].as_str().ok_or("calendar_invalid_response")?;
        total_bytes += body.len();
        if total_bytes > LIMIT {
            return Err("calendar_response_too_large");
        }
        let mut page: Value =
            serde_json::from_str(body).map_err(|_| "calendar_invalid_response")?;
        let mut items = payload[items_key].as_array().cloned().unwrap_or_default();
        items.extend(page[items_key].as_array().cloned().unwrap_or_default());
        page[items_key] = Value::Array(items);
        payload = page;
    }
    Err("calendar_too_many_pages")
}

fn next_page(origin: &Url, payload: &Value) -> Result<Option<Url>, &'static str> {
    let Some(token) = payload["nextPageToken"].as_str().filter(|s| !s.is_empty()) else {
        return Ok(None);
    };
    if token.len() > 8192 || token.chars().any(char::is_control) {
        return Err("calendar_invalid_response");
    }
    let mut next = origin.clone();
    next.query_pairs_mut().append_pair("pageToken", token);
    Ok(Some(next))
}

async fn execute(
    client: &Client,
    request: Request,
    token: Option<&str>,
) -> Result<Value, &'static str> {
    let mut builder = client.request(request.method.clone(), request.url);
    // Invariant: Google's empty-body POST endpoints (events.move) require an explicit
    // length. reqwest/hyper may otherwise omit framing for a zero-byte body.
    if request.method == Method::POST && request.body.is_empty() {
        builder = builder.header(reqwest::header::CONTENT_LENGTH, "0");
    }
    if let Some(etag) = request.if_match {
        builder = builder.header("If-Match", etag);
    }
    let token = token
        .filter(|s| !s.is_empty() && !s.chars().any(char::is_control))
        .ok_or("calendar_auth_required")?;
    builder = builder
        .bearer_auth(token)
        .header("Content-Type", "application/json");
    let mut response = builder
        .body(request.body)
        .send()
        .await
        .map_err(|_| "calendar_network_failed")?;
    let status = response.status();
    if status.as_u16() == 412 {
        return Err("calendar_conflict");
    }
    if status.as_u16() == 404 {
        return Err("calendar_not_found");
    }
    if status.as_u16() == 401 || status.as_u16() == 403 {
        return Err("calendar_auth_refused");
    }
    if !status.is_success() {
        return Err("calendar_request_failed");
    }
    if response.content_length().is_some_and(|n| n > LIMIT as u64) {
        return Err("calendar_response_too_large");
    }
    let mut bytes = Vec::new();
    while let Some(chunk) = response
        .chunk()
        .await
        .map_err(|_| "calendar_network_failed")?
    {
        if chunk.len() > LIMIT - bytes.len() {
            return Err("calendar_response_too_large");
        }
        bytes.extend_from_slice(&chunk);
    }
    let body = String::from_utf8(bytes).map_err(|_| "calendar_invalid_response")?;
    Ok(json!({"body":body,"status":status.as_u16()}))
}

#[cfg(test)]
mod tests;
