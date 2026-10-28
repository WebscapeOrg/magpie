//! Authentication network boundary. Credential destinations are fixed here.
use serde_json::{Value, json};
use std::{sync::OnceLock, time::Duration};

mod callback;
mod credentials;
pub use credentials::{settings, settings_readonly};

#[derive(Default)]
pub struct Session {
    flows: callback::Flows,
}

static CLIENT: OnceLock<Result<reqwest::Client, &'static str>> = OnceLock::new();
const MAX_AUTH_PAYLOAD_BYTES: usize = 256 * 1024;

fn client() -> Result<&'static reqwest::Client, &'static str> {
    CLIENT
        .get_or_init(|| {
            crate::platform::http_client()
                .https_only(true)
                .no_proxy()
                .redirect(reqwest::redirect::Policy::none())
                .connect_timeout(Duration::from_secs(10))
                .timeout(Duration::from_secs(20))
                .build()
                .map_err(|_| "auth_transport_failed")
        })
        .as_ref()
        .map_err(|error| *error)
}

fn destination(parameters: &Value) -> Result<String, &'static str> {
    let fields = parameters.as_object().ok_or("invalid_params")?;
    if fields
        .keys()
        .any(|key| !["provider", "endpoint", "body"].contains(&key.as_str()))
    {
        return Err("invalid_params");
    }
    match (
        parameters["provider"].as_str(),
        parameters["endpoint"].as_str(),
    ) {
        (Some("gmail"), Some("token")) => Ok("https://oauth2.googleapis.com/token".into()),
        _ => Err("invalid_params"),
    }
}

async fn post(client: &reqwest::Client, url: &str, body: String) -> Result<Value, &'static str> {
    post_with_deadline(client, url, body, Duration::from_secs(20)).await
}

async fn post_with_deadline(
    client: &reqwest::Client,
    url: &str,
    body: String,
    deadline: Duration,
) -> Result<Value, &'static str> {
    tokio::time::timeout(deadline, async {
        let mut response = client
            .post(url)
            .header(
                reqwest::header::CONTENT_TYPE,
                "application/x-www-form-urlencoded",
            )
            .body(body)
            .send()
            .await
            .map_err(|_| "auth_transport_failed")?;
        let status = response.status();
        if status.is_redirection() {
            return Err("auth_redirect_refused");
        }
        if response
            .content_length()
            .is_some_and(|size| size > MAX_AUTH_PAYLOAD_BYTES as u64)
        {
            return Err("auth_response_too_large");
        }
        let mut bytes = Vec::new();
        while let Some(chunk) = response
            .chunk()
            .await
            .map_err(|_| "auth_transport_failed")?
        {
            if chunk.len() > MAX_AUTH_PAYLOAD_BYTES - bytes.len() {
                return Err("auth_response_too_large");
            }
            bytes.extend_from_slice(&chunk);
        }
        let body = String::from_utf8(bytes).map_err(|_| "auth_invalid_response")?;
        let parsed: Value = serde_json::from_str(&body).map_err(|_| "auth_invalid_response")?;
        if !parsed.is_object() {
            return Err("auth_invalid_response");
        }
        Ok(json!({"status": status.as_u16(), "body": body}))
    })
    .await
    .map_err(|_| "auth_timeout")?
}

impl Session {
    pub async fn shutdown(&self) {
        self.flows.shutdown().await;
    }
    pub async fn call(&self, method: &str, parameters: &Value) -> Result<Value, &'static str> {
        if method != "auth.form" {
            return self.flows.call(method, parameters).await;
        }
        let url = destination(parameters)?;
        let body = parameters["body"].as_str().ok_or("invalid_params")?;
        if body.len() > MAX_AUTH_PAYLOAD_BYTES || body.bytes().any(|byte| byte < 32 || byte == 127)
        {
            return Err("invalid_params");
        }
        post(client()?, &url, body.into()).await
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[tokio::test]
    async fn native_deadline_cancels_a_server_that_never_answers() {
        use tokio::{io::AsyncReadExt, net::TcpListener};
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let server = tokio::spawn(async move {
            let (mut socket, _) = listener.accept().await.unwrap();
            let mut request = [0; 4096];
            assert!(socket.read(&mut request).await.unwrap() > 0);
            let ended = tokio::time::timeout(Duration::from_secs(1), socket.read(&mut request))
                .await
                .unwrap()
                .unwrap();
            assert_eq!(ended, 0, "deadline must close the outstanding request");
        });
        let client = crate::platform::http_client().no_proxy().build().unwrap();
        assert_eq!(
            post_with_deadline(
                &client,
                &format!("http://{address}"),
                "refresh_token=synthetic".into(),
                Duration::from_millis(50)
            )
            .await,
            Err("auth_timeout")
        );
        server.await.unwrap();
    }

