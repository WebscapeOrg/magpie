use super::*;

#[test]
fn google_requests_keep_calendar_identity_and_preconditions() {
    let request = prepare(&json!({"source":{"kind":"google","calendarId":"family/a?b@example.org"},
        "operation":"update","eventId":"instance/one","body":"{}","ifMatch":"\"revision\"","sendUpdates":"all"})).unwrap();
    assert_eq!(request.url.host_str(), Some("www.googleapis.com"));
    assert_eq!(
        request.url.path(),
        "/calendar/v3/calendars/family%2Fa%3Fb@example.org/events/instance%2Fone"
    );
    assert_eq!(request.if_match.as_deref(), Some("\"revision\""));
    assert!(
        request
            .url
            .query_pairs()
            .any(|(k, v)| k == "conferenceDataVersion" && v == "1")
    );
    assert!(
        prepare(
            &json!({"source":{"kind":"google","calendarId":".."},"operation":"get","eventId":"x"})
        )
        .is_err()
    );
    assert!(prepare(&json!({"source":{"kind":"caldav"},"operation":"move"})).is_err());
}
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::TcpListener,
};

#[test]
fn provider_chooses_origin_and_encodes_event_id() {
    let request = prepare(&json!({"source":{"kind":"google"},"operation":"delete","eventId":"https://evil.example/a?b"})).unwrap();
    assert_eq!(request.url.host_str(), Some("www.googleapis.com"));
    assert!(
        request
            .url
            .path()
            .ends_with("https:%2F%2Fevil.example%2Fa%3Fb")
    );
    assert!(
        prepare(&json!({"source":{"kind":"google"},"operation":"delete","eventId":".."})).is_err()
    );
}

async fn server(response: &'static str) -> (Url, tokio::task::JoinHandle<Vec<u8>>) {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = Url::parse(&format!("http://{}/", listener.local_addr().unwrap())).unwrap();
    let handle = tokio::spawn(async move {
        let (mut socket, _) = listener.accept().await.unwrap();
        let mut bytes = vec![0; 8192];
        let n = socket.read(&mut bytes).await.unwrap();
        bytes.truncate(n);
        socket.write_all(response.as_bytes()).await.unwrap();
        bytes
    });
    (url, handle)
}

fn local_request(url: Url) -> Request {
    Request {
        if_match: None,
        url,
        method: Method::GET,
        body: String::new(),
    }
}

#[tokio::test]
async fn google_mutation_keeps_revision_and_never_follows_redirect() {
    let client = Client::builder()
        .no_proxy()
        .redirect(reqwest::redirect::Policy::none())
        .timeout(Duration::from_secs(2))
        .build()
        .unwrap();
    let target = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let response = Box::leak(format!("HTTP/1.1 307 Temporary Redirect\r\nLocation: http://{}/stolen\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", target.local_addr().unwrap()).into_boxed_str());
    let (url, task) = server(response).await;
    let mut request = prepare(&json!({"source":{"kind":"google","calendarId":"shared@example.org"},
        "operation":"update","eventId":"event","body":"{\"summary\":\"synthetic\"}","ifMatch":"\"revision\"","sendUpdates":"none"})).unwrap();
    request.url = url;
    assert!(
        execute(&client, request, Some("synthetic-calendar-token"))
            .await
            .is_err()
    );
    let bytes = String::from_utf8(task.await.unwrap())
        .unwrap()
        .to_lowercase();
    assert!(bytes.starts_with("patch "));
    assert!(bytes.contains("if-match: \"revision\""));
    assert!(bytes.contains("authorization: bearer synthetic-calendar-token"));
    assert!(
        tokio::time::timeout(Duration::from_millis(100), target.accept())
            .await
            .is_err()
    );
    for suffix in ["\r", "\n", "\r\n", "\0"] {
        assert!(
            prepare(
                &json!({"source":{"kind":"google"},"operation":"update","eventId":"event",
            "body":"{}","ifMatch":format!("revision{suffix}")})
            )
            .is_err()
        );
    }
}

#[tokio::test]
async fn native_http_returns_body_and_refuses_redirects() {
    let client = Client::builder()
        .no_proxy()
        .redirect(reqwest::redirect::Policy::none())
        .timeout(Duration::from_secs(2))
        .build()
        .unwrap();
    let (url, task) =
        server("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}").await;
    assert_eq!(
        execute(&client, local_request(url), Some("synthetic-token"))
            .await
            .unwrap()["body"],
        "{}"
    );
    let raw = String::from_utf8(task.await.unwrap()).unwrap();
    assert!(
        raw.to_lowercase()
            .contains("authorization: bearer synthetic-token")
    );
    let target = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let response=Box::leak(format!("HTTP/1.1 302 Found\r\nLocation: http://{}/stolen\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",target.local_addr().unwrap()).into_boxed_str());
    let (url, task) = server(response).await;
    assert_eq!(
        execute(&client, local_request(url), Some("synthetic-token"))
            .await
            .unwrap_err(),
        "calendar_request_failed"
    );
    task.await.unwrap();
    assert!(
        tokio::time::timeout(Duration::from_millis(100), target.accept())
            .await
            .is_err()
    );
}

