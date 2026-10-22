use super::*;
use std::io::{BufRead, BufReader};
pub(in crate::providers::jmap) struct Peer(pub(in crate::providers::jmap) std::process::Child);
impl Drop for Peer {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}
#[tokio::test]
async fn native_mailbox_read_thread_actions_and_submission_preserve_workflow() {
    let (mut peer, session, client, port) =
        tokio::task::spawn_blocking(mailbox_peer).await.unwrap();
    let context = session.context("jmap:user@example.test").unwrap();
    let call = |method: &'static str, mut params: Value| {
        params["accountId"] = json!("jmap:user@example.test");
        let session = &session;
        async move { session.native(method, &params).await }
    };
    let page = call(
        "jmap.list",
        json!({"query":"role:inbox unseen","maxResults":25,"pageToken":"25|gone"}),
    )
    .await
    .unwrap();
    assert_eq!(page["data"]["ids"], json!(["e1"]));
    let messages = call("jmap.messages", json!({"ids":["e1"]})).await.unwrap();
    assert_eq!(
        messages["data"][0]["thread"]["memberIds"],
        json!(["e1", "e2"])
    );
    assert_eq!(messages["data"][0]["snippet"], "&lt;3 native");
    let read = call("jmap.read", json!({"id":"e1","full":true}))
        .await
        .unwrap();
    let body = base64::engine::general_purpose::URL_SAFE_NO_PAD
        .decode(string(&read["data"]["payload"]["body"]["data"]))
        .unwrap();
    assert_eq!(body, b"complete body");
    call(
        "jmap.batchModify",
        json!({"ids":["e1","e2"],"addLabelIds":[],"removeLabelIds":["INBOX"]}),
    )
    .await
    .unwrap();
    for (subject, expect) in [
        ("importfail", Err("jmap_import_failed")),
        ("fail", Err("jmap_submission_failed")),
        ("success", Ok(())),
        ("uncertain", Err("jmap_submission_unconfirmed")),
    ] {
        let raw = base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(format!(
            "From: user@example.test\r\nTo: a@example.test\r\nSubject: {subject}\r\n\r\nBody\r\n"
        ));
        let result = call("jmap.send", json!({"raw":raw,"draftId":"original"})).await;
        if subject == "success" {
            assert_eq!(result.as_ref().unwrap()["data"]["draftRemoved"], true);
        }
        assert_eq!(result.map(|_| ()), expect);
    }
    let raw = base64::engine::general_purpose::URL_SAFE_NO_PAD
        .encode("From: user@example.test\r\nTo: a@example.test\r\nSubject: draft\r\n\r\nBody");
    let saved = call("jmap.saveDraft", json!({"raw":raw,"draftId":"old-fail"}))
        .await
        .unwrap();
    assert_eq!(saved["data"]["saved"], true);
    assert_eq!(saved["data"]["draftId"], "newdraft");
    assert!(!string(&saved["data"]["warning"]).is_empty());
    call("jmap.watch", json!({"streamId":"native-watch"}))
        .await
        .unwrap();
    let mut changed = false;
    for _ in 0..3 {
        let events = session
            .call("jmap.stream.poll", &json!({"streamId":"native-watch"}))
            .await
            .unwrap();
        for event in events["events"].as_array().unwrap() {
            if event["kind"] == "change" {
                assert_eq!(event["plan"], json!({"mail":true,"mailboxes":true}));
                changed = true;
            }
        }
        if changed {
            break;
        }
    }
    assert!(
        changed,
        "native SSE must deliver account-scoped invalidations"
    );
    session
        .call("jmap.stream.close", &json!({"streamId":"native-watch"}))
        .await
        .unwrap();
    context.snapshot.lock().await.as_mut().unwrap().document["apiUrl"] =
        json!(format!("https://localhost:{port}/refused"));
    for id in ["not-cached-1", "not-cached-2"] {
        assert_eq!(
            call("jmap.messages", json!({"ids":[id]})).await,
            Err("jmap_unauthorized")
        );
    }
    let retired_snapshot = context.snapshot.lock().await.clone().unwrap();
    call("jmap.invalidate", json!({})).await.unwrap();
    assert_eq!(
        session
            .api(
                &context,
                &retired_snapshot,
                json!([["Mailbox/get",{"accountId":"account","ids":null},"0"]]),
                false
            )
            .await,
        Err("jmap_cancelled")
    );
    let report: Value = serde_json::from_slice(
        &client
            .get(format!("https://localhost:{port}/report"))
            .send()
            .await
            .unwrap()
            .bytes()
            .await
            .unwrap(),
    )
    .unwrap();
    assert_eq!(
        report
            .as_array()
            .unwrap()
            .iter()
            .filter(|r| r["path"] == "/refused")
            .count(),
        1,
        "revoked credentials must never be retried"
    );
    let calls: Vec<_> = report
        .as_array()
        .unwrap()
        .iter()
        .flat_map(|request| request["calls"].as_array().into_iter().flatten())
        .collect();
    let update = calls
        .iter()
        .find(|call| call[0] == "Email/set" && call[1]["update"].is_object())
        .unwrap();
    assert_eq!(
        update[1]["update"],
        json!({"e1":{"mailboxIds/A":true,"mailboxIds/I":null}})
    );
    let destroyed: Vec<_> = calls
        .iter()
        .filter(|call| call[0] == "Email/set")
        .flat_map(|call| call[1]["destroy"].as_array().into_iter().flatten().cloned())
        .collect();
    assert_eq!(
        destroyed,
        json!(["newdraft", "original", "old-fail"])
            .as_array()
            .unwrap()
            .clone()
    );
    assert_eq!(
        calls
            .iter()
            .filter(|call| call[0] == "EmailSubmission/set")
            .count(),
        3
    );
    assert!(
        calls
            .iter()
            .any(|call| call[0] == "Email/get" && call[1]["ids"] == json!(["e1", "e2"]))
    );
    assert!(
        report
            .as_array()
            .unwrap()
            .iter()
            .all(|r| r["authorization"] == true)
    );
    assert!(peer.0.wait().unwrap().success());
}

