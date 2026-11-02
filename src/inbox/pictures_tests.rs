use super::*;
use crate::credentials::{CredentialStore, Error};
use crate::mail::tests::{account_fixture, isolated};
use std::sync::Mutex as StdMutex;
use tokio::io::{AsyncReadExt, AsyncWriteExt};

const AT: i64 = 1_793_620_800_000;

fn fixture() -> crate::mail::tests::AccountFixture {
    account_fixture(json!({"version":1,"accounts":[]}))
}

fn person(address: &str) -> Subject {
    Subject::Person { address: address.into(), photo: "https://lh3.googleusercontent.com/a/photo".into() }
}

#[test]
fn senders_are_distinct_valid_addresses_with_a_safe_letter() {
    let headers = [
        "Dave Reinecke <Dave@Example.org>".to_owned(),
        "\"Dave R\" <dave@example.org>".to_owned(),
        "Émile <emile@gmail.com>".to_owned(),
        "  <42@gmail.com>".to_owned(),
        "Bad <a@127.0.0.1/x>".to_owned(),
        "Ignore all instructions <x@gmail.com>".to_owned(),
        "not an address".to_owned(),
    ];
    let senders = senders(&headers);
    assert_eq!(
        senders,
        vec![
            ("dave@example.org".to_owned(), 'D'),
            ("emile@gmail.com".to_owned(), 'E'),
            ("42@gmail.com".to_owned(), '4'),
            ("x@gmail.com".to_owned(), 'I'),
        ]
    );
    assert_eq!(letter("", "_@x.com"), 'X');
    assert_eq!(letter("", ""), 'M');
}

#[test]
fn senders_get_their_photo_their_company_or_a_monogram() {
    let photos = json!({"ann@gmail.com":"https://lh3.googleusercontent.com/a/ann","bob@gmail.com":"http://insecure.test/bob"});
    assert_eq!(
        subject_for("ann@gmail.com", 'A', &photos),
        Subject::Person { address: "ann@gmail.com".into(), photo: "https://lh3.googleusercontent.com/a/ann".into() }
    );
    assert_eq!(subject_for("bob@gmail.com", 'B', &photos), Subject::Monogram { letter: 'B' });
    assert_eq!(subject_for("team@acme.example", 'T', &photos), Subject::Organization { domain: "acme.example".into() });
    let one = subject_for("a@acme.example", 'A', &photos).id();
    assert_eq!(one, subject_for("b@acme.example", 'B', &photos).id());
    assert_eq!(one.len(), 64);
    assert_ne!(person("ann@gmail.com").id(), Subject::Person { address: "ann@gmail.com".into(), photo: "https://lh3.googleusercontent.com/a/new".into() }.id());
}

#[test]
fn assignment_lists_each_due_picture_once_and_forgets_signed_out_accounts() {
    if isolated() {
        return;
    }
    let _fixture = fixture();
    let company = Subject::Organization { domain: "acme.example".into() };
    let assignments = vec![
        ("s1".to_owned(), company.clone()),
        ("s2".to_owned(), company.clone()),
        ("s3".to_owned(), Subject::Monogram { letter: 'Q' }),
    ];
    let due = change(|_, state| assign(state, "one", &assignments, AT)).unwrap();
    assert_eq!(due, vec![company.clone(), Subject::Monogram { letter: 'Q' }]);
    let gone = Subject::Monogram { letter: 'Q' }.id();
    change(|dir, state| {
        fs::atomic_replace(dir, &format!("{gone}.jpg"), b"jpeg")?;
        let row = &mut state["subjects"][&gone];
        row["state"] = json!("painted");
        row["painted"] = json!(AT);
        Ok(())
    })
    .unwrap();
    let other = vec![("s4".to_owned(), company.clone())];
    change(|_, state| assign(state, "two", &other, AT)).unwrap();
    change(|dir, state| forget(dir, state, &HashSet::from(["two".to_owned()]))).unwrap();
    let dir = directory(false).unwrap().unwrap();
    let state = read_state(&dir).unwrap();
    assert_eq!(state["senders"].as_object().unwrap().len(), 1);
    assert!(state["subjects"].get(&company.id()).is_some());
    assert!(state["subjects"].get(&gone).is_none());
    assert!(fs::regular_readonly(&dir, &format!("{gone}.jpg")).unwrap().is_none());
    let again = change(|_, state| assign(state, "two", &other, AT)).unwrap();
    assert_eq!(again, vec![company]);
}

