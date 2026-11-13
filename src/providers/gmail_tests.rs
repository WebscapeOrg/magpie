use super::*;

#[tokio::test]
async fn resource_methods_validate_before_credentials() {
    let session = &Session::default();
    for method in [
        "gmail.labels",
        "gmail.labelCounts",
        "gmail.profile",
        "gmail.sendAs",
    ] {
        assert_eq!(
            session
                .call(
                    method,
                    &json!({"accountId":"a@example.org", "unexpected":true})
                )
                .await,
            Err("invalid_params")
        );
    }
    assert_eq!(
        session
            .call("gmail.labelCounts", &json!({"accountId":"a@example.org"}))
            .await,
        Err("invalid_params")
    );
}
use std::cell::Cell;

fn grant(value: &str) -> Result<Value, &'static str> {
    Ok(json!({"access_token":value,"expires_in":3600}))
}

#[tokio::test]
async fn unauthorized_reauthenticates_once_and_caches_replacement() {
    let session = &Session::default();
    let refreshes = &Cell::new(0);
    let gets = &Cell::new(0);
    let result = session
        .get_with(
            "one",
            || async {
                refreshes.set(refreshes.get() + 1);
                grant(if refreshes.get() == 1 { "old" } else { "new" })
            },
            |token| async move {
                gets.set(gets.get() + 1);
                if token == "old" {
                    Err("gmail_unauthorized")
                } else {
                    Ok(json!({"id":"mail"}))
                }
            },
        )
        .await;
    assert_eq!(result, Ok(json!({"id":"mail"})));
    assert_eq!(refreshes.get(), 2);
    assert_eq!(gets.get(), 2);
    assert_eq!(
        session
            .get_with(
                "one",
                || async { panic!("cached token lost") },
                |token| async move { Ok(json!(token)) }
            )
            .await,
        Ok(json!("new"))
    );
}

#[tokio::test]
async fn repeated_unauthorized_stops_after_one_retry() {
    let session = &Session::default();
    let refreshes = &Cell::new(0);
    let gets = &Cell::new(0);
    assert_eq!(
        session
            .get_with(
                "one",
                || async {
                    refreshes.set(refreshes.get() + 1);
                    grant("token")
                },
                |_| async {
                    gets.set(gets.get() + 1);
                    Err("gmail_unauthorized")
                }
            )
            .await,
        Err("gmail_unauthorized")
    );
    assert_eq!(refreshes.get(), 2);
    assert_eq!(gets.get(), 2);
}

#[tokio::test]
async fn non_authentication_errors_do_not_retry() {
    let session = &Session::default();
    let refreshes = &Cell::new(0);
    let gets = &Cell::new(0);
    assert_eq!(
        session
            .get_with(
                "one",
                || async {
                    refreshes.set(refreshes.get() + 1);
                    grant("token")
                },
                |_| async {
                    gets.set(gets.get() + 1);
                    Err("gmail_http_failed")
                }
            )
            .await,
        Err("gmail_http_failed")
    );
    assert_eq!(refreshes.get(), 1);
    assert_eq!(gets.get(), 1);
}

#[tokio::test]
async fn invalidation_stops_old_request_retry_but_allows_new_requests() {
    let session = &Session::default();
    let refreshes = &Cell::new(0);
    assert_eq!(
        session
            .get_with(
                "one",
                || async {
                    refreshes.set(refreshes.get() + 1);
                    grant("old")
                },
                |_| async {
                    session
                        .call("gmail.invalidate", &json!({"accountId":"one"}))
                        .await
                        .unwrap();
                    Err("gmail_unauthorized")
                }
            )
            .await,
        Err("gmail_session_invalidated")
    );
    assert_eq!(refreshes.get(), 1);
    assert_eq!(
        session
            .get_with(
                "one",
                || async { grant("new") },
                |token| async move { Ok(json!(token)) }
            )
            .await,
        Ok(json!("new"))
    );
}

#[tokio::test]
async fn old_unauthorized_cannot_evict_concurrently_refreshed_token() {
    let session = &Session::default();
    let first = &Cell::new(true);
    let result = session
        .get_with(
            "one",
            || async { grant("old") },
            |token| async move {
                if first.replace(false) {
                    assert_eq!(
                        session
                            .get_with(
                                "one",
                                || async { grant("new") },
                                |inner| async move {
                                    if inner == "old" {
                                        Err("gmail_unauthorized")
                                    } else {
                                        Ok(json!(inner))
                                    }
                                }
                            )
                            .await,
                        Ok(json!("new"))
                    );
                    Err("gmail_unauthorized")
                } else {
                    Ok(json!(token))
                }
            },
        )
        .await;
    assert_eq!(result, Ok(json!("new")));
}

