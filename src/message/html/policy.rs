use super::tree::*;
use base64::{Engine, engine::general_purpose::STANDARD};

pub fn decode(source: &str) -> String {
    re!(r"&(#[0-9]+|#[xX][0-9a-fA-F]+|[a-zA-Z]+);?")
        .replace_all(source, |captures: &regex::Captures| {
            let entity = &captures[1];
            if let Some(number) = entity.strip_prefix('#') {
                let parsed = if number.starts_with(['x', 'X']) {
                    u32::from_str_radix(&number[1..], 16)
                } else {
                    number.parse()
                };
                return parsed
                    .ok()
                    .and_then(char::from_u32)
                    .map(|character| character.to_string())
                    .unwrap_or_else(|| captures[0].into());
            }
            match entity.to_ascii_lowercase().as_str() {
                "amp" => "&",
                "quot" => "\"",
                "apos" => "'",
                "lt" => "<",
                "gt" => ">",
                "sol" => "/",
                "colon" => ":",
                "nbsp" | "ensp" | "emsp" | "thinsp" => " ",
                "mdash" => "—",
                "ndash" => "–",
                "hellip" => "…",
                "bull" => "•",
                "lsquo" => "‘",
                "rsquo" => "’",
                "ldquo" => "“",
                "rdquo" => "”",
                "middot" => "·",
                "copy" => "©",
                "reg" => "®",
                "trade" => "™",
                "deg" => "°",
                "times" => "×",
                "laquo" => "«",
                "raquo" => "»",
                "euro" => "€",
                "pound" => "£",
                "yen" => "¥",
                "cent" => "¢",
                "sect" => "§",
                _ => return captures[0].into(),
            }
            .into()
        })
        .into_owned()
}
pub fn normalized(source: &str) -> String {
    decode(&decode(source))
        .replace(['\t', '\n', '\r'], "")
        .trim_matches(|character: char| character.is_whitespace() || character <= '\u{1f}')
        .into()
}
fn host(address: &str) -> String {
    let lower = address.to_ascii_lowercase();
    let address = lower
        .strip_prefix("https:")
        .or_else(|| lower.strip_prefix("http:"))
        .unwrap_or(&lower);
    let Some(address) = address.strip_prefix("//") else {
        return String::new();
    };
    let address = address.split(['/', '?', '#']).next().unwrap_or("");
    let address = address.rsplit('@').next().unwrap_or("");
    if address.starts_with('[') {
        return address.split(']').next().unwrap_or("").to_owned() + "]";
    }
    address.split(':').next().unwrap_or("").into()
}
fn public_host(host: &str) -> bool {
    if let Ok(ip) = host.parse::<std::net::Ipv4Addr>() {
        return crate::public_http::is_public(ip.into());
    }
    if host.len() > 253 || host.contains("..") || !re!(r"^[a-z0-9.-]+$").is_match(host) {
        return false;
    }
    if re!(r"(?i)(^|\.)(localhost|home\.arpa)$|\.(local|localdomain|internal|intranet|lan|home|corp|test)$").is_match(host){return false}
    re!(r"\.(xn--[a-z0-9-]+|[a-z]{2,})$").is_match(host)
}
pub fn is_public_url(source: &str) -> bool {
    let once = decode(source);
    let twice = decode(&once);
    public_host(&host(&normalized(source)))
        && (once == twice || public_host(&host(&once.replace(['\t', '\n', '\r'], ""))))
}
fn raster_data(source: &str) -> Option<Vec<u8>> {
    let (header, payload) = source.split_once(',')?;
    let header = header.to_ascii_lowercase();
    let kind = header
        .strip_prefix("data:image/")?
        .strip_suffix(";base64")?;
    if payload.len() > 8 * 1024 * 1024 {
        return None;
    }
    let bytes = STANDARD.decode(payload).ok()?;
    let signature_matches = match kind {
        "png" => bytes.starts_with(b"\x89PNG\r\n\x1a\n"),
        "jpg" | "jpeg" => bytes.starts_with(b"\xff\xd8\xff"),
        "gif" => bytes.starts_with(b"GIF87a") || bytes.starts_with(b"GIF89a"),
        "webp" => bytes.starts_with(b"RIFF") && bytes.get(8..12) == Some(b"WEBP"),
        "bmp" => bytes.starts_with(b"BM"),
        _ => false,
    };
    signature_matches.then_some(bytes)
}
pub fn raster_decoded_bytes(source: &str) -> Option<u64> {
    crate::raster::decoded_bytes(&raster_data(source)?)
}
pub fn raster(source: &str) -> bool {
    raster_decoded_bytes(source).is_some()
}
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum ImageSource {
    Absent,
    Embedded,
    Remote,
    Unsafe,
    Local,
}
pub(super) fn image_kind(source: &str) -> ImageSource {
    let url = normalized(source);
    let lower = url.to_ascii_lowercase();
    if url.is_empty() {
        ImageSource::Absent
    } else if lower.starts_with("cid:") || raster_data(&url).is_some() {
        ImageSource::Embedded
    } else if re!(r"(?i)^(https?:)?//").is_match(&url) {
        if is_public_url(source) {
            ImageSource::Remote
        } else {
            ImageSource::Unsafe
        }
    } else if re!(r"(?i)^[a-z][a-z0-9+.-]*:").is_match(&url) {
        ImageSource::Unsafe
    } else {
        ImageSource::Local
    }
}
pub fn safe_href(source: &str) -> bool {
    re!(r"(?i)^\s*(https?:|mailto:)").is_match(source)
}
pub fn declarations(source: &str) -> Vec<(String, String)> {
    let mut value = decode(&decode(source));
    for _ in 0..8 {
        let old = value.clone();
        value = re!(r"(?s)/\*.*?(?:\*/|$)")
            .replace_all(&value, "")
            .into_owned();
        value = re!(r"\\([0-9a-fA-F]{1,6}[\t\n\r\x0c ]?|.)")
            .replace_all(&value, |captures: &regex::Captures| {
                let escaped = &captures[1];
                if escaped.as_bytes()[0].is_ascii_hexdigit() {
                    u32::from_str_radix(escaped.trim(), 16)
                        .ok()
                        .and_then(char::from_u32)
                        .map(|character| character.to_string())
                        .unwrap_or_default()
                } else {
                    escaped.into()
                }
            })
            .into_owned();
        if old == value {
            break;
        }
    }
    let mut parts = vec![];
    let mut start = 0;
    let mut quote = None;
    let mut depth = 0;
    for (offset, character) in value.char_indices() {
        if let Some(delimiter) = quote {
            if character == delimiter {
                quote = None
            }
            continue;
        }
        match character {
            '\'' | '"' => quote = Some(character),
            '(' => depth += 1,
            ')' => depth = std::cmp::max(0, depth - 1),
            ';' if depth == 0 => {
                parts.push(&value[start..offset]);
                start = offset + 1
            }
            _ => {}
        }
    }
    parts.push(&value[start..]);
    parts
        .into_iter()
        .filter_map(|part| part.split_once(':'))
        .map(|(name, value)| (name.trim().to_ascii_lowercase(), value.trim().into()))
        .collect()
}
pub fn set_style(node: &mut Node, styles: &[(String, String)]) {
    let value = styles
        .iter()
        .filter(|(_, value)| !value.is_empty())
        .map(|(name, value)| format!("{name}:{value}"))
        .collect::<Vec<_>>()
        .join(";");
    if value.is_empty() {
        node.remove("style")
    } else {
        node.set("style", &value)
    }
}
pub fn hidden(styles: &[(String, String)]) -> bool {
    styles.iter().any(|(name, value)| {
        (name == "display" && re!(r"(?i)^none\b").is_match(value))
            || (name == "visibility" && re!(r"(?i)^hidden\b").is_match(value))
    })
}
pub fn tracking(node: &Node) -> bool {
    for dimension in ["width", "height"] {
        if !node.attr(dimension).is_empty()
            && node
                .attr(dimension)
                .trim()
                .parse::<f64>()
                .is_ok_and(|value| value <= 2.0)
        {
            return true;
        }
    }
    declarations(node.attr("style"))
        .iter()
        .any(|(name, value)| {
            matches!(name.as_str(), "width" | "height")
                && re!(r"(?i)^[012](\.\d+)?px").is_match(value)
        })
}
pub fn undrawn(source: &str) -> String {
    re!(r"[\x{00ad}\x{034f}\x{061c}\x{180e}\x{200b}-\x{200f}\x{2060}-\x{2064}\x{feff}]")
        .replace_all(source, "")
        .into_owned()
}
pub fn source_space(source: &str) -> String {
    re!(r"[ \t\r\n\x0c]+").replace_all(source, " ").into_owned()
}
