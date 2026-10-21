//! Sender-selected HTTP destinations: validate every DNS answer, then hand the
//! checked numeric sockets directly to the connector. Never follow redirects.
use base64::{Engine, engine::general_purpose::STANDARD};
use hickory_resolver::{TokioResolver, config::LookupIpStrategy};
use reqwest::{
    Client, Method, Url,
    dns::{Addrs, Name, Resolve, Resolving},
};
use std::{
    net::{IpAddr, SocketAddr},
    sync::{Arc, OnceLock},
    time::Duration,
};

const DEADLINE: Duration = Duration::from_secs(20);
const MAX_IMAGE: usize = 5 * 1024 * 1024;
const MAX_RESPONSE: usize = 16 * 1024 * 1024;
static CLIENT: OnceLock<Result<Client, &'static str>> = OnceLock::new();

#[derive(Debug)]
struct PublicResolver;
impl Resolve for PublicResolver {
    fn resolve(&self, name: Name) -> Resolving {
        Box::pin(async move {
            let mut builder = TokioResolver::builder_tokio()?;
            builder.options_mut().ip_strategy = LookupIpStrategy::Ipv4AndIpv6;
            let resolver = builder.build();
            let answer = resolver.lookup_ip(name.as_str()).await?;
            let addresses: Vec<_> = answer.iter().collect();
            let addresses = checked_addresses(addresses).map_err(std::io::Error::other)?;
            Ok(Box::new(addresses.into_iter()) as Addrs)
        })
    }
}

fn checked_addresses(addresses: Vec<IpAddr>) -> Result<Vec<SocketAddr>, &'static str> {
    if addresses.is_empty() || addresses.iter().any(|ip| !is_public(*ip)) {
        return Err("public_destination_refused");
    }
    Ok(addresses.into_iter().map(|ip| SocketAddr::new(ip, 0)).collect())
}

/// Conservative global-unicast policy, including transition mechanisms that
/// can hide a different effective IPv4 destination.
pub fn is_public(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(ip) => {
            let [first_octet, second_octet, third_octet, _] = ip.octets();
            !(first_octet == 0
                || first_octet == 10
                || first_octet == 127
                || first_octet >= 224
                || (first_octet == 100 && (64..=127).contains(&second_octet))
                || (first_octet == 169 && second_octet == 254)
                || (first_octet == 172 && (16..=31).contains(&second_octet))
                || (first_octet == 192
                    && ((second_octet == 168) || (second_octet == 0 && (third_octet == 0 || third_octet == 2)) || (second_octet == 88 && third_octet == 99)))
                || (first_octet == 198 && (second_octet == 18 || second_octet == 19 || (second_octet == 51 && third_octet == 100)))
                || (first_octet == 203 && second_octet == 0 && third_octet == 113))
        }
        IpAddr::V6(ip) => {
            let segments = ip.segments();
            // Only currently allocated global unicast; excludes mapped IPv4,
            // NAT64, local/multicast and deprecated site-local addresses.
            (segments[0] & 0xe000) == 0x2000
                && !(segments[0] == 0x2001 && segments[1] < 0x0200)
                && !(segments[0] == 0x2001 && segments[1] == 0x0db8)
                && segments[0] != 0x2002
                && !(segments[0] == 0x3fff && segments[1] < 0x1000)
        }
    }
}

fn parse_url(raw: &str, https_only: bool) -> Result<Url, &'static str> {
    // URL parsing normalizes controls and backslashes, so reject raw bytes first.
    if raw.is_empty()
        || raw.len() > 128 * 1024
        || raw
            .chars()
            .any(|character| character.is_control() || character.is_whitespace() || character == '\\')
    {
        return Err("public_url_invalid");
    }
    if raw.split_once("://").is_some_and(|(_, rest)| {
        rest.split(['/', '?', '#'])
            .next()
            .is_some_and(|authority| authority.contains('@'))
    }) {
        return Err("public_url_invalid");
    }
    let mut url = Url::parse(raw).map_err(|_| "public_url_invalid")?;
    if !matches!(url.scheme(), "http" | "https")
        || (https_only && url.scheme() != "https")
        || !url.username().is_empty()
        || url.password().is_some()
        || url.port() == Some(0)
    {
        return Err("public_url_invalid");
    }
    let host = url.host_str().ok_or("public_url_invalid")?;
    if let Ok(ip) = host
        .trim_start_matches('[')
        .trim_end_matches(']')
        .parse::<IpAddr>()
    {
        if !is_public(ip) {
            return Err("public_destination_refused");
        }
    } else if host.len() > 253
        || !host.contains('.')
        || host.split('.').any(|label| {
            label.is_empty()
                || label.len() > 63
                || label.starts_with('-')
                || label.ends_with('-')
                || !label
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
        })
    {
        return Err("public_url_invalid");
    }
    url.set_fragment(None);
    Ok(url)
}

