use super::Session;
use crate::mail::tests::{account_fixture, fixture_tree, isolated};
use serde_json::json;
use std::sync::{
    Arc, Mutex,
    atomic::{AtomicUsize, Ordering},
};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::TcpListener,
};

const ACCOUNT: &str = "mail@example.org";

struct Credentials(Arc<AtomicUsize>);
impl crate::credentials::CredentialStore for Credentials {
    fn get(
        &self,
        _: &crate::credentials::CredentialKey,
    ) -> Result<crate::credentials::Secret, crate::credentials::Error> {
        self.0.fetch_add(1, Ordering::SeqCst);
        crate::credentials::Secret::new(b"synthetic-refresh-token".to_vec())
    }
    fn put(
        &self,
        _: &crate::credentials::CredentialKey,
        _: &[u8],
    ) -> Result<(), crate::credentials::Error> {
        panic!("read-only request wrote credentials")
    }
    fn delete(
        &self,
        _: &crate::credentials::CredentialKey,
    ) -> Result<(), crate::credentials::Error> {
        panic!("read-only request deleted credentials")
    }
}

struct Peer {
    origin: String,
    requests: Arc<Mutex<Vec<String>>>,
    task: tokio::task::JoinHandle<()>,
}
impl Drop for Peer {
    fn drop(&mut self) {
        self.task.abort();
    }
}
impl Peer {
    async fn start() -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let origin = format!("http://{}", listener.local_addr().unwrap());
        let requests = Arc::new(Mutex::new(Vec::new()));
        let seen = requests.clone();
        let task = tokio::spawn(async move {
            loop {
                let (mut socket, _) = listener.accept().await.unwrap();
                let mut bytes = Vec::new();
                while !bytes.ends_with(b"\r\n\r\n") {
                    bytes.push(socket.read_u8().await.unwrap());
                    assert!(bytes.len() < 65_536);
                }
                let headers = String::from_utf8(bytes).unwrap();
                let line = headers.lines().next().unwrap().to_owned();
                let length = headers
                    .lines()
                    .find_map(|line| {
                        let (name, value) = line.split_once(':')?;
                        name.eq_ignore_ascii_case("content-length")
                            .then(|| value.trim().parse::<usize>().unwrap())
                    })
                    .unwrap_or(0);
                let mut body = vec![0; length];
                socket.read_exact(&mut body).await.unwrap();
                let value = if line.starts_with("POST /token ") {
                    json!({"access_token":"synthetic-access-token","expires_in":3600})
                } else if line.starts_with("GET /gmail/v1/users/me/settings/sendAs ") {
                    json!({"sendAs":[{"sendAsEmail":ACCOUNT,"displayName":"Mail", "isPrimary":true},
                        {"sendAsEmail":"alias@example.org","displayName":"Alias", "isDefault":true}]})
                } else {
                    panic!("unexpected request: {line}")
                };
                seen.lock().unwrap().push(line);
                let body = value.to_string();
                let reply = format!(
                    "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                    body.len()
                );
                socket.write_all(reply.as_bytes()).await.unwrap();
            }
        });
        Self {
            origin,
            requests,
            task,
        }
    }
}

