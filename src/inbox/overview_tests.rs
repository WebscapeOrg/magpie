use super::{Inbox, overview_batch_with, overview_message};
use crate::{
    credentials::{self, CredentialKey, CredentialStore, Error, Secret},
    local_mail::LocalMail,
    mail::tests::{AccountFixture, account_fixture, fixture_tree, isolated},
    providers::{gmail, gmail_http},
};
use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use serde_json::{Value, json};
use std::{
    collections::BTreeMap,
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::TcpListener,
    sync::Notify,
};

const ACCOUNT: &str = "overviews@example.org";
const OTHER: &str = "other@example.org";
const CLIENT: &str = "123-overviews.apps.googleusercontent.com";

struct Credentials(Arc<Mutex<Vec<String>>>);

/// How often this test process looked for the picker's OpenAI key.
static OPENAI_LOOKUPS: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);

impl CredentialStore for Credentials {
    fn get(&self, key: &CredentialKey) -> Result<Secret, Error> {
        // No OpenAI key, so the picker chooses Sonnet without asking anyone.
        if key.provider == "openai" {
            OPENAI_LOOKUPS.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            return Err(Error::Missing);
        }
        self.0.lock().unwrap().push(key.account_id.clone());
        assert_eq!(key.provider, "gmail");
        assert!([ACCOUNT, OTHER].contains(&key.account_id.as_str()));
        Secret::new(b"synthetic-refresh".to_vec())
    }

    fn put(&self, _: &CredentialKey, _: &[u8]) -> Result<(), Error> {
        panic!("overview wrote a credential")
    }

    fn delete(&self, _: &CredentialKey) -> Result<(), Error> {
        panic!("overview deleted a credential")
    }
}

struct World {
    messages: BTreeMap<String, Value>,
    requests: Vec<String>,
    delay: Duration,
}

struct Provider {
    origin: String,
    world: Arc<Mutex<World>>,
    requested: Arc<Notify>,
    task: tokio::task::JoinHandle<()>,
}

impl Provider {
    async fn new() -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let origin = format!("http://{}", listener.local_addr().unwrap());
        let world = Arc::new(Mutex::new(World {
            messages: BTreeMap::new(),
            requests: Vec::new(),
            delay: Duration::ZERO,
        }));
        let requested = Arc::new(Notify::new());
        let state = world.clone();
        let signal = requested.clone();
        let task = tokio::spawn(async move {
            let mut handlers = tokio::task::JoinSet::new();
            loop {
                let (mut socket, _) = listener.accept().await.unwrap();
                let state = state.clone();
                let signal = signal.clone();
                handlers.spawn(async move {
                    let mut bytes = Vec::new();
                    while !bytes.ends_with(b"\r\n\r\n") {
                        let Ok(byte) = socket.read_u8().await else { return };
                        bytes.push(byte);
                        assert!(bytes.len() < 65_536);
                    }
                    let headers = String::from_utf8(bytes).unwrap();
                    let line = headers.lines().next().unwrap().to_owned();
                    let length = headers.lines().find_map(|line| {
                        let (name, value) = line.split_once(':')?;
                        name.eq_ignore_ascii_case("content-length").then(|| value.trim().parse::<usize>().unwrap())
                    }).unwrap_or(0);
                    assert!(length < 65_536);
                    let mut body = vec![0; length];
                    socket.read_exact(&mut body).await.unwrap();
                    let url = reqwest::Url::parse(&format!("http://fixture{}", line.split_whitespace().nth(1).unwrap())).unwrap();
                    let (status, answer, delay) = {
                        let mut world = state.lock().unwrap();
                        world.requests.push(line);
                        let (status, answer) = answer(&world, &url);
                        (status, answer.to_string(), world.delay)
                    };
                    if url.path().contains("/messages/") {
                        signal.notify_one();
                        if !delay.is_zero() {
                            tokio::time::sleep(delay).await;
                        }
                    }
                    let response = format!("HTTP/1.1 {status} Fixture\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{answer}", answer.len());
                    let _ = socket.write_all(response.as_bytes()).await;
                });
            }
        });
        Self {
            origin,
            world,
            requested,
            task,
        }
    }

    fn requests(&self) -> Vec<String> {
        self.world.lock().unwrap().requests.clone()
    }

    fn insert(&self, resource: Value) {
        self.world
            .lock()
            .unwrap()
            .messages
            .insert(resource["id"].as_str().unwrap().to_owned(), resource);
    }
}

impl Drop for Provider {
    fn drop(&mut self) {
        self.task.abort();
    }
}

fn answer(world: &World, url: &reqwest::Url) -> (u16, Value) {
    if url.path() == "/token" {
        return (
            200,
            json!({"access_token":"synthetic-access","expires_in":3600}),
        );
    }
    let suffix = url
        .path()
        .strip_prefix("/gmail/v1/users/me/messages/")
        .expect("unexpected provider operation");
    if suffix.ends_with("/attachments/text-body") {
        return (
            200,
            json!({"data":URL_SAFE_NO_PAD.encode("Hydrated request: confirm the meeting."),"size":38}),
        );
    }
    assert!(
        !suffix.contains("/attachments/"),
        "overview downloaded a binary or attached text file"
    );
    assert!(
        url.query_pairs()
            .any(|(key, value)| key == "format" && value == "full")
    );
    world
        .messages
        .get(suffix)
        .map(|message| (200, message.clone()))
        .unwrap_or((404, json!({})))
}

fn fixture() -> AccountFixture {
    let fixture = account_fixture(
        json!({"version":1,"accounts":[{"provider":"gmail","email":ACCOUNT},{"provider":"gmail","email":OTHER}]}),
    );
    let directory = crate::platform::private_fs::directories(&fixture.config, &["omamail"], true)
        .unwrap()
        .unwrap();
    crate::platform::private_fs::atomic_replace(
        &directory,
        "credentials.json",
        json!({"installed":{"client_id":CLIENT,"client_secret":"synthetic-secret"}})
            .to_string()
            .as_bytes(),
    )
    .unwrap();
    fixture
}

fn message(id: &str, body: &str) -> Value {
    json!({"id":id,"threadId":id,"internalDate":"1700000000000","labelIds":["INBOX","UNREAD"],
        "payload":{"mimeType":"text/plain","headers":[{"name":"From","value":"Sender <sender@example.org>"},{"name":"Subject","value":"Synthetic request"}],"body":{"data":URL_SAFE_NO_PAD.encode(body),"size":body.len()}}})
}

async fn seed(local: &LocalMail, gmail: &gmail::Session, account: &str, resource: &Value) {
    let id = resource["id"].as_str().unwrap();
    crate::cache::resource::put(account, id, resource)
        .await
        .unwrap();
    local.read(account, id, gmail).await.unwrap();
}

fn validated_response(messages: Value) -> std::future::Ready<Result<Value, &'static str>> {
    let rows = messages.as_array().unwrap().iter().map(|message| {
        json!({"id":message["id"],"text":"Confirm the synthetic request.","evidence":message["subject"]})
    }).collect::<Vec<_>>();
    std::future::ready(crate::agent::overview::validate(
        &json!({"overviews":rows}),
        &messages,
        &json!({}),
    ))
}

#[tokio::test]
async fn attachment_context_uses_only_the_owning_account_and_supplied_attachment_id() {
    if isolated() {
        return;
    }
    let _fixture = fixture();
    let reads = Arc::new(Mutex::new(Vec::new()));
    let _credentials = credentials::tests::isolated_store(Credentials(reads.clone()));
    let provider = Provider::new().await;
    let client = reqwest::Client::builder().no_proxy().build().unwrap();
    gmail_http::with_test_transport(client,provider.origin.clone(),async {
        let gmail = gmail::Session::default();
        let mut raw = message("safe-id","See attachment.");
        raw["payload"]["parts"] = json!([{ "mimeType":"text/plain","filename":"../../private.txt","body":{"attachmentId":"text-body","size":38}}]);
        let mut context = json!({});
        super::context::enrich(ACCOUNT,"safe-id",&raw,&mut context,&gmail,false).await.unwrap();
        assert_eq!(context["files"][0]["content"][0]["text"],"Hydrated request: confirm the meeting.");
        let requests = provider.requests();
        assert_eq!(requests.len(),2);
        assert!(requests.iter().any(|request|request.contains("/messages/safe-id/attachments/text-body")));
        assert!(requests.iter().all(|request| !request.contains("private.txt") && !request.contains(OTHER)));
        assert_eq!(*reads.lock().unwrap(),vec![ACCOUNT]);
    }).await;
}