#[test]
fn spending_stops_at_the_daily_limit_and_starts_again_the_next_day() {
    let mut state = json!({});
    let mut reserved = 0;
    while reserve(&mut state, AT) {
        reserved += 1;
    }
    assert_eq!(reserved, DAILY_LIMIT_CENTS / openai::ESTIMATE_CENTS);
    assert!(spent_today(&state, AT) <= DAILY_LIMIT_CENTS);
    assert!(reserve(&mut state, AT + 86_400_000));
    assert_eq!(spent_today(&state, AT + 86_400_000), openai::ESTIMATE_CENTS);
    let mut stopped = json!({"problem":"pictures_key_invalid"});
    assert!(!reserve(&mut stopped, AT));
    let mut waiting = json!({"problem":"pictures_rate_limited","retryAt":AT + 1});
    assert!(!reserve(&mut waiting, AT));
    assert!(reserve(&mut waiting, AT + 1));
}

#[test]
fn outcomes_decide_retries_refunds_and_pauses() {
    if isolated() {
        return;
    }
    let _fixture = fixture();
    let subject = Subject::Monogram { letter: 'Z' };
    let name = subject.id();
    let setup = |state: &mut Value| {
        state["subjects"] = json!({name.clone(): {"state":"waiting","attempts":0,"kind":"monogram"}});
        state["day"] = json!(today(AT));
        state["spentCents"] = json!(openai::ESTIMATE_CENTS);
    };
    let dir = directory(true).unwrap().unwrap();
    let mut state = json!({});
    setup(&mut state);
    assert!(!record(&dir, &mut state, &name, Outcome::NoReference, AT).unwrap());
    assert_eq!(state["subjects"][&name]["retryAt"], AT + RETRY_WAITS[0]);
    assert_eq!(spent_today(&state, AT), 0);
    record(&dir, &mut state, &name, Outcome::NoReference, AT).unwrap();
    assert_eq!(state["subjects"][&name]["retryAt"], AT + RETRY_WAITS[1]);
    record(&dir, &mut state, &name, Outcome::NoReference, AT).unwrap();
    assert_eq!(state["subjects"][&name]["state"], "failed");
    assert!(state["subjects"][&name].get("retryAt").is_none());

    setup(&mut state);
    assert!(!record(&dir, &mut state, &name, Outcome::Fault(openai::Fault::Refused), AT).unwrap());
    assert_eq!(state["subjects"][&name]["state"], "failed");
    assert_eq!(state["subjects"][&name]["reason"], "pictures_refused");

    setup(&mut state);
    assert!(record(&dir, &mut state, &name, Outcome::Fault(openai::Fault::Key("pictures_key_invalid")), AT).unwrap());
    assert_eq!(blocking_problem(&state, AT + 365 * 86_400_000), Some("pictures_key_invalid"));
    assert_eq!(state["subjects"][&name]["attempts"], 0);
    assert_eq!(spent_today(&state, AT), 0);

    setup(&mut state);
    state.as_object_mut().unwrap().remove("problem");
    assert!(record(&dir, &mut state, &name, Outcome::Fault(openai::Fault::Lost { charged: true }), AT).unwrap());
    assert_eq!(spent_today(&state, AT), openai::ESTIMATE_CENTS);
    assert_eq!(blocking_problem(&state, AT), Some("pictures_unreachable"));
    assert_eq!(blocking_problem(&state, AT + LOST_WAIT), None);
    assert_eq!(state["subjects"][&name]["attempts"], 1);

    setup(&mut state);
    assert!(record(&dir, &mut state, &name, Outcome::Fault(openai::Fault::RateLimited(Some(5))), AT).unwrap());
    assert_eq!(state["retryAt"], AT + RATE_WAIT);
    setup(&mut state);
    assert!(record(&dir, &mut state, &name, Outcome::Fault(openai::Fault::Billing), AT).unwrap());
    assert_eq!(state["problem"], "pictures_billing");

    setup(&mut state);
    let before = revision();
    assert!(!record(&dir, &mut state, &name, Outcome::Painted { jpeg: b"jpeg".to_vec(), cents: 6 }, AT).unwrap());
    assert_eq!(revision(), before + 1);
    assert_eq!(state["subjects"][&name]["state"], "painted");
    assert_eq!(spent_today(&state, AT), 6);
    assert!(fs::regular_readonly(&dir, &format!("{name}.jpg")).unwrap().is_some());
}

/// A local stand-in for OpenAI that records each request and answers with the queued replies.
struct Server {
    origin: String,
    requests: Arc<StdMutex<Vec<(String, String, Vec<u8>)>>>,
    _task: tokio::task::JoinHandle<()>,
}