#[tokio::test]
async fn invalidation_during_refresh_cannot_publish_token_or_send_get() {
    let session = &Session::default();
    let started = tokio::sync::Notify::new();
    let done = tokio::sync::Notify::new();
    let request = session.get_with(
        "one",
        || async {
            started.notify_one();
            tokio::time::timeout(Duration::from_secs(2), done.notified())
                .await
                .expect("invalidate must not wait for remote refresh");
            grant("old")
        },
        |_| async { panic!("invalidated refresh must not send HTTP GET") },
    );
    let invalidate = async {
        started.notified().await;
        session
            .call("gmail.invalidate", &json!({"accountId":"one"}))
            .await
            .unwrap();
        done.notify_one();
    };
    let (result, ()) = tokio::join!(request, invalidate);
    assert_eq!(result, Err("gmail_session_invalidated"));
    assert_eq!(
        session
            .get_with(
                "one",
                || async { grant("new") },
                |token| async move { Ok(json!(token)) }
            )
            .await,
        Ok(json!("new"))
    );
}

#[tokio::test]
async fn slow_account_refresh_does_not_stall_another_account() {
    // Invariant: A single-thread runtime proves the wait yields, rather than being hidden by workers.
    let session = &Session::default();
    let started = tokio::sync::Notify::new();
    let release = tokio::sync::Notify::new();
    let slow = session.get_with(
        "slow",
        || async {
            started.notify_one();
            release.notified().await;
            grant("slow-token")
        },
        |token| async move { Ok(json!(token)) },
    );
    let fast = async {
        started.notified().await;
        let result = tokio::time::timeout(
            Duration::from_secs(2),
            session.get_with(
                "fast",
                || async { grant("fast-token") },
                |token| async move { Ok(json!(token)) },
            ),
        )
        .await
        .expect("fast account must finish before slow refresh is released");
        release.notify_one();
        result
    };
    let (slow, fast) = tokio::join!(slow, fast);
    assert_eq!(slow, Ok(json!("slow-token")));
    assert_eq!(fast, Ok(json!("fast-token")));
}

#[tokio::test]
async fn concurrent_requests_coalesce_refresh_for_one_account() {
    let session = &Session::default();
    let refreshes = &Cell::new(0);
    let refresh = || async {
        refreshes.set(refreshes.get() + 1);
        tokio::task::yield_now().await;
        grant("shared")
    };
    let (first, second) = tokio::join!(
        session.get_with("one", refresh, |token| async move { Ok(json!(token)) }),
        session.get_with("one", refresh, |token| async move { Ok(json!(token)) })
    );
    assert_eq!(first, Ok(json!("shared")));
    assert_eq!(second, first);
    assert_eq!(refreshes.get(), 1);
}

#[tokio::test]
async fn invalidate_is_idempotent_without_config_or_keyring() {
    let session = &Session::default();
    for _ in 0..2 {
        assert_eq!(
            session
                .call(
                    "gmail.invalidate",
                    &json!({"accountId":"synthetic@example.org"})
                )
                .await,
            Ok(json!({"invalidated":true}))
        );
    }
    assert_eq!(
        session
            .call(
                "gmail.invalidate",
                &json!({"accountId":"synthetic@example.org", "extra":true})
            )
            .await,
        Err("invalid_params")
    );
}

#[tokio::test]
async fn credentials_failure_prevents_refresh_and_mail_network_requests() {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let origin = format!("http://{}", listener.local_addr().unwrap());
    let transport = reqwest::Client::builder().no_proxy().build().unwrap();
    let session = Session::default();
    let client = gmail_credentials::Client {
        client_id: "123-synthetic.apps.googleusercontent.com".into(),
        client_secret: "synthetic-client-secret".into(),
    };
    gmail_http::with_test_transport(transport, origin, async {
        for (failure, expected) in [
            (crate::credentials::Error::Missing, "gmail_token_missing"),
            (
                crate::credentials::Error::Unavailable,
                "gmail_keyring_failed",
            ),
        ] {
            let result = session
                .get_with(
                    "synthetic@example.org",
                    || async {
                        let refresh = gmail_credentials::lookup_with(
                            &client,
                            "synthetic@example.org",
                            |_| Err(failure),
                        )?;
                        gmail_http::refresh(&client.client_id, &client.client_secret, &refresh)
                            .await
                    },
                    |token| async move { gmail_http::get(&["profile"], &[], &token).await },
                )
                .await;
            assert_eq!(result, Err(expected));
            assert!(
                tokio::time::timeout(Duration::from_millis(30), listener.accept())
                    .await
                    .is_err(),
                "failed credential lookup opened a network connection"
            );
        }
    })
    .await;
}