#[tokio::test]
async fn four_cached_overviews_use_one_ordered_ai_batch_without_credentials_or_http() {
    if isolated() {
        return;
    }
    let _fixture = fixture();
    let reads = Arc::new(Mutex::new(Vec::new()));
    let _credentials = credentials::tests::isolated_store(Credentials(reads.clone()));
    let provider = Provider::new().await;
    let client = reqwest::Client::builder().no_proxy().build().unwrap();
    gmail_http::with_test_transport(client, provider.origin.clone(), async {
        let gmail = gmail::Session::default();
        let local = LocalMail::default();
        let ids = ["d", "b", "a", "c"].map(str::to_owned);
        for id in &ids {
            seed(
                &local,
                &gmail,
                ACCOUNT,
                &message(id, "Confirm the synthetic request."),
            )
            .await;
        }
        let mut calls = 0;
        let result = overview_batch_with(ACCOUNT, &ids, &gmail, &local, |messages| {
            calls += 1;
            assert_eq!(
                messages
                    .as_array()
                    .unwrap()
                    .iter()
                    .map(|m| m["id"].as_str().unwrap())
                    .collect::<Vec<_>>(),
                ids
            );
            assert!(
                messages
                    .as_array()
                    .unwrap()
                    .iter()
                    .all(|m| m["body"] == "Confirm the synthetic request.")
            );
            validated_response(messages)
        })
        .await
        .unwrap();
        assert_eq!(result.as_array().unwrap().len(), 4);
        assert_eq!(calls, 1);
        let other_owner = LocalMail::default();
        let shared = overview_batch_with(ACCOUNT, &ids, &gmail, &other_owner, validated_response)
            .await
            .unwrap();
        assert_eq!(
            shared, result,
            "an IPC reader must reuse the owner's saved bodies"
        );
        assert!(provider.requests().is_empty());
        assert!(reads.lock().unwrap().is_empty());
    })
    .await;
}

#[tokio::test]
async fn mixed_overviews_fetch_only_missing_message_and_body_text() {
    if isolated() {
        return;
    }
    let _fixture = fixture();
    let reads = Arc::new(Mutex::new(Vec::new()));
    let _credentials = credentials::tests::isolated_store(Credentials(reads.clone()));
    let provider = Provider::new().await;
    provider.insert(message("missing", "A new request."));
    let client = reqwest::Client::builder().no_proxy().build().unwrap();
    gmail_http::with_test_transport(client, provider.origin.clone(), async {
        let gmail = gmail::Session::default();
        let local = LocalMail::default();
        for id in ["cached-a", "cached-b"] { seed(&local, &gmail, ACCOUNT, &message(id, "Already downloaded.")).await; }
        let mut partial = message("partial", "");
        partial["payload"]["mimeType"] = json!("multipart/mixed");
        partial["payload"]["body"] = json!({});
        partial["payload"]["parts"] = json!([
            {"mimeType":"text/plain","body":{"attachmentId":"text-body","size":38}},
            {"mimeType":"application/pdf","filename":"invoice.pdf","body":{"attachmentId":"binary-file","size":4096}},
            {"mimeType":"text/plain","filename":"notes.txt","headers":[{"name":"Content-Disposition","value":"attachment"}],"body":{"attachmentId":"attached-file","size":200}}
        ]);
        crate::cache::resource::put(ACCOUNT, "partial", &partial).await.unwrap();
        let ids = ["cached-a", "missing", "partial", "cached-b"].map(str::to_owned);
        overview_batch_with(ACCOUNT, &ids, &gmail, &local, |messages| {
            assert_eq!(messages[2]["body"], "Hydrated request: confirm the meeting.");
            assert_eq!(messages[2]["attachments"].as_array().unwrap().len(), 2);
            validated_response(messages)
        }).await.unwrap();
        let requests = provider.requests();
        assert_eq!(requests.len(), 3, "one token, one missing resource, one body text request: {requests:?}");
        assert_eq!(requests.iter().filter(|r| r.contains("/messages/missing?")).count(), 1);
        assert_eq!(requests.iter().filter(|r| r.contains("/attachments/text-body")).count(), 1);
        assert!(!requests.iter().any(|r| r.contains("binary-file") || r.contains("attached-file")));
        assert_eq!(*reads.lock().unwrap(), vec![ACCOUNT]);
        overview_batch_with(ACCOUNT, &ids, &gmail, &local, validated_response).await.unwrap();
        assert_eq!(provider.requests(), requests, "the next preparation uses the hydrated saved bodies");
    }).await;
}

#[tokio::test]
async fn cold_reader_and_overview_share_one_message_fetch() {
    if isolated() {
        return;
    }
    let _fixture = fixture();
    let _credentials =
        credentials::tests::isolated_store(Credentials(Arc::new(Mutex::new(Vec::new()))));
    let provider = Provider::new().await;
    provider.insert(message("shared", "Reader and overview share this request."));
    provider.world.lock().unwrap().delay = Duration::from_millis(50);
    let client = reqwest::Client::builder().no_proxy().build().unwrap();
    gmail_http::with_test_transport(client, provider.origin.clone(), async {
        let gmail = gmail::Session::default();
        let local = LocalMail::default();
        let ids = ["shared".to_owned()];
        let (overview, reader) = tokio::time::timeout(Duration::from_secs(5), async {
            tokio::join!(
                overview_batch_with(ACCOUNT, &ids, &gmail, &local, validated_response),
                async {
                    provider.requested.notified().await;
                    local.read(ACCOUNT, "shared", &gmail).await
                }
            )
        })
        .await
        .unwrap();
        assert_eq!(overview.unwrap()[0]["id"], "shared");
        assert_eq!(reader.unwrap()["id"], "shared");
        let requests = provider.requests();
        assert_eq!(
            requests
                .iter()
                .filter(|r| r.contains("/messages/shared?"))
                .count(),
            1
        );
        assert_eq!(requests.len(), 2);
    })
    .await;
}

#[tokio::test]
async fn saved_overviews_remain_account_scoped_and_removed_accounts_have_no_effects() {
    if isolated() {
        return;
    }
    let fixture = fixture();
    let reads = Arc::new(Mutex::new(Vec::new()));
    let _credentials = credentials::tests::isolated_store(Credentials(reads.clone()));
    let provider = Provider::new().await;
    let client = reqwest::Client::builder().no_proxy().build().unwrap();
    gmail_http::with_test_transport(client, provider.origin.clone(), async {
        let gmail = gmail::Session::default();
        let local = LocalMail::default();
        let ids = ["same-id".to_owned()];
        for (account, body) in [
            (ACCOUNT, "First account private text."),
            (OTHER, "Other account private text."),
        ] {
            seed(&local, &gmail, account, &message("same-id", body)).await;
            overview_batch_with(account, &ids, &gmail, &local, |messages| {
                assert_eq!(messages[0]["body"], body);
                validated_response(messages)
            })
            .await
            .unwrap();
        }
        let directory =
            crate::platform::private_fs::directories(&fixture.config, &["omamail"], false)
                .unwrap()
                .unwrap();
        crate::platform::private_fs::atomic_replace(
            &directory,
            "accounts.json",
            json!({"version":1,"accounts":[{"provider":"gmail","email":OTHER}]})
                .to_string()
                .as_bytes(),
        )
        .unwrap();
        let before = fixture_tree(&fixture.root);
        let result = overview_batch_with(ACCOUNT, &ids, &gmail, &local, |_| async {
            panic!("removed account reached AI")
        })
        .await;
        assert_eq!(result, Err("local_account_unknown"));
        assert_eq!(
            fixture_tree(&fixture.root),
            before,
            "removed account must not update any cache, registry, or persisted job"
        );
        assert!(provider.requests().is_empty());
        assert!(reads.lock().unwrap().is_empty());
    })
    .await;
}