fn client_builder() -> reqwest::ClientBuilder {
    Client::builder()
        .user_agent("Magpie/0.11")
        .no_proxy()
        .redirect(reqwest::redirect::Policy::none())
        .dns_resolver(Arc::new(PublicResolver))
        .connect_timeout(Duration::from_secs(10))
        .timeout(DEADLINE)
        .pool_max_idle_per_host(2)
}
fn client() -> Result<&'static Client, &'static str> {
    CLIENT
        .get_or_init(|| client_builder().build().map_err(|_| "public_http_failed"))
        .as_ref()
        .map_err(|error| *error)
}

pub struct Response {
    pub status: u16,
    pub content_type: String,
    pub body: Vec<u8>,
}

async fn execute(
    client: &Client,
    url: Url,
    method: Method,
    max_bytes: usize,
    deadline: Duration,
) -> Result<Response, &'static str> {
    tokio::time::timeout(deadline, async {
        let mut request = client.request(method.clone(), url);
        if method == Method::POST {
            request = request
                .header("Content-Type", "application/x-www-form-urlencoded")
                .body("List-Unsubscribe=One-Click");
        }
        let mut response = request.send().await.map_err(|_| "public_http_failed")?;
        let status = response.status().as_u16();
        let content_type = response
            .headers()
            .get("Content-Type")
            .and_then(|value| value.to_str().ok())
            .unwrap_or("")
            .split(';')
            .next()
            .unwrap_or("")
            .trim()
            .to_ascii_lowercase();
        let mut body = Vec::new();
        // Unsubscribe only consumes the status; redirects never consume a body.
        if method == Method::GET && (200..300).contains(&status) {
            if response
                .headers()
                .get("Content-Encoding")
                .is_some_and(|value| value != "identity")
            {
                return Err("public_encoding_refused");
            }
            if response
                .content_length()
                .is_some_and(|size| size > max_bytes as u64)
            {
                return Err("public_response_too_large");
            }
            while let Some(chunk) = response.chunk().await.map_err(|_| "public_http_failed")? {
                if chunk.len() > max_bytes - body.len() {
                    return Err("public_response_too_large");
                }
                body.extend_from_slice(&chunk);
            }
        }
        Ok(Response {
            status,
            content_type,
            body,
        })
    })
    .await
    .map_err(|_| "public_http_timeout")?
}

/// Public calendar subscription fetches use the same pinned-address policy.
pub async fn fetch(url: &str, max_bytes: usize) -> Result<Response, &'static str> {
    execute(
        client()?,
        parse_url(url, false)?,
        Method::GET,
        max_bytes.min(MAX_RESPONSE),
        DEADLINE,
    )
    .await
}
pub async fn unsubscribe(url: &str) -> Result<u16, &'static str> {
    Ok(
        execute(client()?, parse_url(url, true)?, Method::POST, 0, DEADLINE)
            .await?
            .status,
    )
}
fn image_data(response: Response) -> Result<String, &'static str> {
    if !(200..300).contains(&response.status) {
        return Err("public_http_refused");
    }
    let data = response.body;
    let mime = if data.starts_with(b"\x89PNG\r\n\x1a\n") {
        "image/png"
    } else if data.starts_with(b"\xff\xd8\xff") {
        "image/jpeg"
    } else if data.starts_with(b"GIF87a") || data.starts_with(b"GIF89a") {
        "image/gif"
    } else if data.starts_with(b"RIFF") && data.get(8..12) == Some(b"WEBP") {
        "image/webp"
    } else if data.starts_with(b"BM") {
        "image/bmp"
    } else {
        return Err("public_image_refused");
    };
    let claimed = if response.content_type == "image/jpg" {
        "image/jpeg"
    } else {
        &response.content_type
    };
    if claimed != mime {
        return Err("public_image_refused");
    }
    Ok(format!("data:{mime};base64,{}", STANDARD.encode(data)))
}
pub async fn image(url: &str) -> Result<String, &'static str> {
    image_data(fetch(url, MAX_IMAGE).await?)
}

#[cfg(test)]
mod tests;
