use serde_json::{Value, json};
use std::{io::Read, os::unix::fs::MetadataExt, time::Duration};
use zeroize::Zeroizing;

const ENDPOINT: &str = "https://api.z.ai/api/paas/v4/chat/completions";
const UNAVAILABLE: &str = "overview_ai_unavailable";
const INVALID: &str = "overview_invalid_response";

pub(super) struct Vision {
    token: Zeroizing<String>,
    client: reqwest::Client,
}

impl Vision {
    pub(super) fn configured() -> Option<Self> {
        let path = crate::platform::dirs::AppDirs::home()
            .ok()?
            .join(".config/zai/env");
        let file = crate::platform::private_fs::open_external(&path).ok()?;
        let metadata = file.metadata().ok()?;
        if !metadata.is_file()
            || metadata.uid() != unsafe { libc::geteuid() }
            || metadata.mode() & 0o077 != 0
            || metadata.len() > 65536
        {
            return None;
        }
        let mut text = Zeroizing::new(String::new());
        file.take(65537).read_to_string(&mut text).ok()?;
        if text.len() > 65536 {
            return None;
        }
        let token = token(&text)?;
        Some(Self {
            token,
            client: client().ok()?,
        })
    }

    pub(super) async fn complete(
        &self,
        prompt: &str,
        messages: &Value,
    ) -> Result<Value, &'static str> {
        let body = body(prompt, messages)?;
        self.request(ENDPOINT, body).await
    }

    async fn request(&self, endpoint: &str, body: Value) -> Result<Value, &'static str> {
        let mut auth =
            reqwest::header::HeaderValue::from_str(&format!("Bearer {}", self.token.as_str()))
                .map_err(|_| UNAVAILABLE)?;
        auth.set_sensitive(true);
        let mut response = self
            .client
            .post(endpoint)
            .header(reqwest::header::AUTHORIZATION, auth)
            .header("X-Title", "Magpie")
            .header("Accept-Language", "en-US,en")
            .header("Content-Type", "application/json")
            .body(body.to_string())
            .send()
            .await
            .map_err(|_| UNAVAILABLE)?;
        if !response.status().is_success() {
            return Err(UNAVAILABLE);
        }
        let mut bytes = Vec::new();
        while let Some(chunk) = response.chunk().await.map_err(|_| UNAVAILABLE)? {
            if bytes.len() + chunk.len() > 256 * 1024 {
                return Err(INVALID);
            }
            bytes.extend_from_slice(&chunk);
        }
        let value: Value = serde_json::from_slice(&bytes).map_err(|_| INVALID)?;
        if value["choices"][0]["finish_reason"] != "stop" {
            return Err(INVALID);
        }
        let text = value["choices"][0]["message"]["content"]
            .as_str()
            .ok_or(INVALID)?
            .trim();
        let text = text
            .strip_prefix("```json")
            .or_else(|| text.strip_prefix("```"))
            .unwrap_or(text)
            .trim();
        serde_json::from_str(text.strip_suffix("```").unwrap_or(text).trim()).map_err(|_| INVALID)
    }
}

fn client() -> Result<reqwest::Client, reqwest::Error> {
    reqwest::Client::builder()
        .no_proxy()
        .redirect(reqwest::redirect::Policy::none())
        .connect_timeout(Duration::from_secs(10))
        .timeout(Duration::from_secs(90))
        .build()
}

fn token(text: &str) -> Option<Zeroizing<String>> {
    let origin = text.lines().find_map(|line| {
        let line = line.trim().strip_prefix("export ").unwrap_or(line.trim());
        let (name, value) = line.split_once('=')?;
        (name == "ANTHROPIC_BASE_URL")
            .then(|| value.trim().trim_matches(['\'', '"']).trim_end_matches('/'))
    });
    if origin != Some("https://api.z.ai/api/anthropic") {
        return None;
    }
    for line in text.lines() {
        let line = line.trim().strip_prefix("export ").unwrap_or(line.trim());
        let Some((name, value)) = line.split_once('=') else {
            continue;
        };
        if !matches!(name, "ANTHROPIC_AUTH_TOKEN" | "Z_AI_API_KEY") {
            continue;
        }
        let value = value.trim();
        let value = value
            .strip_prefix('"')
            .and_then(|v| v.strip_suffix('"'))
            .or_else(|| value.strip_prefix('\'').and_then(|v| v.strip_suffix('\'')))
            .unwrap_or(value);
        let value = value.strip_prefix("Bearer ").unwrap_or(value);
        if value.is_empty()
            || value.len() > 8192
            || !value
                .bytes()
                .all(|c| c.is_ascii_alphanumeric() || b"-_.".contains(&c))
        {
            return None;
        }
        return Some(Zeroizing::new(value.to_owned()));
    }
    None
}