#[tokio::test]
async fn native_http_bounds_downloads() {
    let client = Client::builder().no_proxy().build().unwrap();
    let (url, task) =
        server("HTTP/1.1 200 OK\r\nContent-Length: 16777217\r\nConnection: close\r\n\r\n").await;
    assert_eq!(
        execute(&client, local_request(url), Some("test"))
            .await
            .unwrap_err(),
        "calendar_response_too_large"
    );
    task.await.unwrap();
}

#[tokio::test]
async fn google_move_sends_explicit_zero_content_length() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let mut request = prepare(&json!({"source":{"kind":"google","calendarId":"family@example.test"},
        "operation":"move","eventId":"meeting","destination":"owner@example.test","sendUpdates":"none"})).unwrap();
    assert_eq!(request.method, Method::POST);
    assert!(request.url.path().ends_with("/events/meeting/move"));
    assert!(
        request
            .url
            .query_pairs()
            .any(|(key, value)| key == "destination" && value == "owner@example.test")
    );
    request.url.set_scheme("http").unwrap();
    request.url.set_host(Some("127.0.0.1")).unwrap();
    request
        .url
        .set_port(Some(listener.local_addr().unwrap().port()))
        .unwrap();
    let server = tokio::spawn(async move {
        let (mut socket, _) = listener.accept().await.unwrap();
        let mut headers = Vec::new();
        loop {
            let mut byte = [0];
            socket.read_exact(&mut byte).await.unwrap();
            headers.push(byte[0]);
            if headers.ends_with(b"\r\n\r\n") {
                break;
            }
            assert!(headers.len() < 16384);
        }
        let text = String::from_utf8(headers).unwrap().to_lowercase();
        let framed = text.contains("\r\ncontent-length: 0\r\n");
        let reply = if framed {
            "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}"
        } else {
            "HTTP/1.1 411 Length Required\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        };
        socket.write_all(reply.as_bytes()).await.unwrap();
        assert!(framed, "empty Google POST must state its content length");
    });
    let client = Client::builder()
        .no_proxy()
        .timeout(Duration::from_secs(2))
        .build()
        .unwrap();
    assert!(
        execute(&client, request, Some("synthetic-token"))
            .await
            .is_ok()
    );
    server.await.unwrap();
}

#[tokio::test]
async fn independent_calendar_requests_progress_concurrently() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = Url::parse(&format!("http://{}/", listener.local_addr().unwrap())).unwrap();
    // Invariant: No response until all three requests arrived: a serial transport cannot
    // finish this exchange. The timeout only prevents a regression hanging CI.
    let server = tokio::spawn(async move {
        let mut sockets = Vec::new();
        for _ in 0..3 {
            let (mut socket, _) = listener.accept().await.unwrap();
            let mut bytes = [0; 4096];
            assert!(socket.read(&mut bytes).await.unwrap() > 0);
            sockets.push(socket);
        }
        for mut socket in sockets {
            socket
                .write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}")
                .await
                .unwrap();
        }
    });
    let client = Client::builder()
        .no_proxy()
        .timeout(Duration::from_secs(2))
        .build()
        .unwrap();
    let (one, two, three) = tokio::join!(
        execute(&client, local_request(url.clone()), Some("test")),
        execute(&client, local_request(url.clone()), Some("test")),
        execute(&client, local_request(url), Some("test"))
    );
    assert!(one.is_ok() && two.is_ok() && three.is_ok());
    server.await.unwrap();
}

#[test]
fn pagination_keeps_google_origin_and_encodes_tokens() {
    let origin = Url::parse(
        "https://www.googleapis.com/calendar/v3/calendars/primary/events?singleEvents=true",
    )
    .unwrap();
    let next = next_page(&origin, &json!({"nextPageToken":"a&evil=value"}))
        .unwrap()
        .unwrap();
    assert_eq!(next.origin(), origin.origin());
    assert_eq!(next.path(), origin.path());
    assert_eq!(
        next.query_pairs()
            .find(|(key, _)| key == "pageToken")
            .unwrap()
            .1,
        "a&evil=value"
    );
    for token in ["bad\r", "bad\n", "bad\0"] {
        assert!(next_page(&origin, &json!({"nextPageToken":token})).is_err());
    }
}

#[tokio::test]
async fn unsupported_calendars_never_contact_the_configured_destination() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    for kind in ["caldav", "icloud", "microsoft", "hey", "unknown"] {
        let params = json!({"source":{"kind":kind,"id":"saved", "accountId":"saved",
            "url":format!("https://{}/calendar/", listener.local_addr().unwrap()),"username":"synthetic"},
            "operation":"list","body":"synthetic"});
        assert_eq!(
            call(&params, Some("synthetic-token")).await,
            Err("calendar_provider_unsupported")
        );
        assert!(
            tokio::time::timeout(Duration::from_millis(30), listener.accept())
                .await
                .is_err()
        );
    }
}