#[tokio::test]
async fn unsupported_client_provider_never_reads_keyring_or_contacts_google() {
    if crate::mail::tests::isolated() {
        return;
    }
    struct RefusedStore(Arc<std::sync::atomic::AtomicUsize>);
    impl crate::credentials::CredentialStore for RefusedStore {
        fn get(
            &self,
            _: &crate::credentials::CredentialKey,
        ) -> Result<crate::credentials::Secret, crate::credentials::Error> {
            self.0.fetch_add(1, Ordering::SeqCst);
            Err(crate::credentials::Error::Unavailable)
        }
        fn put(
            &self,
            _: &crate::credentials::CredentialKey,
            _: &[u8],
        ) -> Result<(), crate::credentials::Error> {
            self.0.fetch_add(1, Ordering::SeqCst);
            Err(crate::credentials::Error::Unavailable)
        }
        fn delete(
            &self,
            _: &crate::credentials::CredentialKey,
        ) -> Result<(), crate::credentials::Error> {
            self.0.fetch_add(1, Ordering::SeqCst);
            Err(crate::credentials::Error::Unavailable)
        }
    }
    let account = "synthetic@example.org";
    let fixture = crate::mail::tests::account_fixture(json!({"version":1,"accounts":[{
        "provider":"gmail","email":account
    }]}));
    let directory =
        crate::platform::private_fs::directories_readonly(&fixture.config, &["omamail"])
            .unwrap()
            .unwrap();
    let credential_calls = Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let _credentials =
        crate::credentials::tests::isolated_store(RefusedStore(credential_calls.clone()));
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let origin = format!("http://{}", listener.local_addr().unwrap());
    let transport = reqwest::Client::builder().no_proxy().build().unwrap();
    gmail_http::with_test_transport(transport, origin, async {
        for provider in ["imap", "outlook", "hey", "jmap", "caldav", "unknown"] {
            let own = json!({"provider":"gmail","id":account,
                "clientId":"123-own.apps.googleusercontent.com","clientSecret":"synthetic"});
            let unsupported = json!({"provider":provider,"id":"other@example.org",
                "clientId":"456-shared.apps.googleusercontent.com","clientSecret":"synthetic"});
            for clients in [
                json!({"accounts":[unsupported]}),
                json!({"accounts":[own,unsupported]}),
                json!({"provider":provider,"installed":{"client_id":"789-client.apps.googleusercontent.com"}}),
                json!({"installed":{"provider":provider,"client_id":"789-client.apps.googleusercontent.com"}}),
                json!({"web":{"provider":provider,"client_id":"789-client.apps.googleusercontent.com"}}),
                json!({"accounts":[own,{"id":"other@example.org","installed":{"provider":provider,"client_id":"789-client.apps.googleusercontent.com"}}]}),
                json!({"accounts":[own,{"id":"other@example.org","web":{"provider":provider,"client_id":"789-client.apps.googleusercontent.com"}}]}),
            ] {
                crate::platform::private_fs::atomic_replace(&directory, "credentials.json", clients.to_string().as_bytes()).unwrap();
                let before = crate::mail::tests::fixture_tree(&fixture.root);
                let session = Session::default();
                let results = [
                    session.call("gmail.profile", &json!({"accountId":account})).await,
                    session.access_token(account).await.map(Value::String),
                    session.call("gmail.send", &json!({"accountId":account,"raw":"eA"})).await,
                    session.call_settled("gmail.trash", &json!({"accountId":account,"id":"message"})).await,
                    session.replica_call(account, "labels", &json!({})).await,
                    session.thread_resources(account, "thread").await.map(Value::Array),
                ];
                assert_eq!(credential_calls.load(Ordering::SeqCst), 0, "unsupported client accessed credential store");
                for result in results {
                    assert_eq!(result, Err("accounts_provider_unsupported"));
                }
                assert_eq!(crate::mail::tests::fixture_tree(&fixture.root), before);
                session.shutdown();
            }
        }
        assert!(tokio::time::timeout(Duration::from_millis(30), listener.accept()).await.is_err(),
            "unsupported client opened a token or Gmail connection");
    }).await;
}