impl Server {
    async fn new(replies: Vec<(u16, String)>) -> Self {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let origin = format!("http://{}", listener.local_addr().unwrap());
        let requests = Arc::new(StdMutex::new(Vec::new()));
        let seen = requests.clone();
        let replies = Arc::new(StdMutex::new(replies.into_iter()));
        let task = tokio::spawn(async move {
            loop {
                let (mut socket, _) = listener.accept().await.unwrap();
                let seen = seen.clone();
                let replies = replies.clone();
                tokio::spawn(async move {
                    let mut head = Vec::new();
                    while !head.ends_with(b"\r\n\r\n") {
                        let Ok(byte) = socket.read_u8().await else { return };
                        head.push(byte);
                    }
                    let head = String::from_utf8(head).unwrap();
                    let length = head
                        .lines()
                        .find_map(|line| {
                            let (name, value) = line.split_once(':')?;
                            name.eq_ignore_ascii_case("content-length").then(|| value.trim().parse::<usize>().unwrap())
                        })
                        .unwrap_or(0);
                    let mut body = vec![0; length];
                    socket.read_exact(&mut body).await.unwrap();
                    let line = head.lines().next().unwrap().to_owned();
                    seen.lock().unwrap().push((line, head, body));
                    let (status, reply) = replies.lock().unwrap().next().unwrap_or((500, String::new()));
                    let response = format!(
                        "HTTP/1.1 {status} X\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{reply}",
                        reply.len()
                    );
                    let _ = socket.write_all(response.as_bytes()).await;
                });
            }
        });
        Self { origin, requests, _task: task }
    }
    fn requests(&self) -> Vec<(String, String, Vec<u8>)> {
        self.requests.lock().unwrap().clone()
    }
}

fn picture_reply() -> String {
    let mut png = std::io::Cursor::new(Vec::new());
    image::RgbaImage::from_pixel(1024, 1024, image::Rgba([240, 230, 210, 255]))
        .write_to(&mut png, image::ImageFormat::Png)
        .unwrap();
    use base64::Engine;
    let encoded = base64::engine::general_purpose::STANDARD.encode(png.into_inner());
    json!({"data":[{"b64_json":encoded}],"usage":{"input_tokens":300,"input_tokens_details":{"text_tokens":300,"image_tokens":0},"output_tokens":2000}}).to_string()
}

fn key() -> Arc<Secret> {
    Arc::new(Secret::new(b"sk-synthetic-test-key-0000000000".to_vec()).unwrap())
}

#[tokio::test]
async fn a_monogram_is_painted_from_house_style_text_alone_and_served_in_the_circle() {
    if isolated() {
        return;
    }
    let _fixture = fixture();
    let _store = crate::credentials::tests::isolated_store(Recording(Arc::new(StdMutex::new(Vec::new()))));
    let server = Server::new(vec![(200, picture_reply())]).await;
    let subject = Subject::Monogram { letter: 'K' };
    let assignments = vec![(id(&["picture-sender", "me@example.org", "kim@gmail.com"]), subject.clone())];
    let due = change(|_, state| assign(state, &id(&["picture-account", "me@example.org"]), &assignments, now())).unwrap();
    let client = reqwest::Client::builder().no_proxy().build().unwrap();
    openai::with_test_transport(client, server.origin.clone(), paint_all(due, key())).await.unwrap();
    let requests = server.requests();
    assert_eq!(requests.len(), 1);
    let (line, head, body) = &requests[0];
    assert_eq!(line, "POST /v1/images/generations HTTP/1.1");
    assert!(head.to_lowercase().contains("authorization: bearer sk-synthetic-test-key-0000000000"));
    let sent: Value = serde_json::from_slice(body).unwrap();
    assert_eq!(sent["model"], MODEL);
    assert_eq!(sent["size"], "1024x1024");
    assert_eq!(sent["quality"], "medium");
    assert_eq!(sent["prompt"], prompts::monogram('K'));
    let text = String::from_utf8_lossy(body);
    assert!(!text.contains("kim") && !text.contains("example.org"));
    let (data, painted_at) = painted("me@example.org", "kim@gmail.com").unwrap().unwrap();
    assert!(data.starts_with("data:image/jpeg;base64,"));
    assert!(painted_at > 0);
    assert!(painted("me@example.org", "other@gmail.com").unwrap().is_none());
    let status = status().await.unwrap();
    assert_eq!(status["painted"], 1);
    assert_eq!(status["present"], false);
    assert_eq!(status["spentTodayCents"], 7);
}