#[tokio::test]
async fn invalid_batch_is_rejected_before_storage_credentials_http_or_ai() {
    if isolated() {
        return;
    }
    let fixture = fixture();
    let reads = Arc::new(Mutex::new(Vec::new()));
    let _credentials = credentials::tests::isolated_store(Credentials(reads.clone()));
    let inbox = Inbox::default();
    let gmail = Arc::new(gmail::Session::default());
    let local = Arc::new(LocalMail::default());
    let provider = Provider::new().await;
    let client = reqwest::Client::builder().no_proxy().build().unwrap();
    gmail_http::with_test_transport(client, provider.origin.clone(), async {
        let before = fixture_tree(&fixture.root);
        for ids in [
            json!([]),
            json!(["a", "b", "c", "d", "e"]),
            json!(["a", "a"]),
            json!(["bad\n"]),
        ] {
            assert_eq!(
                inbox
                    .call(
                        "inbox.overviews",
                        &json!({"accountId":ACCOUNT,"ids":ids}),
                        gmail.clone(),
                        local.clone()
                    )
                    .await,
                Err("invalid_params")
            );
        }
        assert_eq!(fixture_tree(&fixture.root), before);
        assert!(reads.lock().unwrap().is_empty());
        assert!(provider.requests().is_empty());
    })
    .await;
}

#[tokio::test]
async fn overview_admission_allows_only_one_batch_and_failure_never_starts_ai() {
    if isolated() {
        return;
    }
    let fixture = fixture();
    let _credentials =
        credentials::tests::isolated_store(Credentials(Arc::new(Mutex::new(Vec::new()))));
    let inbox = Inbox::default();
    let gmail = Arc::new(gmail::Session::default());
    let local = Arc::new(LocalMail::default());
    let _permit = inbox.overview_slots.clone().try_acquire_owned().unwrap();
    let before = fixture_tree(&fixture.root);
    assert_eq!(
        inbox
            .call(
                "inbox.overviews",
                &json!({"accountId":ACCOUNT,"ids":["missing"]}),
                gmail.clone(),
                local.clone()
            )
            .await
            .unwrap(),
        json!({"accepted":false})
    );
    assert_eq!(fixture_tree(&fixture.root), before);
    let provider = Provider::new().await;
    let client = reqwest::Client::builder().no_proxy().build().unwrap();
    gmail_http::with_test_transport(client, provider.origin.clone(), async {
        let result = overview_batch_with(ACCOUNT, &["missing".into()], &gmail, &local, |_| async {
            panic!("incomplete batch reached AI")
        })
        .await;
        assert_eq!(result, Ok(json!([{"id":"missing","error":"gmail_not_found","stage":"prepare"}])));
        assert_eq!(provider.requests().len(), 2);
    })
    .await;
}

#[tokio::test]
async fn a_message_that_cannot_be_prepared_fails_alone_and_its_neighbours_reach_ai() {
    if isolated() {
        return;
    }
    let _fixture = fixture();
    let _credentials =
        credentials::tests::isolated_store(Credentials(Arc::new(Mutex::new(Vec::new()))));
    let provider = Provider::new().await;
    let client = reqwest::Client::builder().no_proxy().build().unwrap();
    gmail_http::with_test_transport(client, provider.origin.clone(), async {
        let gmail = gmail::Session::default();
        let local = LocalMail::default();
        for id in ["a", "c"] {
            seed(&local, &gmail, ACCOUNT, &message(id, "Confirm the synthetic request.")).await;
        }
        let ids = ["a", "missing", "c"].map(str::to_owned);
        let mut asked = Vec::new();
        let result = overview_batch_with(ACCOUNT, &ids, &gmail, &local, |messages| {
            asked = messages.as_array().unwrap().iter().map(|m| m["id"].as_str().unwrap().to_owned()).collect();
            validated_response(messages)
        })
        .await
        .unwrap();
        assert_eq!(asked, ["a", "c"], "only the messages that were prepared reach AI");
        let rows = result.as_array().unwrap();
        assert_eq!(rows.len(), 3);
        let missing = rows.iter().find(|row| row["id"] == "missing").unwrap();
        assert_eq!(missing["error"], "gmail_not_found");
        assert_eq!(missing["stage"], "prepare");
        assert!(rows.iter().filter(|row| row["id"] != "missing").all(|row| row["text"].is_string()));
        let failed = overview_batch_with(ACCOUNT, &ids, &gmail, &local, |_| std::future::ready(Err("overview_ai_unavailable")))
            .await
            .unwrap();
        let errors: BTreeMap<String, String> = failed.as_array().unwrap().iter()
            .map(|row| (row["id"].as_str().unwrap().to_owned(), row["error"].as_str().unwrap().to_owned()))
            .collect();
        assert_eq!(errors["missing"], "gmail_not_found", "a writer failure does not replace a message's own failure");
        assert_eq!(errors["a"], "overview_ai_unavailable");
        assert_eq!(errors["c"], "overview_ai_unavailable");
    })
    .await;
}

#[test]
fn overview_preparation_keeps_opening_and_end_without_truncating_unicode() {
    let body = format!(
        "{}{}{}",
        "開".repeat(36000),
        "中".repeat(12000),
        "終".repeat(12000)
    );
    let prepared = overview_message("long", &message("long", &body)).unwrap();
    let text = prepared["body"].as_str().unwrap();
    assert!(text.chars().count() <= 48_000);
    assert!(text.starts_with(&"開".repeat(35_000)));
    assert!(text.ends_with(&"終".repeat(11_000)));
    assert!(text.contains("[Middle omitted]"));
}

#[tokio::test]
#[ignore = "records controlled cached overview preparation timings without external AI"]
async fn cached_overview_preparation_benchmark() {
    measure_cached_overview_preparation(false).await;
}

#[tokio::test]
#[ignore = "records sustained preparation pacing with a shared Gmail quota budget"]
async fn sustained_cached_overview_preparation_benchmark() {
    measure_cached_overview_preparation(true).await;
}

async fn measure_cached_overview_preparation(reuse_budget: bool) {
    if isolated() {
        return;
    }
    let _fixture = fixture();
    let _credentials =
        credentials::tests::isolated_store(Credentials(Arc::new(Mutex::new(Vec::new()))));
    let provider = Provider::new().await;
    let client = reqwest::Client::builder().no_proxy().build().unwrap();
    gmail_http::with_test_transport(client, provider.origin.clone(), async {
        let mut gmail = gmail::Session::default();
        let local = LocalMail::default();
        let ids = ["a", "b", "c", "d"].map(str::to_owned);
        for id in &ids {
            let resource = message(id, &"Synthetic cached mail body. ".repeat(120));
            seed(&local, &gmail, ACCOUNT, &resource).await;
            provider.insert(resource);
        }
        let mut baseline = Vec::new();
        let mut candidate = Vec::new();
        let mut baseline_requests = 0;
        let mut candidate_requests = 0;
        for sample in 0..34 {
            if !reuse_budget {
                gmail = gmail::Session::default();
                gmail.access_token(ACCOUNT).await.unwrap();
            }
            let requests = provider.requests().len();
            let started = Instant::now();
            let mut original = Vec::new();
            for id in &ids {
                let raw = gmail.call("gmail.read", &json!({"accountId":ACCOUNT,"id":id,"full":true})).await.unwrap();
                original.push(overview_message(id, &raw).unwrap());
            }
            let elapsed = started.elapsed().as_secs_f64() * 1000.0;
            if sample >= 3 {
                baseline.push(elapsed);
                baseline_requests += provider.requests().len() - requests;
            }
            let requests = provider.requests().len();
            let started = Instant::now();
            overview_batch_with(ACCOUNT, &ids, &gmail, &local, |messages| {
                assert_eq!(messages, json!(original));
                std::future::ready(Ok(json!([])))
            }).await.unwrap();
            let elapsed = started.elapsed().as_secs_f64() * 1000.0;
            if sample >= 3 {
                candidate.push(elapsed);
                candidate_requests += provider.requests().len() - requests;
            }
        }
        let stats = |samples: &mut Vec<f64>| {
            samples.sort_by(f64::total_cmp);
            json!({"p50Ms":samples[samples.len()/2],"p95Ms":samples[(samples.len()*95).div_ceil(100)-1],"samplesMs":samples})
        };
        println!("OVERVIEW_PREPARATION_BENCHMARK {}", json!({
            "fixture":"four saved synthetic Gmail messages, 3360 body bytes each",
            "transport":"controlled loopback HTTP; zero artificial latency",
            "samples":31,"warmups":3,"externalAiIncluded":false,
            "quotaScenario":if reuse_budget {"sustained shared budget; original reads eventually wait for Magpie pacing"} else {"fresh budget and prewarmed token per sample; token refresh excluded"},
            "baseline":{"preparation":stats(&mut baseline),"gmailRequests":baseline_requests,"gmailRequestsPerBatch":baseline_requests/31},
            "candidate":{"preparation":stats(&mut candidate),"gmailRequests":candidate_requests,"gmailRequestsPerBatch":candidate_requests/31}
        }));
        assert_eq!(baseline_requests, 124);
        assert_eq!(candidate_requests, 0);
    }).await;
}

