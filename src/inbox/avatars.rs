pub(super) mod artwork;
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
pub(super) fn consumer(domain: &str) -> bool {
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
/// The contacts' photos and whether that answer is complete. An incomplete answer (no token, or a
/// failed or partial People reply) does not mean a contact has no photo.
#[cfg(any(all(feature = "agent", unix, not(target_os = "ios")), feature = "mobile"))]
pub(super) async fn contact_photos(
    gmail: &crate::providers::gmail::Session,
    account: &str,
) -> Result<(Value, bool), &'static str> {
    let photos = contacts(gmail, account, "").await?;
    let complete = store::read(&store::key(&["contacts", account]))?.is_some_and(|saved| saved["state"] == "ready");
    Ok((photos, complete))
}
pub(super) async fn contacts(
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
    #[cfg(any(all(feature = "agent", unix, not(target_os = "ios")), feature = "mobile"))]
    if let Some(value) = painted(account, address).await {
        return Ok(value);
    }
    let name = format!("avatar-{}", store::key(&["avatar-v3", account, address]));
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
        if let Some(data) = organization_image(domain).await {
            image = data;
            source = "organization";
        }
    }
    if !image.is_empty() {
        let organization = source == "organization";
        image = tokio::task::spawn_blocking(move || artwork::prepare(&image, organization))
            .await
            .ok()
            .and_then(Result::ok)
            .unwrap_or_default();
        if image.is_empty() {
            source = "initial";
        }
    }
    let value = json!({"data":image,"source":source,"updated":now(),"owner":account});
    store::cache(&name, &value)?;
    Ok(value)
}
/// The company's own artwork for a domain, or its favicon, as a data URL.
pub(super) async fn organization_image(domain: &str) -> Option<String> {
    if let Some(url) = organization_artwork(domain)
        && let Ok(data) = crate::public_http::image(url).await
    {
        return Some(data);
    }
    // Invariant: Query only a domain, never a mailbox address or sender-controlled image URL.
    let url = format!(
        "https://t2.gstatic.com/faviconV2?client=SOCIAL&type=FAVICON&fallback_opts=TYPE,SIZE,URL&url=https%3A%2F%2F{domain}&size=256"
    );
    crate::public_http::image(&url).await.ok()
}
/// The sender's painted picture, prepared for the avatar circle and cached until it is painted
/// again. Any problem with the pictures store means no painted picture, so the usual avatar is
/// shown instead.
#[cfg(any(all(feature = "agent", unix, not(target_os = "ios")), feature = "mobile"))]
async fn painted(account: &str, address: &str) -> Option<Value> {
    let (owner, sender) = (account.to_owned(), address.to_owned());
    let (subject, painted) = tokio::task::spawn_blocking(move || super::pictures::painted(&owner, &sender))
        .await
        .ok()?
        .ok()??;
    let name = format!("avatar-{}", store::key(&["avatar-painted", account, address]));
    if let Ok(Some(saved)) = store::read(&name)
        && saved["source"] == "painted"
        && saved["painted"] == painted
    {
        return Some(saved);
    }
    let data = tokio::task::spawn_blocking(move || super::pictures::picture(&subject))
        .await
        .ok()?
        .ok()??;
    let image = tokio::task::spawn_blocking(move || artwork::prepare(&data, false))
        .await
        .ok()?
        .ok()?;
    let value = json!({"data":image,"source":"painted","painted":painted,"updated":now(),"owner":account});
    let _ = store::cache(&name, &value);
    Some(value)
}
/// Deletes the prepared painted pictures of accounts that are not in `accounts`. The rows are read
/// without the cache lock, so avatar requests keep working during the scan; the lock is taken,
/// waiting up to two seconds, only to delete. Blocks: call it off the async threads.
#[cfg(any(all(feature = "agent", unix, not(target_os = "ios")), feature = "mobile"))]
pub(super) fn forget_painted(accounts: &[String]) -> Result<(), &'static str> {
    use crate::platform::{dirs::AppDirs, private_fs};
    let Some(dir) = private_fs::directories(&AppDirs::discover()?.state, &["omamail", "inbox"], false)? else {
        return Ok(());
    };
    let unlisted = |row: &Value| {
        let owner = row["owner"].as_str().unwrap_or("");
        row["source"] == "painted" && !accounts.iter().any(|account| account == owner)
    };
    let gone: Vec<String> = private_fs::names(&dir)?
        .into_iter()
        .filter(|name| name.starts_with("avatar-"))
        .filter(|name| matches!(store::read(name), Ok(Some(row)) if unlisted(&row)))
        .collect();
    if gone.is_empty() {
        return Ok(());
    }
    let deadline = std::time::Instant::now() + Duration::from_secs(2);
    let _lock = loop {
        match private_fs::lock_exclusive(&dir, ".cache-lock") {
            Err("private_fs_busy") if std::time::Instant::now() < deadline => {
                std::thread::sleep(Duration::from_millis(10));
            }
            other => break other?,
        }
    };
    // A row's name is bound to one account and address, so a row rewritten since the scan still
    // belongs to the same unlisted account; it is checked again all the same.
    for name in gone {
        if matches!(store::read(&name), Ok(Some(row)) if unlisted(&row)) {
            private_fs::remove_owned(&dir, &name)?;
        }
    }
    private_fs::sync_dir(&dir)
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
