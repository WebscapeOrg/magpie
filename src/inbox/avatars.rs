use super::{now, store};
use serde_json::{Value, json};
use std::time::Duration;
pub fn email(raw: &str) -> Result<String, &'static str> {
    if raw.chars().any(char::is_control) {
        return Err("invalid_params");
    }
    let text = raw.trim().to_lowercase();
    let Some((local, domain)) = text.split_once('@') else {
        return Err("invalid_params");
    };
    if text.len() > 320
        || local.is_empty()
        || local.contains('@')
        || domain.contains('@')
        || text
            .chars()
            .any(|c| c.is_control() || c.is_whitespace() || "<>/\\\"?#&".contains(c))
        || !domain.contains('.')
        || domain.split('.').any(|s| {
            s.is_empty()
                || s.starts_with('-')
                || s.ends_with('-')
                || !s.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-')
        })
    {
        return Err("invalid_params");
    }
    Ok(text)
}
fn consumer(domain: &str) -> bool {
    [
        "gmail.com",
        "googlemail.com",
        "outlook.com",
        "hotmail.com",
        "live.com",
        "yahoo.com",
        "icloud.com",
        "me.com",
        "proton.me",
        "protonmail.com",
        "aol.com",
        "mail.com",
    ]
    .contains(&domain)
}
async fn contacts(
    gmail: &crate::providers::gmail::Session,
    account: &str,
    refresh_id: &str,
) -> Result<Value, &'static str> {
    static CONTACT_REFRESH: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());
    let _refresh = CONTACT_REFRESH.lock().await;
    let name = store::key(&["contacts", account]);
    if let Some(saved) = store::read(&name)? {
        if (refresh_id.is_empty() && now() - saved["updated"].as_i64().unwrap_or(0) < 86_400_000)
            || (!refresh_id.is_empty() && saved["refreshId"] == refresh_id)
        {
            return Ok(saved["photos"].clone());
        }
    }
    let token = gmail.access_token(account).await?;
    let client = reqwest::Client::builder()
        .https_only(true)
        .no_proxy()
        .redirect(reqwest::redirect::Policy::none())
        .timeout(Duration::from_secs(18))
        .build()
        .map_err(|_| "contacts_unavailable")?;
    let mut photos = json!({});
    let mut page = String::new();
    let work = async {
        for _ in 0..20 {
            let mut response = client
                .get("https://people.googleapis.com/v1/people/me/connections")
                .bearer_auth(&token)
                .query(&[
                    ("personFields", "emailAddresses,photos"),
                    ("pageSize", "1000"),
                    ("pageToken", &page),
                ])
                .send()
                .await
                .map_err(|_| "contacts_unavailable")?;
            if !response.status().is_success() {
                return Err("contacts_permission_required");
            }
            let mut bytes = Vec::new();
            while let Some(chunk) = response.chunk().await.map_err(|_| "contacts_unavailable")? {
                if bytes.len() + chunk.len() > 4 * 1024 * 1024 {
                    return Err("contacts_response_limit");
                };
                bytes.extend_from_slice(&chunk);
            }
            let answer: Value = serde_json::from_slice(&bytes).map_err(|_| "contacts_invalid")?;
            for person in answer["connections"].as_array().into_iter().flatten() {
                let photo = person["photos"]
                    .as_array()
                    .and_then(|p| p.iter().find(|v| v["default"] != true))
                    .and_then(|v| v["url"].as_str())
                    .filter(|s| s.starts_with("https://"));
                if let Some(photo) = photo {
                    for address in person["emailAddresses"].as_array().into_iter().flatten() {
                        if let Some(email) = address["value"].as_str().and_then(|s| email(s).ok()) {
                            photos[&email] = json!(photo);
                        }
                    }
                }
            }
            page = answer["nextPageToken"].as_str().unwrap_or("").to_owned();
            if page.is_empty() {
                break;
            }
        }
        Ok::<_, &'static str>(())
    };
    let result = tokio::time::timeout(Duration::from_secs(20), work).await;
    let state = if matches!(result, Ok(Ok(()))) {
        "ready"
    } else {
        "permission_required"
    };
    store::write(
        &name,
        &json!({"photos":photos,"updated":now(),"state":state,"refreshId":refresh_id}),
    )?;
    Ok(photos)
}
pub async fn get(
    gmail: &crate::providers::gmail::Session,
    account: &str,
    address: &str,
    refresh_id: &str,
) -> Result<Value, &'static str> {
    let domain = address.split_once('@').ok_or("invalid_params")?.1;
    let name = format!("avatar-{}", store::key(&["avatar-v2", account, address]));
    if let Some(saved) = store::read(&name)? {
        if refresh_id.is_empty() && now() - saved["updated"].as_i64().unwrap_or(0) < 7 * 86_400_000
        {
            return Ok(saved);
        }
    }
    let photos = contacts(gmail, account, refresh_id)
        .await
        .unwrap_or(json!({}));
    let mut image = String::new();
    let mut source = "initial";
    if let Some(url) = photos[address].as_str() {
        if let Ok(data) = crate::public_http::image(url).await {
            image = data;
            source = "contact";
        }
    }
    if image.is_empty() && !consumer(domain) {
        if let Some(url) = organization_artwork(domain) {
            if let Ok(data) = crate::public_http::image(url).await {
                image = data;
                source = "organization";
            }
        }
    }
    if image.is_empty() && !consumer(domain) {
        // Query only a domain, never a mailbox address or sender-controlled image URL.
        let url = format!(
            "https://t2.gstatic.com/faviconV2?client=SOCIAL&type=FAVICON&fallback_opts=TYPE,SIZE,URL&url=https%3A%2F%2F{domain}&size=256"
        );
        if let Ok(data) = crate::public_http::image(&url).await {
            image = data;
            source = "organization";
        }
    }
    let value = json!({"data":image,"source":source,"updated":now()});
    store::cache(&name, &value)?;
    Ok(value)
}
fn organization_artwork(domain: &str) -> Option<&'static str> {
    match domain {
        "linkedin.com" => Some(
            "https://static.licdn.com/scds/common/u/images/logos/linkedin/logo-in-win8-tile-144_v1.png",
        ),
        "xneelo.co.za" | "xneelo.com" => {
            Some("https://xneelo.co.za/wp-content/uploads/2020/12/cropped-favicon-300x300.png")
        }
        _ => None,
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn artwork_uses_exact_domains_and_official_high_resolution_sources() {
        assert!(
            organization_artwork("linkedin.com")
                .unwrap()
                .contains("144")
        );
        assert!(
            organization_artwork("xneelo.co.za")
                .unwrap()
                .contains("300x300")
        );
        for domain in [
            "linkedin.com.evil.test",
            "evil.linkedin.com",
            "xneelo.co.za/evil",
        ] {
            assert_eq!(organization_artwork(domain), None);
        }
    }
    #[test]
    fn hostile_addresses_never_form_requests() {
        for value in [
            "a@127.0.0.1/x",
            "a@x.com\r\nX:y",
            "a@x.com?other=secret",
            "a@x.com\\evil",
            "a@-x.com",
            "a@x.com@evil.com",
        ] {
            assert!(email(value).is_err(), "{value}");
        }
    }
}