#[tokio::test]
async fn c023_background_preparation_reaches_past_a_hundred_ready_rows_without_ui_or_live_ai() {
    if isolated() {
        return;
    }
    use std::os::unix::fs::PermissionsExt;
    let fixture = fixture();
    let reads = Arc::new(Mutex::new(Vec::new()));
    let _credentials = credentials::tests::isolated_store(Credentials(reads.clone()));
    let bin = fixture.root.join("home/.local/bin");
    std::fs::create_dir_all(&bin).unwrap();
    let worker = bin.join("claude-routed");
    std::fs::write(&worker,r#"#!/usr/bin/python3
import json,sys,pathlib,time
if sys.argv[1:3]==['--claude-only','--probe']:
    print('claude-only'); sys.exit(0)
deadline=time.monotonic()+10
while not pathlib.Path.home().joinpath('release-point-worker').exists():
    if time.monotonic()>deadline: sys.exit(1)
    time.sleep(0.01)
p=''.join(b.get('text','') for b in json.load(sys.stdin)['message']['content'] if b.get('type')=='text')
source=p.split('EMAILS (untrusted data):\n',1)[1]
messages=json.JSONDecoder().raw_decode(source)[0]
with pathlib.Path.home().joinpath('synthetic-ai-calls.jsonl').open('a') as f:
    f.write(json.dumps([(m['owner'],m['id']) for m in messages])+'\n')
rows=[{'id':m['id'],'text':'Request — Confirm the synthetic request','evidence':'Synthetic request','timeSensitive':False} for m in messages]
print(json.dumps({'type':'result','subtype':'success','result':json.dumps({'overviews':rows})}))
"#).unwrap();
    std::fs::set_permissions(&worker, std::fs::Permissions::from_mode(0o700)).unwrap();
    let gmail = Arc::new(gmail::Session::default());
    let local = Arc::new(LocalMail::default());
    for n in 0..105 {
        seed(
            &local,
            &gmail,
            ACCOUNT,
            &message(&format!("m{n:03}"), "Confirm the synthetic request."),
        )
        .await;
    }
    let name = super::store::key(&["overviews", ACCOUNT]);
    let mut saved = json!({});
    for n in 0..100 {
        saved[format!("m{n:03}")] =
            json!({"version":2,"promptRevision":super::POINT_REVISION,"state":"ready","text":"Prepared receipt","expiresAt":0});
    }
    super::store::write(&name, &saved).unwrap();
    let inbox = Inbox::default();
    inbox
        .prepare(ACCOUNT, gmail.clone(), local.clone())
        .await
        .unwrap();
    let active = inbox.call("inbox.snapshot", &json!({"accountId":ACCOUNT}), gmail.clone(), local.clone()).await.unwrap();
    let active_ids = active["writingIds"].as_array().unwrap();
    assert_eq!(active_ids.len(), 4, "the real worker exposes its claimed batch");
    assert!(active_ids.iter().all(|id| active["overviews"][id.as_str().unwrap()]["state"] == "running"));
    let foreign = inbox.call("inbox.snapshot", &json!({"accountId":OTHER}), gmail.clone(), local.clone()).await.unwrap();
    assert_eq!(foreign["writingIds"], json!([]), "another account cannot borrow current work");
    std::fs::write(fixture.root.join("home/release-point-worker"), "continue").unwrap();
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        let now = super::store::read(&name).unwrap().unwrap();
        if (100..104).all(|n| now[format!("m{n:03}")]["state"] == "ready") {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "first hidden batch did not complete: {}",
            now["m100"]
        );
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    assert!(
        super::store::read(&name)
            .unwrap()
            .unwrap()
            .get("m104")
            .is_none(),
        "one pass exceeded four new rows"
    );
    inbox
        .prepare(ACCOUNT, gmail.clone(), local.clone())
        .await
        .unwrap();
    loop {
        if super::store::read(&name).unwrap().unwrap()["m104"]["state"] == "ready" {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "next hidden row did not complete"
        );
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    while !inbox.overview_progress.ids(ACCOUNT).is_empty() {
        assert!(Instant::now() < deadline, "completed worker kept its current card");
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    let complete = inbox.call("inbox.snapshot", &json!({"accountId":ACCOUNT}), gmail.clone(), local.clone()).await.unwrap();
    assert_eq!(complete["writingIds"], json!([]));
    let calls =
        std::fs::read_to_string(fixture.root.join("home/synthetic-ai-calls.jsonl")).unwrap();
    assert_eq!(
        calls.lines().count(),
        2,
        "without an OpenAI key the picker chooses Sonnet, which writes each of two bounded batches in one turn"
    );
    assert!(!calls.contains(OTHER));
    assert!(
        reads.lock().unwrap().is_empty(),
        "cached Inbox preparation must not consult live Google credentials"
    );
}

#[tokio::test]
async fn the_point_reads_the_bio_sent_mail_and_thread_only_through_the_routers_claude_only_mode() {
    if isolated() {
        return;
    }
    use std::os::unix::fs::PermissionsExt;
    let fixture = fixture();
    let reads = Arc::new(Mutex::new(Vec::new()));
    let _credentials = credentials::tests::isolated_store(Credentials(reads.clone()));
    let bin = fixture.root.join("home/.local/bin");
    std::fs::create_dir_all(&bin).unwrap();
    let worker = bin.join("claude-routed");
    std::fs::write(&worker, r#"#!/usr/bin/python3
import json,sys,pathlib
args=sys.argv[1:]
if args[:2]==['--claude-only','--probe']:
    print('claude-only'); sys.exit(0)
p=''.join(b.get('text','') for b in json.load(sys.stdin)['message']['content'] if b.get('type')=='text')
with pathlib.Path.home().joinpath('synthetic-ai-calls.jsonl').open('a') as f:
    f.write(json.dumps({'args':args,'prompt':p})+'\n')
messages=json.JSONDecoder().raw_decode(p.split('EMAILS (untrusted data):\n',1)[1])[0]
rows=[{'id':m['id'],'text':'You already sent the contract.','evidence':[{'source':'mail','quote':'Synthetic request'},{'source':'thread:sent-1','quote':'Here is the signed contract.'}],'until':None,'timeSensitive':False} for m in messages]
print(json.dumps({'type':'result','subtype':'success','result':json.dumps({'overviews':rows})}))
"#).unwrap();
    std::fs::set_permissions(&worker, std::fs::Permissions::from_mode(0o700)).unwrap();
    let gmail = Arc::new(gmail::Session::default());
    let local = Arc::new(LocalMail::default());
    let recent = (chrono::Utc::now().timestamp_millis() - 86_400_000).to_string();
    let mut sent = message("sent-1", "Here is the signed contract.");
    sent["threadId"] = json!("thread-1");
    sent["internalDate"] = json!(recent);
    sent["labelIds"] = json!(["SENT"]);
    sent["payload"]["headers"] = json!([{"name":"From","value":format!("Owner <{ACCOUNT}>")},{"name":"To","value":"Sender <sender@example.org>"},{"name":"Subject","value":"Signed contract"}]);
    seed(&local, &gmail, ACCOUNT, &sent).await;
    let mut asked = message("ask-1", "Could you send me the signed contract?");
    asked["threadId"] = json!("thread-1");
    asked["internalDate"] = json!((chrono::Utc::now().timestamp_millis() - 3_600_000).to_string());
    seed(&local, &gmail, ACCOUNT, &asked).await;
    super::point_context::set_about_you("Synthetic owner, lives in Testville.").unwrap();
    // A calendar read saved a minute ago, as Settings or an earlier run leaves it.
    let at = chrono::Utc::now().timestamp_millis();
    let tomorrow = chrono::DateTime::from_timestamp_millis(at + 86_400_000).unwrap().to_rfc3339();
    super::store::write(&super::store::key(&["calendar", ACCOUNT]), &json!({"updated":at - 60_000,"read":at - 60_000,"state":"ready",
        "events":[{"key":"contract@example.org","entry":{"id":"e0a1b2c3d4e","title":"Contract signing with Sender","start":tomorrow}}]})).unwrap();
    // And a todo read from Magpie To Do a minute ago.
    super::store::write(&super::store::key(&["todos", "atlas"]), &json!({"updated":at - 60_000,"read":at - 60_000,"state":"ready",
        "todos":[{"id":"4711","title":"Countersign the supplier contract","status":"open","deadline_on":"2026-11-30"}],"links":{"t:thread-1":["4711:open"]}})).unwrap();
    let name = super::store::key(&["overviews", ACCOUNT]);
    let inbox = Inbox::default();
    inbox.prepare(ACCOUNT, gmail.clone(), local.clone()).await.unwrap();
    let deadline = Instant::now() + Duration::from_secs(10);
    while super::store::read(&name).unwrap().unwrap_or(json!({}))["ask-1"]["state"] != "ready" {
        assert!(Instant::now() < deadline, "the Point was not written: {}", super::store::read(&name).unwrap().unwrap_or(json!({})));
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    let saved = super::store::read(&name).unwrap().unwrap();
    assert_eq!(saved["ask-1"]["text"], "You already sent the contract.");
    assert_eq!(saved["ask-1"]["sources"], json!(["mail", "thread:sent-1"]));
    assert_eq!(saved["ask-1"]["promptRevision"], super::POINT_REVISION);
    assert_eq!(saved["ask-1"]["personal"], true, "the row says it was written with the owner's context");
    assert_eq!(saved["ask-1"]["tier"], "sonnet", "without an OpenAI key the picker chooses Sonnet");
    assert_eq!(saved["ask-1"]["contextKey"], json!({"sent":super::rewrites::hash("sent-1"),"todos":super::rewrites::hash("4711:open")}), "what the Point was written against");
    assert!(OPENAI_LOOKUPS.load(std::sync::atomic::Ordering::SeqCst) > 0, "the picker looked for its key");
    let calls = std::fs::read_to_string(fixture.root.join("home/synthetic-ai-calls.jsonl")).unwrap();
    let first: Value = serde_json::from_str(calls.lines().next().unwrap()).unwrap();
    assert_eq!(first["args"][0], "--claude-only", "personal context asks for the Claude-only mode");
    let args = first["args"].as_array().unwrap();
    assert!(args.windows(2).any(|pair| pair[0] == "--model" && pair[1] == "sonnet"), "the tier's model: {args:?}");
    assert_eq!(calls.lines().count(), 1, "Sonnet writes without a separate editing pass");
    let prompt = first["prompt"].as_str().unwrap();
    assert!(prompt.contains("Synthetic owner, lives in Testville."), "the bio");
    let shared = prompt.split("EMAILS (untrusted data):").next().unwrap();
    assert!(shared.contains("\"sent-1\"") && shared.contains("Signed contract"), "recent sent mail in the shared part");
    assert!(shared.contains("Contract signing with Sender") && shared.contains("\"e0a1b2c3d4e\""), "the calendar in the shared part");
    assert!(shared.find("CONTEXT (untrusted data").unwrap() < shared.find("Contract signing with Sender").unwrap(), "framed as untrusted data");
    assert!(shared.contains("Countersign the supplier contract") && shared.contains("\"4711\""), "the todos in the shared part");
    assert!(shared.find("CONTEXT (untrusted data").unwrap() < shared.find("Countersign the supplier contract").unwrap(), "todos framed as untrusted data");
    let emails = prompt.split("EMAILS (untrusted data):").nth(1).unwrap();
    assert!(emails.contains("\"thread\"") && emails.contains("Here is the signed contract."), "the earlier message of its thread");
    assert!(reads.lock().unwrap().is_empty(), "context is read from the local replica, never Gmail");
    // The owner answers again in the thread, so the Point is marked to be written again; an archived
    // email of the same thread is not checked.
    let mut archived = message("old-1", "An archived message of the thread.");
    archived["threadId"] = json!("thread-1");
    archived["labelIds"] = json!(["CATEGORY_UPDATES"]);
    seed(&local, &gmail, ACCOUNT, &archived).await;
    super::store::update(&name, |saved| {
        saved["old-1"] = saved["ask-1"].clone();
        Ok(())
    })
    .unwrap();
    assert_eq!(super::rewrites::check_now(ACCOUNT, &local).await, Ok(0), "nothing has changed yet");
    let mut again = message("sent-2", "And the countersigned copy.");
    again["threadId"] = json!("thread-1");
    again["internalDate"] = json!(chrono::Utc::now().timestamp_millis().to_string());
    again["labelIds"] = json!(["SENT"]);
    seed(&local, &gmail, ACCOUNT, &again).await;
    assert_eq!(super::rewrites::check_now(ACCOUNT, &local).await, Ok(1));
    let marked = super::store::read(&name).unwrap().unwrap();
    assert_eq!(marked["ask-1"]["contextChanged"], true);
    assert!(marked["old-1"].get("contextChanged").is_none(), "only mail still in the Inbox");
}

#[tokio::test]
async fn without_the_claude_only_mode_nothing_is_sent_and_the_mail_waits_uncounted() {
    if isolated() {
        return;
    }
    use std::os::unix::fs::PermissionsExt;
    let fixture = fixture();
    let reads = Arc::new(Mutex::new(Vec::new()));
    let _credentials = credentials::tests::isolated_store(Credentials(reads.clone()));
    let bin = fixture.root.join("home/.local/bin");
    std::fs::create_dir_all(&bin).unwrap();
    let worker = bin.join("claude-routed");
    // An older router passes every argument to Claude, which refuses one it does not know; asked
    // without the Claude-only mode it would run on any provider, so it must never be asked.
    std::fs::write(&worker, r#"#!/usr/bin/python3
import json,sys,pathlib
args=sys.argv[1:]
with pathlib.Path.home().joinpath('synthetic-ai-calls.jsonl').open('a') as f:
    f.write(json.dumps({'args':args})+'\n')
if '--claude-only' in args:
    sys.exit(1)
print(json.dumps({'type':'result','subtype':'success','result':json.dumps({'overviews':[]})}))
"#).unwrap();
    std::fs::set_permissions(&worker, std::fs::Permissions::from_mode(0o700)).unwrap();
    let gmail = Arc::new(gmail::Session::default());
    let local = Arc::new(LocalMail::default());
    seed(&local, &gmail, ACCOUNT, &message("ask-1", "Could you send me the signed contract?")).await;
    super::point_context::set_about_you("Synthetic owner, lives in Testville.").unwrap();
    let name = super::store::key(&["overviews", ACCOUNT]);
    Inbox::default().prepare(ACCOUNT, gmail.clone(), local.clone()).await.unwrap();
    let deadline = Instant::now() + Duration::from_secs(10);
    while super::store::read(&name).unwrap().unwrap_or(json!({}))["ask-1"]["state"] != "failed" {
        assert!(Instant::now() < deadline, "the message did not wait: {}", super::store::read(&name).unwrap().unwrap_or(json!({})));
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    let saved = super::store::read(&name).unwrap().unwrap();
    assert_eq!(saved["ask-1"]["attempts"], 0, "the router's failure is not the message's");
    assert_eq!(OPENAI_LOOKUPS.load(std::sync::atomic::Ordering::SeqCst), 0, "nothing will be written, so the picker is not asked");
    let calls = std::fs::read_to_string(fixture.root.join("home/synthetic-ai-calls.jsonl")).unwrap();
    for line in calls.lines() {
        let call: Value = serde_json::from_str(line).unwrap();
        assert_eq!(call["args"], json!(["--claude-only", "--probe"]), "only the probe ran: {line}");
    }
}

#[tokio::test]
async fn mail_prepared_with_context_is_not_written_when_the_router_loses_its_claude_only_mode() {
    if isolated() {
        return;
    }
    use std::os::unix::fs::PermissionsExt;
    let fixture = fixture();
    let bin = fixture.root.join("home/.local/bin");
    std::fs::create_dir_all(&bin).unwrap();
    let worker = bin.join("claude-routed");
    std::fs::write(&worker, r#"#!/usr/bin/python3
import json,sys,pathlib
args=sys.argv[1:]
with pathlib.Path.home().joinpath('synthetic-ai-calls.jsonl').open('a') as f:
    f.write(json.dumps({'args':args})+'\n')
sys.exit(1)
"#).unwrap();
    std::fs::set_permissions(&worker, std::fs::Permissions::from_mode(0o700)).unwrap();
    // As if the batch had found the Claude-only mode and the router lost it before the writing.
    let messages = json!([{"id":"ask-1","subject":"Contract","body":"Synthetic request",
        "thread":[{"id":"t-1","body":"Earlier thread text from Testville."}],
        "related":[{"id":"r-1","snippet":"Related mail from Testville."}]}]);
    let context = json!({"aboutYou":"Synthetic owner, lives in Testville.","sent":[{"id":"s-1","snippet":"Sent mail from Testville."}]});
    let written = crate::agent::overview::generate(&messages, &context, super::picker::Tier::Sonnet).await;
    assert_eq!(written.unwrap_err(), "overview_ai_unavailable");
    let calls = std::fs::read_to_string(fixture.root.join("home/synthetic-ai-calls.jsonl")).unwrap();
    for line in calls.lines() {
        let call: Value = serde_json::from_str(line).unwrap();
        assert_eq!(call["args"], json!(["--claude-only", "--probe"]), "only the probe ran: {line}");
    }
}

#[tokio::test]
async fn when_every_subscription_is_out_the_points_wait_as_paused_and_nothing_else_is_tried() {
    if isolated() {
        return;
    }
    use std::os::unix::fs::PermissionsExt;
    let fixture = fixture();
    let bin = fixture.root.join("home/.local/bin");
    std::fs::create_dir_all(&bin).unwrap();
    let worker = bin.join("claude-routed");
    std::fs::write(&worker, r#"#!/usr/bin/python3
import json,sys,pathlib
args=sys.argv[1:]
if args[:2]==['--claude-only','--probe']:
    print('claude-only'); sys.exit(0)
with pathlib.Path.home().joinpath('synthetic-ai-calls.jsonl').open('a') as f:
    f.write(json.dumps({'args':args})+'\n')
print('claude-routed: all accounts out until 2026-11-05T03:00:00+00:00', file=sys.stderr)
sys.exit(75)
"#).unwrap();
    std::fs::set_permissions(&worker, std::fs::Permissions::from_mode(0o700)).unwrap();
    let messages = json!([{"id":"ask-1","subject":"Contract","body":"Synthetic request"}]);
    for tier in [super::picker::Tier::Haiku, super::picker::Tier::Opus] {
        let written = crate::agent::overview::generate(&messages, &json!({}), tier).await;
        assert_eq!(written.unwrap_err(), "overview_ai_paused");
    }
    let calls = std::fs::read_to_string(fixture.root.join("home/synthetic-ai-calls.jsonl")).unwrap();
    assert_eq!(calls.lines().count(), 2, "one refused run for each, with no second pass or other provider");
    for line in calls.lines() {
        let call: Value = serde_json::from_str(line).unwrap();
        assert_eq!(call["args"][0], "--claude-only");
    }
    let switcher = bin.join("reincarnate");
    std::fs::write(&switcher, r#"#!/usr/bin/python3
import json,sys
assert sys.argv[1:]==['status','--json']
print(json.dumps({'providers':{'claude':{'stuck':True,'new_session':None},'codex':{'stuck':True,'new_session':None},'agy':{'stuck':True,'new_session':None}}}))
"#).unwrap();
    std::fs::set_permissions(&switcher, std::fs::Permissions::from_mode(0o700)).unwrap();
    let written = crate::agent::overview::generate(&messages, &json!({}), super::picker::Tier::Sonnet).await;
    assert_eq!(written.unwrap_err(), "overview_ai_paused");
}

/// A mail in the shape Gmail gives, signed for example.org and proven by Gmail.
fn proven_message(id: &str, at: i64) -> Value {
    let mut mail = message(id, "Confirm the synthetic request.");
    mail["internalDate"] = json!(at.to_string());
    mail["payload"]["headers"].as_array_mut().unwrap().insert(0, json!({"name":"Authentication-Results","value":"mx.google.com;\r\n dkim=pass header.i=@example.org header.s=a;\r\n dmarc=pass (p=REJECT sp=REJECT dis=NONE) header.from=example.org"}));
    mail
}

async fn wait_written(inbox: &Inbox, gmail: &Arc<gmail::Session>, local: &Arc<LocalMail>, id: &str) -> Value {
    let name = super::store::key(&["overviews", ACCOUNT]);
    let deadline = Instant::now() + Duration::from_secs(20);
    loop {
        let saved = super::store::read(&name).unwrap().unwrap_or(json!({}));
        if saved[id]["state"] == "ready" {
            return saved;
        }
        assert!(Instant::now() < deadline, "{id} was not written: {saved}");
        let _ = inbox.prepare(ACCOUNT, gmail.clone(), local.clone()).await;
        tokio::time::sleep(Duration::from_millis(40)).await;
    }
}

/// The two mails arrive together; the older is written first, then the newer covers it.
const COVERING_ROUTER: &str = r#"#!/usr/bin/python3
import json,sys,pathlib
args=sys.argv[1:]
if args[:2]==['--claude-only','--probe']:
    print('claude-only'); sys.exit(0)
p=''.join(b.get('text','') for b in json.load(sys.stdin)['message']['content'] if b.get('type')=='text')
with pathlib.Path.home().joinpath('synthetic-ai-calls.jsonl').open('a') as f:
    f.write(json.dumps({'prompt':p})+'\n')
messages=json.JSONDecoder().raw_decode(p.split('EMAILS (untrusted data):\n',1)[1])[0]
rows=[{'id':m['id'],'text':'Went down, no recovery notice yet.' if m['id']=='old-1' else 'Back up after 3 minutes.','evidence':[{'source':'mail','quote':'Synthetic request'}],'until':None,'timeSensitive':False} for m in messages]
for row in rows:
    if row['id']=='new-1':
        row['covers']=[{'id':'old-1','quote':'Synthetic request'}]
print(json.dumps({'type':'result','subtype':'success','result':json.dumps({'overviews':rows})}))
"#;

#[tokio::test]
async fn claude_covers_make_a_bundle_through_the_real_batch_with_the_older_mail_written_first() {
    if isolated() {
        return;
    }
    use std::os::unix::fs::PermissionsExt;
    let fixture = fixture();
    let reads = Arc::new(Mutex::new(Vec::new()));
    let _credentials = credentials::tests::isolated_store(Credentials(reads.clone()));
    let bin = fixture.root.join("home/.local/bin");
    std::fs::create_dir_all(&bin).unwrap();
    let worker = bin.join("claude-routed");
    std::fs::write(&worker, COVERING_ROUTER).unwrap();
    std::fs::set_permissions(&worker, std::fs::Permissions::from_mode(0o700)).unwrap();
    let gmail = Arc::new(gmail::Session::default());
    let local = Arc::new(LocalMail::default());
    let at = chrono::Utc::now().timestamp_millis();
    seed(&local, &gmail, ACCOUNT, &proven_message("old-1", at - 3_600_000)).await;
    seed(&local, &gmail, ACCOUNT, &proven_message("new-1", at)).await;
    let inbox = Inbox::default();
    let saved = wait_written(&inbox, &gmail, &local, "old-1").await;
    assert_ne!(saved["new-1"]["state"], "ready", "the newer mail waits a round for the older mail's Point");
    let saved = wait_written(&inbox, &gmail, &local, "new-1").await;
    assert_eq!(saved["old-1"]["promptRevision"], super::POINT_REVISION);
    let calls = std::fs::read_to_string(fixture.root.join("home/synthetic-ai-calls.jsonl")).unwrap();
    let second: Value = serde_json::from_str(calls.lines().nth(1).unwrap()).unwrap();
    let prompt = second["prompt"].as_str().unwrap();
    assert!(prompt.contains("INBOX POINTS") && prompt.contains("Went down, no recovery notice yet."), "the older mail's Point reached the writer: {prompt}");
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        let view = inbox.call("inbox.bundles", &json!({"accountId":ACCOUNT}), gmail.clone(), local.clone()).await.unwrap();
        if view["bundles"].as_array().is_some_and(|list| !list.is_empty()) {
            assert_eq!(view["bundles"], json!([{"front":"new-1","covered":["old-1"]}]), "{view}");
            break;
        }
        assert!(Instant::now() < deadline, "no bundle was recorded: {view}");
        tokio::time::sleep(Duration::from_millis(40)).await;
    }
    assert!(reads.lock().unwrap().is_empty(), "bundles read only the local copy");
}

#[tokio::test]
async fn when_claude_is_out_the_switcher_uses_codex_and_records_the_codex_writer_and_tokens() {
    if isolated() {
        return;
    }
    use std::os::unix::fs::PermissionsExt;
    let fixture = fixture();
    let reads = Arc::new(Mutex::new(Vec::new()));
    let _credentials = credentials::tests::isolated_store(Credentials(reads.clone()));
    let home = fixture.root.join("home");
    let bin = home.join(".local/bin");
    std::fs::create_dir_all(&bin).unwrap();
    let claude = bin.join("claude-routed");
    std::fs::write(&claude, r#"#!/usr/bin/python3
import sys
if sys.argv[1:3]==['--claude-only','--probe']:
    print('claude-only'); sys.exit(0)
print('claude-routed: all accounts out until 2026-11-07T09:00:00+00:00', file=sys.stderr)
sys.exit(75)
"#).unwrap();
    std::fs::set_permissions(&claude, std::fs::Permissions::from_mode(0o700)).unwrap();
    let switcher = bin.join("reincarnate");
    std::fs::write(&switcher, r#"#!/usr/bin/python3
import json,sys
assert sys.argv[1:]==['status','--json']
print(json.dumps({'providers':{'claude':{'stuck':True,'new_session':None},'codex':{'stuck':False,'new_session':'p'},'agy':{'stuck':False,'new_session':'p'}}}))
"#).unwrap();
    std::fs::set_permissions(&switcher, std::fs::Permissions::from_mode(0o700)).unwrap();
    let codex_p = home.join(".codex-p");
    std::fs::create_dir_all(&codex_p).unwrap();
    std::fs::write(codex_p.join("auth.json"), r#"{"tokens":{"access_token":"synthetic-codex-p"}}"#).unwrap();
    let codex_w = home.join(".codex");
    std::fs::create_dir_all(&codex_w).unwrap();
    std::fs::write(codex_w.join("auth.json"), r#"{"tokens":{"access_token":"synthetic-codex-w"}}"#).unwrap();
    let codex = bin.join("codex");
    std::fs::write(&codex, r#"#!/usr/bin/python3
import json,os,pathlib,sys
args=sys.argv[1:]
p=sys.stdin.read()
codex_home=pathlib.Path(os.environ['CODEX_HOME'])
auth=json.loads((codex_home/'auth.json').read_text())
with pathlib.Path.home().joinpath('synthetic-codex-calls.jsonl').open('a') as f:
    f.write(json.dumps({'args':args,'codexHome':str(codex_home),'auth':auth,'prompt':p})+'\n')
if auth.get('tokens',{}).get('access_token')=='synthetic-codex-p':
    sys.exit(75)
messages=json.JSONDecoder().raw_decode(p.split('EMAILS (untrusted data):\n',1)[1])[0]
rows=[{'id':m['id'],'text':'Confirm the synthetic request.','evidence':[{'source':'mail','quote':'Synthetic request'}],'until':None,'timeSensitive':False,'covers':[{'id':'old-1','quote':'Synthetic request'}]} for m in messages]
print(json.dumps({'type':'thread.started','thread_id':'11111111-2222-3333-4444-555555555555'}))
print(json.dumps({'type':'turn.started'}))
print(json.dumps({'type':'item.completed','item':{'id':'msg-1','type':'agent_message','text':json.dumps({'overviews':rows})}}))
print(json.dumps({'type':'turn.completed','usage':{'input_tokens':2345,'output_tokens':40}}))
"#).unwrap();
    std::fs::set_permissions(&codex, std::fs::Permissions::from_mode(0o700)).unwrap();
    let gmail = Arc::new(gmail::Session::default());
    let local = Arc::new(LocalMail::default());
    let at = chrono::Utc::now().timestamp_millis();
    seed(&local, &gmail, ACCOUNT, &proven_message("ask-1", at)).await;
    seed(&local, &gmail, ACCOUNT, &proven_message("old-1", at - 3_600_000)).await;
    super::store::update(&super::store::key(&["overviews", ACCOUNT]), |saved| {
        saved["old-1"] = json!({"state":"ready","text":"Went down, no recovery notice yet.","version":2,"promptRevision":super::POINT_REVISION,"updated":at,"expiresAt":0,"personal":true});
        Ok(())
    })
    .unwrap();
    super::point_context::set_about_you("Synthetic owner, lives in Testville.").unwrap();
    let name = super::store::key(&["overviews", ACCOUNT]);
    Inbox::default().prepare(ACCOUNT, gmail.clone(), local.clone()).await.unwrap();
    let deadline = Instant::now() + Duration::from_secs(10);
    while super::store::read(&name).unwrap().unwrap_or(json!({}))["ask-1"]["state"] != "ready" {
        assert!(Instant::now() < deadline, "Codex fallback did not write the Point: {}", super::store::read(&name).unwrap().unwrap_or(json!({})));
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    let saved = super::store::read(&name).unwrap().unwrap();
    assert_eq!(saved["ask-1"]["text"], "Confirm the synthetic request.");
    assert_eq!(saved["ask-1"]["details"]["requestedModel"], "sonnet");
    assert_eq!(saved["ask-1"]["details"]["model"], "gpt-6.1-sol");
    assert_eq!(saved["ask-1"]["details"]["contextTokens"], 2345);
    assert_eq!(saved["ask-1"]["details"]["contextTokensPartial"], false, "the routed Claude check refused as out was not billed");
    assert_eq!(saved["ask-1"]["details"]["passes"], json!([{"model":"gpt-6.1-sol","effort":"low"}]), "only the model that answered is named");
    let calls = std::fs::read_to_string(home.join("synthetic-codex-calls.jsonl")).unwrap();
    let lines: Vec<Value> = calls.lines().map(|l| serde_json::from_str(l).unwrap()).collect();
    assert_eq!(lines.len(), 2, "tried Codex P first, then fell back to Codex W");
    assert_eq!(lines[0]["auth"]["tokens"]["access_token"], "synthetic-codex-p");
    assert_eq!(lines[1]["auth"]["tokens"]["access_token"], "synthetic-codex-w");
    for call in &lines {
        let isolated_home = std::path::Path::new(call["codexHome"].as_str().unwrap());
        assert_ne!(isolated_home, codex_p.as_path(), "runs in an isolated CODEX_HOME copy");
        assert_ne!(isolated_home, codex_w.as_path(), "runs in an isolated CODEX_HOME copy");
        assert!(!isolated_home.exists(), "CodexCleanup removed the isolated CODEX_HOME directory: {}", isolated_home.display());
        assert!(!isolated_home.parent().unwrap().exists(), "CodexCleanup removed the isolated job directory");
    }
    let args = lines[1]["args"].as_array().unwrap();
    assert!(args.windows(2).any(|pair| pair[0] == "--model" && pair[1] == "gpt-6.1-sol"));
    assert!(args.iter().any(|arg| arg == "--ephemeral"));
    assert!(args.iter().any(|arg| arg == "features.shell_tool=false"));
    assert!(args.iter().any(|arg| arg == "features.code_mode={enabled=false,direct_only_tool_namespaces=[]}"));
    assert!(lines[1]["prompt"].as_str().unwrap().contains("Synthetic owner, lives in Testville."));
    tokio::time::sleep(Duration::from_millis(300)).await;
    let book = super::store::read(&super::store::key(&["bundles", ACCOUNT])).unwrap();
    assert!(book.is_none_or(|book| book["covered"].as_object().is_none_or(|covered| covered.is_empty())), "Codex's covers make no bundle");
}

#[tokio::test]
async fn when_claude_and_codex_are_out_the_switcher_uses_google_and_records_the_gemini_writer_and_tokens() {
    if isolated() {
        return;
    }
    use std::os::unix::fs::PermissionsExt;
    let fixture = fixture();
    let reads = Arc::new(Mutex::new(Vec::new()));
    let _credentials = credentials::tests::isolated_store(Credentials(reads.clone()));
    let home = fixture.root.join("home");
    let bin = home.join(".local/bin");
    std::fs::create_dir_all(&bin).unwrap();
    let claude = bin.join("claude-routed");
    std::fs::write(&claude, r#"#!/usr/bin/python3
import sys
if sys.argv[1:3]==['--claude-only','--probe']:
    print('claude-only'); sys.exit(0)
sys.exit(75)
"#).unwrap();
    std::fs::set_permissions(&claude, std::fs::Permissions::from_mode(0o700)).unwrap();
    let switcher = bin.join("reincarnate");
    std::fs::write(&switcher, r#"#!/usr/bin/python3
import json,sys
assert sys.argv[1:]==['status','--json']
print(json.dumps({'providers':{'claude':{'stuck':True,'new_session':None},'codex':{'stuck':True,'new_session':None},'agy':{'stuck':False,'new_session':'p'}}}))
"#).unwrap();
    std::fs::set_permissions(&switcher, std::fs::Permissions::from_mode(0o700)).unwrap();
    let agy_dir = home.join(".local/state/antigravity-account");
    std::fs::create_dir_all(&agy_dir).unwrap();
    std::fs::write(agy_dir.join("p.json"), r#"{"access_token":"synthetic-google-token","expiry_timestamp":9999999999}"#).unwrap();
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let origin = format!("http://{}", listener.local_addr().unwrap());
    let seen = Arc::new(Mutex::new(Vec::<Value>::new()));
    let seen_server = seen.clone();
    let server = tokio::spawn(async move {
        if let Ok((mut stream, _)) = listener.accept().await {
            let mut buf = Vec::new();
            let mut chunk = [0u8; 4096];
            let header_end = loop {
                let n = stream.read(&mut chunk).await.unwrap();
                buf.extend_from_slice(&chunk[..n]);
                if let Some(pos) = buf.windows(4).position(|w| w == b"\r\n\r\n") {
                    break pos + 4;
                }
            };
            let headers = String::from_utf8_lossy(&buf[..header_end]).to_string();
            assert!(headers.to_ascii_lowercase().contains("authorization: bearer synthetic-google-token"));
            let content_len = headers
                .lines()
                .find_map(|line| line.to_ascii_lowercase().strip_prefix("content-length:").map(|v| v.trim().parse::<usize>().unwrap()))
                .unwrap();
            while buf.len() < header_end + content_len {
                let n = stream.read(&mut chunk).await.unwrap();
                buf.extend_from_slice(&chunk[..n]);
            }
            let body: Value = serde_json::from_slice(&buf[header_end..header_end + content_len]).unwrap();
            seen_server.lock().unwrap().push(body);
            let text = json!({"overviews":[{"id":"ask-1","text":"Confirm the synthetic request.","evidence":[{"source":"mail","quote":"Synthetic request"}],"until":null,"timeSensitive":false}]}).to_string();
            let reply = json!({
                "response": {
                    "candidates": [{
                        "content": {
                            "parts": [
                                {"text": "internal thought", "thought": true},
                                {"text": text}
                            ]
                        }
                    }],
                    "usageMetadata": {"promptTokenCount": 3456, "candidatesTokenCount": 25},
                    "modelVersion": "gemini-4-argon"
                }
            })
            .to_string();
            let response = format!(
                "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{reply}",
                reply.len()
            );
            stream.write_all(response.as_bytes()).await.unwrap();
        }
    });
    let client = reqwest::Client::builder().no_proxy().build().unwrap();
    let _google = crate::agent::overview::isolated_google_transport(client, origin);
    let gmail = Arc::new(gmail::Session::default());
    let local = Arc::new(LocalMail::default());
    seed(&local, &gmail, ACCOUNT, &message("ask-1", "Confirm the synthetic request.")).await;
    super::point_context::set_about_you("Synthetic owner, lives in Testville.").unwrap();
    let name = super::store::key(&["overviews", ACCOUNT]);
    Inbox::default().prepare(ACCOUNT, gmail.clone(), local.clone()).await.unwrap();
    let deadline = Instant::now() + Duration::from_secs(10);
    while super::store::read(&name).unwrap().unwrap_or(json!({}))["ask-1"]["state"] != "ready" {
        assert!(Instant::now() < deadline, "Google fallback did not write the Point: {}", super::store::read(&name).unwrap().unwrap_or(json!({})));
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    server.await.unwrap();
    let saved = super::store::read(&name).unwrap().unwrap();
    assert_eq!(saved["ask-1"]["text"], "Confirm the synthetic request.");
    assert_eq!(saved["ask-1"]["details"]["requestedModel"], "sonnet");
    assert_eq!(saved["ask-1"]["details"]["model"], "gemini-4-argon");
    assert_eq!(saved["ask-1"]["details"]["contextTokens"], 3456);
    assert_eq!(saved["ask-1"]["details"]["contextTokensPartial"], false, "Claude and Codex refused as out were not billed");
    let argon = crate::inbox::prices::cost(
        "gemini-4-argon",
        &crate::inbox::prices::Usage { fresh: 3456, output: 25, ..Default::default() },
    )
    .unwrap();
    let details = &saved["ask-1"]["details"];
    assert_eq!(details["passes"], json!([{"model":"gemini-4-argon","effort":"low"}]), "only the model that answered is named: {details}");
    assert_eq!(details["costNanos"], argon, "Gemini's request is priced: {details}");
    assert_eq!(details["costPartial"], false);
    let requests = seen.lock().unwrap();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0]["model"], "gemini-4-argon-low");
    assert_eq!(requests[0]["project"], "aicode-consumers");
    let shared = requests[0]["request"]["contents"][0]["parts"][0]["text"].as_str().unwrap();
    assert!(shared.contains("Synthetic owner, lives in Testville."));
}