fn body(prompt: &str, messages: &Value) -> Result<Value, &'static str> {
    let mut content = vec![json!({"type":"text","text":prompt})];
    for message in messages.as_array().ok_or("overview_input_invalid")? {
        for (index, file) in message["files"]
            .as_array()
            .into_iter()
            .flatten()
            .enumerate()
        {
            for block in file["content"]
                .as_array()
                .into_iter()
                .flatten()
                .filter(|block| block["type"] == "image")
            {
                let source = &block["source"];
                if source["type"] != "base64"
                    || !matches!(
                        source["media_type"].as_str(),
                        Some("image/png" | "image/jpeg")
                    )
                {
                    return Err("overview_input_invalid");
                }
                let data = source["data"].as_str().ok_or("overview_input_invalid")?;
                if data.len() > 3 * 1024 * 1024
                    || !data
                        .bytes()
                        .all(|c| c.is_ascii_alphanumeric() || b"+/=".contains(&c))
                {
                    return Err("overview_input_invalid");
                }
                content.push(json!({"type":"text","text":format!("Untrusted media for message {} file:{index}",message["id"])}));
                content.push(json!({"type":"image_url","image_url":{"url":format!("data:{};base64,{data}",source["media_type"].as_str().unwrap())}}));
            }
        }
    }
    let body = json!({"model":"glm-5.3-flash","messages":[{"role":"user","content":content}],"stream":false,"reasoning_effort":"low","max_tokens":4096});
    if serde_json::to_vec(&body)
        .map_err(|_| "overview_input_invalid")?
        .len()
        > 16 * 1024 * 1024
    {
        return Err("overview_input_invalid");
    }
    Ok(body)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn config_is_read_as_data_and_never_supplies_a_destination() {
        assert_eq!(token("export ANTHROPIC_AUTH_TOKEN='synthetic.key-1'\nANTHROPIC_BASE_URL=https://api.z.ai/api/anthropic").unwrap().as_str(),"synthetic.key-1");
        assert!(
            token("ANTHROPIC_AUTH_TOKEN=synthetic\nANTHROPIC_BASE_URL=https://attacker.invalid")
                .is_none()
        );
        for value in ["$(touch /tmp/forbidden)", "a`id`", "a\\nb", "a b", "a\rb"] {
            assert!(token(&format!("ANTHROPIC_BASE_URL=https://api.z.ai/api/anthropic\nANTHROPIC_AUTH_TOKEN='{value}'")).is_none());
        }
        assert_eq!(ENDPOINT, "https://api.z.ai/api/paas/v4/chat/completions");
    }
    #[test]
    fn media_urls_are_fixed_data_and_cannot_fetch_sender_selected_resources() {
        let message = |source: Value| json!([{"id":"a","files":[{"content":[{"type":"image","source":source}]}]}]);
        for source in [
            json!({"type":"url","url":"http://127.0.0.1/private"}),
            json!({"type":"base64","media_type":"image/svg+xml","data":"PHN2Zz4="}),
            json!({"type":"base64","media_type":"image/png","data":"http://127.0.0.1/private"}),
        ] {
            assert!(body("safe", &message(source)).is_err());
        }
        let value = body(
            "untrusted prompt",
            &message(json!({"type":"base64","media_type":"image/png","data":"eA=="})),
        )
        .unwrap();
        assert_eq!(
            value["messages"][0]["content"][2]["image_url"]["url"],
            "data:image/png;base64,eA=="
        );
        assert!(value.get("tools").is_none());
    }
    #[tokio::test]
    async fn credentials_never_follow_redirects_or_enter_errors() {
        use tokio::{
            io::{AsyncReadExt, AsyncWriteExt},
            net::TcpListener,
        };
        let target = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let redirect = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let origin = format!("http://{}", redirect.local_addr().unwrap());
        let location = format!("http://{}", target.local_addr().unwrap());
        let task = tokio::spawn(async move {
            let (mut socket, _) = redirect.accept().await.unwrap();
            let mut input = vec![0; 8192];
            let count = socket.read(&mut input).await.unwrap();
            assert!(String::from_utf8_lossy(&input[..count]).contains("synthetic-token"));
            socket.write_all(format!("HTTP/1.1 302 Found\r\nLocation: {location}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n").as_bytes()).await.unwrap();
        });
        let vision = Vision {
            token: Zeroizing::new("synthetic-token".into()),
            client: client().unwrap(),
        };
        assert_eq!(vision.request(&origin, json!({})).await, Err(UNAVAILABLE));
        task.await.unwrap();
        assert!(
            tokio::time::timeout(Duration::from_millis(150), target.accept())
                .await
                .is_err()
        );
    }
}
