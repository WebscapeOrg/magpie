use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use serde_json::Value;

pub(super) struct Text {
    pub body: String,
    pub filenames: String,
    pub complete: bool,
}
pub(super) fn is_attachment(part: &Value) -> bool {
    if !part["filename"].as_str().unwrap_or("").is_empty() {
        return true;
    }
    part["headers"]
        .as_array()
        .into_iter()
        .flatten()
        .any(|header| {
            header["name"]
                .as_str()
                .is_some_and(|name| name.eq_ignore_ascii_case("content-disposition"))
                && header["value"].as_str().is_some_and(|value| {
                    value
                        .split(';')
                        .next()
                        .unwrap_or("")
                        .trim()
                        .eq_ignore_ascii_case("attachment")
                })
        })
}

pub(super) fn extract(resource: &Value) -> Text {
    let mut output = Text {
        body: String::new(),
        filenames: String::new(),
        complete: true,
    };
    let mut pending = vec![&resource["payload"]];
    while let Some(part) = pending.pop() {
        let filename = part["filename"].as_str().unwrap_or("");
        if !filename.is_empty() {
            output.filenames.push_str(filename);
            output.filenames.push('\n');
        }
        if is_attachment(part) {
            continue;
        }
        if let Some(parts) = part["parts"].as_array() {
            pending.extend(parts.iter().rev());
        }
        let mime = part["mimeType"].as_str().unwrap_or("");
        if !matches!(mime, "text/plain" | "text/html") {
            continue;
        }
        let Some(data) = part["body"]["data"].as_str() else {
            if part["body"]["size"].as_u64().unwrap_or(0) > 0
                || part["body"]["attachmentId"].is_string()
            {
                output.complete = false;
            }
            continue;
        };
        let Ok(bytes) = URL_SAFE_NO_PAD.decode(data.trim_end_matches('=')) else {
            output.complete = false;
            continue;
        };
        let charset = part["headers"]
            .as_array()
            .into_iter()
            .flatten()
            .find(|h| {
                h["name"]
                    .as_str()
                    .is_some_and(|s| s.eq_ignore_ascii_case("Content-Type"))
            })
            .and_then(|h| h["value"].as_str())
            .and_then(|s| mailparse::parse_content_type(s).charset.into());
        let encoding = charset
            .as_deref()
            .and_then(|s| encoding_rs::Encoding::for_label(s.as_bytes()))
            .unwrap_or(encoding_rs::UTF_8);
        let (text, _, errors) = encoding.decode(&bytes);
        if errors {
            output.complete = false;
        }
        let text = if mime == "text/html" {
            crate::message::content::html_to_text(&text)
        } else {
            text.into_owned()
        };
        output.body.push_str(&text);
        output.body.push('\n');
    }
    output
}
