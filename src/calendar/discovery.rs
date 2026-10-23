use reqwest::{Response, Url};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

const DISCOVERY_LIMIT: usize = 4 * 1024 * 1024;
const MAX_CALENDARS: usize = 256;

fn bounded_text(value: &Value, key: &str) -> Option<String> {
    value[key]
        .as_str()
        .map(str::trim)
        .filter(|text| !text.is_empty() && text.len() <= 8192)
        .filter(|text| !text.chars().any(char::is_control))
        .map(str::to_owned)
}

fn source_id(provider: &str, account: &str, remote: &str, is_default: bool) -> String {
    if is_default {
        return format!("{provider}:{account}");
    }
    let mut digest = Sha256::new();
    digest.update(provider.as_bytes());
    digest.update([0]);
    digest.update(account.as_bytes());
    digest.update([0]);
    digest.update(remote.as_bytes());
    format!("{provider}:{account}:{:x}", digest.finalize())
}

pub(super) async fn response_body(mut response: Response) -> Result<String, &'static str> {
    if response
        .content_length()
        .is_some_and(|size| size > DISCOVERY_LIMIT as u64)
    {
        return Err("calendar_response_too_large");
    }
    let mut bytes = Vec::new();
    while let Some(chunk) = response
        .chunk()
        .await
        .map_err(|_| "calendar_network_failed")?
    {
        if chunk.len() > DISCOVERY_LIMIT - bytes.len() {
            return Err("calendar_response_too_large");
        }
        bytes.extend_from_slice(&chunk);
    }
    String::from_utf8(bytes).map_err(|_| "calendar_invalid_response")
}

pub async fn google(account: &str, token: &str) -> Result<Value, &'static str> {
    if account.is_empty()
        || account.contains(':')
        || !account.contains('@')
        || account.len() > 1024
        || account.chars().any(char::is_whitespace)
        || account.chars().any(char::is_control)
    {
        return Err("invalid_params");
    }
    tokio::time::timeout(
        std::time::Duration::from_secs(27),
        google_pages(account, token),
    )
    .await
    .map_err(|_| "calendar_timeout")?
}

fn google_calendar(account: &str, value: &Value) -> Result<Value, &'static str> {
    let id = bounded_text(value, "id").ok_or("calendar_invalid_response")?;
    if value["id"].as_str() != Some(id.as_str()) || matches!(id.as_str(), "." | "..") {
        return Err("calendar_invalid_response");
    }
    let primary = value["primary"] == true;
    let role = bounded_text(value, "accessRole").unwrap_or_default();
    let name = bounded_text(value, "summaryOverride")
        .or_else(|| bounded_text(value, "summary"))
        .unwrap_or_else(|| id.clone());
    Ok(json!({
        "sourceId":source_id("google", account, &id, primary),
        "calendarId":id,"name":name,"isDefault":primary,
        "readOnly":!matches!(role.as_str(), "owner" | "writer"),
        "accessRole":role,"timeZone":bounded_text(value, "timeZone").unwrap_or_default(),
        "selected":value["selected"] == true,"hidden":value["hidden"] == true,
        "defaultReminders":value["defaultReminders"].as_array().cloned().unwrap_or_default(),
        "canCreateMeet":value["conferenceProperties"]["allowedConferenceSolutionTypes"]
            .as_array().is_some_and(|types| types.iter().any(|kind| kind == "hangoutsMeet"))
    }))
}

async fn google_pages(account: &str, token: &str) -> Result<Value, &'static str> {
    let origin =
        Url::parse("https://www.googleapis.com/calendar/v3/users/me/calendarList").unwrap();
    let mut page_token = String::new();
    let mut calendars = Vec::new();
    let mut bytes = 0;
    let mut seen = std::collections::HashSet::new();
    for _ in 0..100 {
        let mut url = origin.clone();
        url.query_pairs_mut()
            .extend_pairs([("showHidden", "true"), ("maxResults", "250")]);
        if !page_token.is_empty() {
            url.query_pairs_mut().append_pair("pageToken", &page_token);
        }
        let response = super::client()?
            .get(url)
            .bearer_auth(token)
            .send()
            .await
            .map_err(|_| "calendar_network_failed")?;
        if matches!(response.status().as_u16(), 401 | 403) {
            return Err("calendar_auth_refused");
        }
        if !response.status().is_success() {
            return Err("calendar_request_failed");
        }
        let body = response_body(response).await?;
        bytes += body.len();
        if bytes > DISCOVERY_LIMIT {
            return Err("calendar_response_too_large");
        }
        let payload: Value =
            serde_json::from_str(&body).map_err(|_| "calendar_invalid_response")?;
        for value in payload["items"]
            .as_array()
            .ok_or("calendar_invalid_response")?
        {
            if value["deleted"] == true {
                continue;
            }
            let item = google_calendar(account, value)?;
            if seen.insert(item["calendarId"].as_str().unwrap().to_owned()) {
                calendars.push(item);
            }
            if calendars.len() > MAX_CALENDARS {
                return Err("calendar_too_many_calendars");
            }
        }
        match bounded_text(&payload, "nextPageToken") {
            Some(next) if next != page_token => page_token = next,
            None if payload.get("nextPageToken").is_none() => {
                return Ok(json!({"provider":"google","accountId":account,"calendars":calendars}));
            }
            _ => return Err("calendar_invalid_response"),
        }
    }
    Err("calendar_too_many_pages")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn google_projection_keeps_hidden_permissions_and_refuses_noncanonical_ids() {
        let source = google_calendar(
            "me@example.org",
            &json!({"id":"team@example.org","summary":"Team",
            "accessRole":"reader","hidden":true,"timeZone":"Europe/Paris",
            "defaultReminders":[{"method":"popup","minutes":10}],
            "conferenceProperties":{"allowedConferenceSolutionTypes":["hangoutsMeet"]}}),
        )
        .unwrap();
        assert_eq!(source["selected"], false);
        assert_eq!(source["hidden"], true);
        assert_eq!(source["readOnly"], true);
        assert_eq!(source["timeZone"], "Europe/Paris");
        assert_eq!(source["defaultReminders"][0]["minutes"], 10);
        assert_eq!(source["canCreateMeet"], true);
        for id in [
            "..",
            ".",
            " leading",
            "trailing ",
            "trailing\n",
            "nul\0",
            "cr\r",
        ] {
            assert!(
                google_calendar("me@example.org", &json!({"id":id})).is_err(),
                "{id:?}"
            );
        }
        assert_ne!(
            source["sourceId"],
            google_calendar("other@example.org", &json!({"id":"team@example.org"})).unwrap()["sourceId"]
        );
    }
}