#[tokio::test]
async fn retired_methods_and_non_gmail_delivery_stop_before_credentials_network_or_storage() {
    if isolated() {
        return;
    }
    let fixture = account_fixture(
        json!({"version":1,"activeId":ACCOUNT,"accounts":[{"provider":"gmail","email":ACCOUNT}]}),
    );
    let gets = Arc::new(AtomicUsize::new(0));
    let _credentials = crate::credentials::tests::isolated_store(Credentials(gets.clone()));
    let peer = Peer::start().await;
    let client = reqwest::Client::builder().no_proxy().build().unwrap();
    let before = fixture_tree(&fixture.root);
    crate::providers::gmail_http::with_test_transport(client, peer.origin.clone(), async {
        let session = Session::default();
        for method in [
            "auth.invalidate",
            "cache.querySession",
            "cache.querySessionGet",
            "auth.store",
            "auth.clear",
            "outlook.graphSend",
            "outlook.connectionCheck",
            "hey.probe",
            "hey.status",
            "hey.profile",
            "hey.sendAs",
            "hey.labels",
            "hey.list",
            "hey.read",
            "hey.loginStart",
            "hey.loginPoll",
            "hey.loginCancel",
            "hey.logout",
            "hey.act",
            "hey.send",
            "hey.saveDraft",
            "imap.request",
            "imap.append",
            "imap.check",
            "imap.folders",
            "imap.list",
            "imap.listContinue",
            "imap.messages",
            "imap.count",
            "imap.cancel",
            "imap.attachment",
            "imap.modify",
            "imap.trash",
            "imap.untrash",
            "imap.createFolder",
            "imap.renameFolder",
            "imap.deleteFolder",
            "imap.saveDraft",
            "imap.deleteDraft",
            "imap.send",
            "smtp.send",
            "jmap.verify",
            "jmap.profile",
            "jmap.session",
            "jmap.list",
            "jmap.messages",
            "jmap.read",
            "jmap.attachment",
            "jmap.labels",
            "jmap.labelCounts",
            "jmap.watch",
            "jmap.modify",
            "jmap.batchModify",
            "jmap.trash",
            "jmap.untrash",
            "jmap.sendAs",
            "jmap.send",
            "jmap.saveDraft",
            "jmap.invalidate",
            "jmap.cancel",
            "jmap.request",
            "jmap.stream.open",
            "jmap.stream.poll",
            "jmap.stream.close",
        ] {
            assert_eq!(session.dispatch(method, &json!({"accountId":ACCOUNT,"raw":"synthetic-private-body","token":"synthetic-secret"})).await, Err("unknown_method"), "{method}");
        }
        for provider in ["imap", "outlook", "hey", "jmap"] {
            let job = json!({"accountId":ACCOUNT,"provider":provider,"payload":{"raw":"synthetic-private-body"}});
            assert_eq!(session.dispatch("outbox.enqueue", &job).await, Err("outbox_invalid_provider"));
            assert_eq!(crate::outbox::delivery::send(&job, &session.gmail).await, Err("outbox_invalid_provider"));
        }
    }).await;
    assert_eq!(gets.load(Ordering::SeqCst), 0);
    assert!(peer.requests.lock().unwrap().is_empty());
    assert_eq!(fixture_tree(&fixture.root), before);
}

#[tokio::test]
async fn gmail_send_preview_reads_only_authorized_identities_and_preserves_storage() {
    if isolated() {
        return;
    }
    let fixture = account_fixture(
        json!({"version":1,"activeId":ACCOUNT,"accounts":[{"provider":"gmail","email":ACCOUNT}]}),
    );
    let directory = crate::platform::private_fs::directories(
        &fixture.config,
        &[crate::platform::dirs::APP_DIRECTORY],
        true,
    )
    .unwrap()
    .unwrap();
    crate::platform::private_fs::atomic_replace(&directory, "credentials.json", br#"{"installed":{"client_id":"123-mail.apps.googleusercontent.com","client_secret":"synthetic-client-secret"}}"#).unwrap();
    let path = fixture.root.join("attachment.txt");
    std::fs::write(&path, b"synthetic attachment").unwrap();
    let gets = Arc::new(AtomicUsize::new(0));
    let _credentials = crate::credentials::tests::isolated_store(Credentials(gets.clone()));
    let peer = Peer::start().await;
    let client = reqwest::Client::builder().no_proxy().build().unwrap();
    let before = fixture_tree(&fixture.root);
    crate::providers::gmail_http::with_test_transport(client, peer.origin.clone(), async {
        let session = Session::default();
        let params = json!({"to":["one@example.org","two@example.org"],"cc":["three@example.org"],"bcc":["four@example.org"],"subject":"Unicode 工","body":"private body 工\nsecond\r\nthird\tline","attachments":[{"path":path,"name":"attachment.txt","size":20}]});
        let preview = session.dispatch("mail.send", &params).await.unwrap();
        assert_eq!(preview, json!({"dryRun":true,"executed":false,"accountId":ACCOUNT,"from":"Alias <alias@example.org>","to":params["to"],"cc":params["cc"],"bcc":params["bcc"],"subject":params["subject"],"body":params["body"],"attachments":[{"name":"attachment.txt","size":20}]}));
        let count = peer.requests.lock().unwrap().len();
        for bad in ["bad\r", "bad\n", "bad\r\n", "bad\0"] {
            let mut invalid = params.clone();
            invalid["subject"] = json!(bad);
            assert_eq!(session.dispatch("mail.send", &invalid).await, Err("invalid_params"));
        }
        assert_eq!(peer.requests.lock().unwrap().len(), count);
        let mut unapproved = params;
        unapproved["from"] = json!("other-account@example.org");
        assert_eq!(session.dispatch("mail.send", &unapproved).await, Err("mail_send_sender_unavailable"));
    }).await;
    assert_eq!(gets.load(Ordering::SeqCst), 1);
    let requests = peer.requests.lock().unwrap();
    assert_eq!(
        requests
            .iter()
            .filter(|line| line.starts_with("POST "))
            .count(),
        1
    );
    assert_eq!(
        requests
            .iter()
            .filter(|line| line.contains("settings/sendAs"))
            .count(),
        2
    );
    assert_eq!(fixture_tree(&fixture.root), before);
}