#[test]
fn retained_caches_evict_by_bytes_and_skip_oversized_entries() {
    let mut cache = Cache::default();
    for n in 0..100 {
        cache.insert(n.to_string(), json!("x".repeat(100_000)));
        assert!(cache.bytes <= CACHE_BYTES);
    }
    assert!(cache.len() < 100);
    cache.insert("oversized".into(), json!("x".repeat(CACHE_BYTES)));
    assert!(cache.get("oversized").is_none());
    assert!(cache.bytes <= CACHE_BYTES);
    cache.clear();
    assert_eq!(cache.bytes, 0);
}

#[test]
fn oversized_cache_replacement_drops_the_stale_entry() {
    let mut cache = Cache::default();
    cache.insert("message".into(), json!({"subject":"old"}));
    cache.insert("other".into(), json!({"subject":"kept"}));
    cache.insert("message".into(), json!("x".repeat(CACHE_BYTES)));
    assert!(cache.get("message").is_none());
    assert_eq!(cache.get("other"), Some(&json!({"subject":"kept"})));
    assert_eq!(
        cache.bytes,
        cache
            .entries
            .values()
            .map(|(_, bytes)| bytes)
            .sum::<usize>()
    );
}

#[tokio::test]
async fn native_watch_rejects_unmanageable_stream_ids_before_starting_a_stream() {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let session = Session::default();
    let account = "jmap:watch-validation@example.test";
    session.install_verified(
        account,
        json!({
            "apiUrl":format!("https://localhost:{port}/api"),
            "eventSourceUrl":format!("https://localhost:{port}/events"),
            "capabilities":{CORE:{},MAIL:{}},
            "primaryAccounts":{MAIL:"account"},
            "accounts":{"account":{"accountCapabilities":{MAIL:{"emailQuerySortOptions":["receivedAt"]}}}}
        }),
        vec![],
        json!({"scheme":"basic","username":"synthetic","secret":"synthetic"}),
        "watch-validation@example.test",
    ).await.unwrap();
    for stream_id in [
        String::new(),
        "x".repeat(257),
        "watch\r".into(),
        "watch\n".into(),
        "watch\r\n".into(),
        "watch\0".into(),
    ] {
        assert_eq!(
            session
                .native(
                    "jmap.watch",
                    &json!({"accountId":account,"streamId":stream_id})
                )
                .await,
            Err("invalid_params")
        );
        assert!(session.streams.lock().unwrap().is_empty());
    }
    assert!(
        tokio::time::timeout(Duration::from_millis(20), listener.accept())
            .await
            .is_err()
    );
}