    #[tokio::test]
    async fn oversized_token_response_is_refused_before_body_collection() {
        use tokio::{
            io::{AsyncReadExt, AsyncWriteExt},
            net::TcpListener,
        };
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let server = tokio::spawn(async move {
            let (mut socket, _) = listener.accept().await.unwrap();
            let mut request = [0; 4096];
            assert!(socket.read(&mut request).await.unwrap() > 0);
            socket
                .write_all(
                    format!(
                        "HTTP/1.1 200 OK\r\nContent-Length: {}\r\n\r\n",
                        MAX_AUTH_PAYLOAD_BYTES + 1
                    )
                    .as_bytes(),
                )
                .await
                .unwrap();
        });
        let client = crate::platform::http_client().no_proxy().build().unwrap();
        assert_eq!(
            post(
                &client,
                &format!("http://{address}"),
                "refresh_token=synthetic".into()
            )
            .await,
            Err("auth_response_too_large")
        );
        server.await.unwrap();
    }
    #[test]
    fn credentials_cannot_choose_a_destination() {
        for tenant in [
            "https://evil.test",
            "a/b",
            "a%2fb",
            "a\\b",
            "..",
            "a..b",
            "a\n",
            "a\0",
            "@evil",
        ] {
            assert!(
                destination(&json!({"provider":"outlook","endpoint":"token","tenant":tenant}))
                    .is_err()
            );
        }
        assert_eq!(
            destination(&json!({"provider":"gmail","endpoint":"token"})).unwrap(),
            "https://oauth2.googleapis.com/token"
        );
        for provider in ["outlook", "imap", "jmap", "hey", "caldav"] {
            assert_eq!(
                destination(&json!({"provider":provider,"endpoint":"token"})),
                Err("invalid_params")
            );
        }
        assert!(
            destination(&json!({"provider":"gmail","endpoint":"token","url":"https://evil.test"}))
                .is_err()
        );
    }
    #[tokio::test]
    async fn redirect_never_receives_form_credentials() {
        use tokio::{
            io::{AsyncReadExt, AsyncWriteExt},
            net::TcpListener,
        };
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let server = tokio::spawn(async move {
            let (mut socket, _) = listener.accept().await.unwrap();
            let mut bytes = [0; 4096];
            assert!(socket.read(&mut bytes).await.unwrap() > 0);
            socket.write_all(b"HTTP/1.1 302 Found\r\nLocation: /stolen\r\nContent-Length: 0\r\nConnection: close\r\n\r\n").await.unwrap();
            assert!(
                tokio::time::timeout(Duration::from_millis(100), listener.accept())
                    .await
                    .is_err()
            );
        });
        let client = crate::platform::http_client()
            .no_proxy()
            .redirect(reqwest::redirect::Policy::none())
            .build()
            .unwrap();
        assert_eq!(
            post(
                &client,
                &format!("http://{address}"),
                "token=synthetic".into()
            )
            .await,
            Err("auth_redirect_refused")
        );
        server.await.unwrap();
    }
}

#[cfg(feature = "mobile")]
pub async fn mobile_exchange(params: &Value) -> Result<Value, &'static str> {
    let client_id = params["clientId"].as_str().ok_or("invalid_params")?;
    let code = params["code"].as_str().ok_or("invalid_params")?;
    let verifier = params["verifier"].as_str().ok_or("invalid_params")?;
    let redirect = params["redirectURI"].as_str().ok_or("invalid_params")?;
    let prefix = client_id
        .strip_suffix(".apps.googleusercontent.com")
        .ok_or("invalid_params")?;
    if prefix.len() > 512
        || !prefix
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-')
        || !prefix.contains('-')
        || !(43..=128).contains(&verifier.len())
        || !verifier
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"-._~".contains(&b))
        || code.is_empty()
        || code.len() > 16384
        || code.chars().any(char::is_control)
        || redirect != format!("com.googleusercontent.apps.{prefix}:/oauthredirect")
    {
        return Err("invalid_params");
    }
    let body = reqwest::Url::parse_with_params(
        "https://unused.invalid/",
        &[
            ("client_id", client_id),
            ("code", code),
            ("code_verifier", verifier),
            ("redirect_uri", redirect),
            ("grant_type", "authorization_code"),
        ],
    )
    .map_err(|_| "invalid_params")?
    .query()
    .unwrap_or("")
    .to_owned();
    callback::finish_google(
        post(client()?, "https://oauth2.googleapis.com/token", body).await?,
        client_id,
    )
    .await
}