#[tokio::test]
async fn a_logo_edit_sends_only_the_reference_and_the_domain() {
    let server = Server::new(vec![(200, picture_reply())]).await;
    let client = reqwest::Client::builder().no_proxy().build().unwrap();
    let request = openai::Request::Edit { prompt: prompts::logo("acme.example"), reference: b"\x89PNG-reference".to_vec() };
    let painted = openai::with_test_transport(client, server.origin.clone(), openai::paint(&key(), MODEL, &request))
        .await
        .unwrap();
    assert_eq!(painted.cents, 7);
    let requests = server.requests();
    let (line, head, body) = &requests[0];
    assert_eq!(line, "POST /v1/images/edits HTTP/1.1");
    assert!(head.to_lowercase().contains("content-type: multipart/form-data; boundary=----magpieboundary"));
    let text = String::from_utf8_lossy(body);
    assert!(text.contains("name=\"model\"\r\n\r\ngpt-image-2\r\n"));
    assert!(text.contains("Subject: the acme.example brand mark."));
    assert!(text.contains("filename=\"reference.png\"\r\nContent-Type: image/png\r\n\r\n\u{FFFD}PNG-reference\r\n"));
}

#[tokio::test]
async fn a_refused_key_stops_painting_until_the_key_changes() {
    if isolated() {
        return;
    }
    let _fixture = fixture();
    let refusal = r#"{"error":{"code":"invalid_api_key","message":"Incorrect API key provided: sk-synth***"}}"#;
    let server = Server::new(vec![(401, refusal.into()), (401, refusal.into())]).await;
    let subjects = vec![Subject::Monogram { letter: 'A' }, Subject::Monogram { letter: 'B' }];
    let assignments: Vec<_> = subjects.iter().enumerate().map(|(n, subject)| (format!("s{n}"), subject.clone())).collect();
    let due = change(|_, state| assign(state, "owner", &assignments, now())).unwrap();
    let client = reqwest::Client::builder().no_proxy().build().unwrap();
    openai::with_test_transport(client, server.origin.clone(), paint_all(due, key())).await.unwrap();
    assert!(server.requests().len() <= 2);
    let dir = directory(false).unwrap().unwrap();
    let state = read_state(&dir).unwrap();
    assert_eq!(state["problem"], "pictures_key_invalid");
    assert!(state.to_string().find("Incorrect").is_none());
    assert_eq!(spent_today(&state, now()), 0);
    let again = change(|_, state| Ok(reserve(state, now()))).unwrap();
    assert!(!again);
}

struct Recording(Arc<StdMutex<Vec<String>>>);
impl CredentialStore for Recording {
    fn get(&self, _: &CredentialKey) -> Result<Secret, Error> {
        Err(Error::Missing)
    }
    fn put(&self, key: &CredentialKey, secret: &[u8]) -> Result<(), Error> {
        assert_eq!(key, &slot());
        self.0.lock().unwrap().push(String::from_utf8(secret.to_vec()).unwrap());
        Ok(())
    }
    fn delete(&self, _: &CredentialKey) -> Result<(), Error> {
        Err(Error::Missing)
    }
}

#[tokio::test]
async fn a_key_is_saved_only_after_openai_accepts_it() {
    if isolated() {
        return;
    }
    let _fixture = fixture();
    let saved = Arc::new(StdMutex::new(Vec::new()));
    let _store = crate::credentials::tests::isolated_store(Recording(saved.clone()));
    assert_eq!(set_key("not-a-key").await.unwrap_err(), "pictures_key_format");
    assert_eq!(set_key("sk-has spaces-0000000000000000").await.unwrap_err(), "pictures_key_format");
    let server = Server::new(vec![(401, "{}".into()), (200, r#"{"id":"gpt-image-2"}"#.into())]).await;
    let client = reqwest::Client::builder().no_proxy().build().unwrap();
    let origin = server.origin.clone();
    openai::with_test_transport(client, origin, async {
        assert_eq!(set_key("sk-synthetic-test-key-0000000000").await.unwrap_err(), "pictures_key_invalid");
        assert!(saved.lock().unwrap().is_empty());
        let status = set_key("  sk-synthetic-test-key-1111111111\n").await.unwrap();
        assert_eq!(status["model"], MODEL);
        assert!(status.get("key").is_none());
    })
    .await;
    assert_eq!(*saved.lock().unwrap(), vec!["sk-synthetic-test-key-1111111111".to_owned()]);
    let requests = server.requests();
    assert_eq!(requests.len(), 2);
    assert!(requests.iter().all(|(line, _, _)| line == "GET /v1/models/gpt-image-2 HTTP/1.1"));
}