pub(in crate::providers::jmap) fn mailbox_peer() -> (Peer, Session, reqwest::Client, u16) {
    let mut peer = Peer(
        std::process::Command::new("python3")
            .arg(concat!(
                env!("CARGO_MANIFEST_DIR"),
                "/src/providers/jmap/mailbox_tls_test.py"
            ))
            .stdout(std::process::Stdio::piped())
            .spawn()
            .unwrap(),
    );
    let mut output = BufReader::new(peer.0.stdout.take().unwrap());
    let mut port = String::new();
    output.read_line(&mut port).unwrap();
    let port: u16 = port.trim().parse().unwrap();
    let mut cert = String::new();
    output.read_line(&mut cert).unwrap();
    let client = client_builder()
        .add_root_certificate(
            reqwest::Certificate::from_pem(&std::fs::read(cert.trim()).unwrap()).unwrap(),
        )
        .build()
        .unwrap();
    let session = Session {
        client: Ok(client.clone()),
        ..Default::default()
    };
    let context = session.context("jmap:user@example.test").unwrap();
    let boxes = vec![
        json!({"id":"I","role":"inbox"}),
        json!({"id":"S","role":"sent"}),
        json!({"id":"T","role":"trash"}),
        json!({"id":"A","role":"archive"}),
        json!({"id":"D","role":"drafts"}),
    ];
    let document = json!({"apiUrl":format!("https://localhost:{port}/api"),"downloadUrl":format!("https://localhost:{port}/blob/{{blobId}}"),"uploadUrl":format!("https://localhost:{port}/upload"),"eventSourceUrl":format!("https://localhost:{port}/events"),"state":"s1","capabilities":{CORE:{"maxObjectsInGet":2,"maxObjectsInSet":2},MAIL:{},SUBMISSION:{}},"accounts":{"account":{"accountCapabilities":{MAIL:{"emailQuerySortOptions":["receivedAt"]},SUBMISSION:{}}}},"primaryAccounts":{MAIL:"account"}});
    *context.snapshot.blocking_lock() = Some(Snapshot {
        document,
        roles: query::roles(&boxes),
        boxes,
        credential: json!({"scheme":"basic","username":"user","secret":"synthetic"}),
        address: "user@example.test".into(),
        account: "account".into(),
        slots: Arc::new(Semaphore::new(4)),
        uploads: Arc::new(Semaphore::new(2)),
    });
    (peer, session, client, port)
}

#[tokio::test]
async fn native_mutations_require_complete_acknowledgements() {
    let (mut peer, session, client, port) =
        tokio::task::spawn_blocking(mailbox_peer).await.unwrap();
    let context = session.context("jmap:user@example.test").unwrap();
    let mut outcomes = Vec::new();
    for case in [
        "missing",
        "wrong-shape",
        "foreign",
        "overlap",
        "failure-shape",
        "valid",
        "not-found",
    ] {
        context.snapshot.lock().await.as_mut().unwrap().document["apiUrl"] =
            json!(format!("https://localhost:{port}/ack/{case}"));
        for targets in [json!(["e1"]), json!(["e1", "e2"])] {
            let result = session
                .native(
                    "jmap.batchModify",
                    &json!({"accountId":"jmap:user@example.test", "ids":targets,
                "removeLabelIds":["UNREAD"], "addLabelIds":[]}),
                )
                .await;
            outcomes.push((case, targets.as_array().unwrap().len(), result.is_ok()));
        }
    }
    let report: Value = serde_json::from_slice(
        &client
            .get(format!("https://localhost:{port}/report"))
            .send()
            .await
            .unwrap()
            .bytes()
            .await
            .unwrap(),
    )
    .unwrap();
    assert!(peer.0.wait().unwrap().success());
    assert_eq!(
        report.as_array().unwrap().len(),
        14,
        "no unconfirmed mutation is retried"
    );
    for (case, count, succeeded) in outcomes {
        assert_eq!(
            succeeded,
            case == "valid" || (case == "not-found" && count > 1),
            "{case}, {count} targets"
        );
    }
}

#[tokio::test]
async fn native_draft_cleanup_requires_complete_acknowledgements() {
    let (mut peer, session, client, port) =
        tokio::task::spawn_blocking(mailbox_peer).await.unwrap();
    let context = session.context("jmap:user@example.test").unwrap();
    let raw = base64::engine::general_purpose::URL_SAFE_NO_PAD
        .encode("From: user@example.test\r\nTo: a@example.test\r\nSubject: draft\r\n\r\nBody");
    let mut outcomes = Vec::new();
    for case in [
        "missing",
        "wrong-shape",
        "foreign",
        "overlap",
        "failure-shape",
        "valid",
        "not-found",
    ] {
        context.snapshot.lock().await.as_mut().unwrap().document["apiUrl"] =
            json!(format!("https://localhost:{port}/ack/{case}"));
        let result = session
            .native(
                "jmap.saveDraft",
                &json!({"accountId":"jmap:user@example.test", "raw":raw, "draftId":"original"}),
            )
            .await
            .unwrap();
        assert_eq!(result["data"]["saved"], true);
        outcomes.push((case, !string(&result["data"]["warning"]).is_empty()));
    }
    let report: Value = serde_json::from_slice(
        &client
            .get(format!("https://localhost:{port}/report"))
            .send()
            .await
            .unwrap()
            .bytes()
            .await
            .unwrap(),
    )
    .unwrap();
    assert!(peer.0.wait().unwrap().success());
    let destroys = report
        .as_array()
        .unwrap()
        .iter()
        .flat_map(|request| request["calls"].as_array().into_iter().flatten())
        .filter(|call| call[0] == "Email/set" && call[1]["destroy"].is_array())
        .count();
    assert_eq!(destroys, 7, "unconfirmed draft cleanup is never retried");
    for (case, warned) in outcomes {
        assert_eq!(warned, case != "valid" && case != "not-found", "{case}");
    }
}

