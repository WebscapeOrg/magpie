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

impl CredentialStore for Credentials {
    fn get(&self, key: &CredentialKey) -> Result<Secret, Error> {
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
        assert_eq!(result, Err("gmail_not_found"));
        assert_eq!(provider.requests().len(), 2);
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
import json,sys,pathlib
p=json.load(sys.stdin)['message']['content'][0]['text']
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
            json!({"version":2,"promptRevision":1,"state":"ready","text":"Prepared receipt","expiresAt":0});
    }
    super::store::write(&name, &saved).unwrap();
    let inbox = Inbox::default();
    inbox
        .prepare(ACCOUNT, gmail.clone(), local.clone())
        .await
        .unwrap();
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
    let calls =
        std::fs::read_to_string(fixture.root.join("home/synthetic-ai-calls.jsonl")).unwrap();
    assert_eq!(
        calls.lines().count(),
        4,
        "two reviewed AI turns for each of two bounded batches"
    );
    assert!(!calls.contains(OTHER));
    assert!(
        reads.lock().unwrap().is_empty(),
        "cached Inbox preparation must not consult live Google credentials"
    );
}