#[tokio::test]
async fn native_queued_requests_recheck_account_lifetime_before_connecting() {
    let (mut peer, session, client, port) =
        tokio::task::spawn_blocking(mailbox_peer).await.unwrap();
    let context = session.context("jmap:user@example.test").unwrap();
    let mut outcomes = Vec::new();
    for method in ["jmap.labels", "jmap.attachment"] {
        for state in ["active", "retired", "rejected"] {
            context
                .retired
                .store(false, std::sync::atomic::Ordering::Release);
            context
                .rejected
                .store(false, std::sync::atomic::Ordering::Release);
            let snapshot = context.snapshot.lock().await.clone().unwrap();
            let slots = if method == "jmap.labels" {
                &session.slots
            } else {
                snapshot.slots.as_ref()
            };
            let held = slots
                .acquire_many(slots.available_permits() as u32)
                .await
                .unwrap();
            let params = json!({"accountId":"jmap:user@example.test", "attachmentId":"test"});
            let operation = session.native(method, &params);
            tokio::pin!(operation);
            assert!(
                tokio::time::timeout(Duration::from_millis(20), &mut operation)
                    .await
                    .is_err(),
                "request must be queued"
            );
            if state == "retired" {
                context
                    .retired
                    .store(true, std::sync::atomic::Ordering::Release);
            }
            if state == "rejected" {
                context
                    .rejected
                    .store(true, std::sync::atomic::Ordering::Release);
            }
            drop(held);
            outcomes.push((method, state, operation.await.map(|_| ())));
        }
    }
    let report: Value = serde_json::from_slice(
        &client
            .get(format!("https://localhost:{port}/report"))
            .send()
            .await
            .unwrap()
            .bytes()
            .await
            .unwrap(),
    )
    .unwrap();
    assert!(peer.0.wait().unwrap().success());
    assert_eq!(
        report.as_array().unwrap().len(),
        2,
        "only the active positive controls may connect; retired/rejected queued credentials must not reach the peer"
    );
    for (method, state, result) in outcomes {
        assert_eq!(
            result,
            match state {
                "retired" => Err("jmap_cancelled"),
                "rejected" => Err("jmap_unauthorized"),
                _ => Ok(()),
            },
            "{method} {state}"
        );
    }
}

#[tokio::test]
async fn native_truncated_body_repair_stops_rejected_credentials() {
    let (mut peer, session, client, port) =
        tokio::task::spawn_blocking(mailbox_peer).await.unwrap();
    let context = session.context("jmap:user@example.test").unwrap();
    {
        let mut held = context.snapshot.lock().await;
        let snapshot = held.as_mut().unwrap();
        snapshot.document["apiUrl"] = json!(format!("https://localhost:{port}/repair-auth"));
        snapshot.document["downloadUrl"] =
            json!(format!("https://localhost:{port}/refused-blob/{{blobId}}"));
    }
    let result = session
        .native(
            "jmap.read",
            &json!({"accountId":"jmap:user@example.test", "id":"e1", "full":true}),
        )
        .await;
    let retry = session
        .native(
            "jmap.attachment",
            &json!({"accountId":"jmap:user@example.test", "attachmentId":"later"}),
        )
        .await;
    let report: Value = serde_json::from_slice(
        &client
            .get(format!("https://localhost:{port}/report"))
            .send()
            .await
            .unwrap()
            .bytes()
            .await
            .unwrap(),
    )
    .unwrap();
    assert!(peer.0.wait().unwrap().success());
    assert_eq!(
        report
            .as_array()
            .unwrap()
            .iter()
            .filter(|request| string(&request["path"]).starts_with("/refused-blob/"))
            .count(),
        1,
        "rejected body repair credentials must not be sent for another part or later request"
    );
    assert_eq!(result, Err("jmap_unauthorized"));
    assert_eq!(retry, Err("jmap_unauthorized"));
}
