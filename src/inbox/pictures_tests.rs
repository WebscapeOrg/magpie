use super::*;
use crate::credentials::{CredentialStore, Error};
use crate::mail::tests::{account_fixture, isolated};
use std::sync::Mutex as StdMutex;
use tokio::io::{AsyncReadExt, AsyncWriteExt};

const AT: i64 = 1_793_620_800_000;

fn fixture() -> crate::mail::tests::AccountFixture {
    account_fixture(json!({"version":1,"accounts":[]}))
}

fn person(address: &str, photo: &str) -> Subject {
    Subject::Person { account: "me@example.org".into(), address: address.into(), photo: photo.into() }
}

fn png_data(width: u32, color: [u8; 4]) -> String {
    use base64::Engine;
    let mut png = std::io::Cursor::new(Vec::new());
    image::RgbaImage::from_pixel(width, width, image::Rgba(color)).write_to(&mut png, image::ImageFormat::Png).unwrap();
    format!("data:image/png;base64,{}", base64::engine::general_purpose::STANDARD.encode(png.into_inner()))
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
    let me = "me@example.org";
    assert_eq!(
        subject_for(me, "ann@gmail.com", 'A', &photos),
        person("ann@gmail.com", "https://lh3.googleusercontent.com/a/ann")
    );
    assert_eq!(subject_for(me, "bob@gmail.com", 'B', &photos), Subject::Monogram { letter: 'B' });
    assert_eq!(subject_for(me, "team@acme.example", 'T', &photos), Subject::Organization { domain: "acme.example".into() });
    let one = subject_for(me, "a@acme.example", 'A', &photos).id();
    assert_eq!(one, subject_for(me, "b@acme.example", 'B', &photos).id());
    assert_eq!(one.len(), 64);
    // A contact keeps one picture whatever its photo address; each account has its own.
    let ann = person("ann@gmail.com", "https://lh3.googleusercontent.com/a/ann");
    assert_eq!(ann.id(), person("ann@gmail.com", "https://lh3.googleusercontent.com/a/new").id());
    let elsewhere = Subject::Person { account: "other@example.org".into(), address: "ann@gmail.com".into(), photo: "https://lh3.googleusercontent.com/a/ann".into() };
    assert_ne!(ann.id(), elsewhere.id());
}

#[test]
fn a_company_is_one_picture_across_its_subdomains() {
    let photos = json!({});
    let me = "me@example.org";
    let company = Subject::Organization { domain: "acme.co.uk".into() };
    assert_eq!(subject_for(me, "news@em12.acme.co.uk", 'N', &photos), company);
    assert_eq!(subject_for(me, "billing@acme.co.uk", 'B', &photos), company);
    assert_eq!(subject_for(me, "a@mail.shop.example.com", 'A', &photos), Subject::Organization { domain: "example.com".into() });
    assert_eq!(subject_for(me, "x@co.za", 'X', &photos), Subject::Organization { domain: "co.za".into() });
    // Names under a hosting suffix are free to make, so they share the host's picture.
    let host = Subject::Organization { domain: "github.io".into() };
    assert_eq!(subject_for(me, "a@one.github.io", 'A', &photos), host);
    assert_eq!(subject_for(me, "b@two.github.io", 'B', &photos), host);
    assert_eq!(subject_for(me, "c@deep.acme.example", 'C', &photos), Subject::Organization { domain: "acme.example".into() });
    assert_eq!(subject_for(me, "x@gmail.com", 'X', &photos), Subject::Monogram { letter: 'X' });
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
    let due = change(|_, state| assign(state, "one", &assignments, true, AT)).unwrap();
    assert_eq!(due, vec![(company.clone(), None), (Subject::Monogram { letter: 'Q' }, None)]);
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
    change(|_, state| assign(state, "two", &other, true, AT)).unwrap();
    change(|dir, state| forget(dir, state, &HashSet::from(["two".to_owned()]), AT)).unwrap();
    let dir = directory(false).unwrap().unwrap();
    let state = read_state(&dir).unwrap();
    assert_eq!(state["senders"].as_object().unwrap().len(), 1);
    assert!(state["subjects"].get(company.id()).is_some());
    assert!(state["subjects"].get(&gone).is_none());
    assert!(fs::regular_readonly(&dir, &format!("{gone}.jpg")).unwrap().is_none());
    let again = change(|_, state| assign(state, "two", &other, true, AT)).unwrap();
    assert_eq!(again, vec![(company, None)]);
}

#[test]
fn a_portrait_survives_unknown_contacts_and_an_unused_picture_waits_before_deletion() {
    if isolated() {
        return;
    }
    let _fixture = fixture();
    let ann = person("ann@gmail.com", "https://lh3.googleusercontent.com/a/ann");
    let portrait = ann.id();
    let signed_in = HashSet::from(["one".to_owned()]);
    let due = change(|_, state| assign(state, "one", &[("s1".into(), ann.clone())], true, AT)).unwrap();
    assert_eq!(due, vec![(ann.clone(), None)]);
    change(|dir, state| {
        fs::atomic_replace(dir, &format!("{portrait}.jpg"), b"jpeg")?;
        state["subjects"][&portrait]["state"] = json!("painted");
        state["subjects"][&portrait]["painted"] = json!(AT);
        Ok(())
    })
    .unwrap();
    // Contacts could not be read: the sender keeps the portrait and nothing new is painted.
    let monogram = Subject::Monogram { letter: 'A' };
    let unknown = change(|_, state| assign(state, "one", &[("s1".into(), monogram.clone())], false, AT)).unwrap();
    assert!(unknown.is_empty());
    change(|dir, state| forget(dir, state, &signed_in, AT)).unwrap();
    let dir = directory(false).unwrap().unwrap();
    let state = read_state(&dir).unwrap();
    assert_eq!(state["senders"]["s1"]["subject"], portrait.as_str());
    assert!(state["subjects"].get(monogram.id()).is_none());
    assert!(state["subjects"][&portrait].get("orphaned").is_none());
    // Contacts say Ann has no photo now: she moves to her monogram, and the portrait waits.
    let known = change(|_, state| assign(state, "one", &[("s1".into(), monogram.clone())], true, AT)).unwrap();
    assert_eq!(known, vec![(monogram.clone(), None)]);
    change(|dir, state| forget(dir, state, &signed_in, AT)).unwrap();
    let state = read_state(&dir).unwrap();
    assert_eq!(state["subjects"][&portrait]["orphaned"], AT);
    assert!(fs::regular_readonly(&dir, &format!("{portrait}.jpg")).unwrap().is_some());
    change(|dir, state| forget(dir, state, &signed_in, AT + ORPHAN_KEEP - 1)).unwrap();
    assert!(fs::regular_readonly(&dir, &format!("{portrait}.jpg")).unwrap().is_some());
    change(|dir, state| forget(dir, state, &signed_in, AT + ORPHAN_KEEP)).unwrap();
    let state = read_state(&dir).unwrap();
    assert!(state["subjects"].get(&portrait).is_none());
    assert!(fs::regular_readonly(&dir, &format!("{portrait}.jpg")).unwrap().is_none());
    // A sender missing from the Inbox for 90 days is forgotten.
    change(|dir, state| forget(dir, state, &signed_in, AT + SENDER_KEEP + 86_400_000)).unwrap();
    assert!(read_state(&dir).unwrap()["senders"].get("s1").is_none());
}

#[tokio::test]
async fn a_new_photo_address_with_the_same_pixels_is_not_painted_again() {
    let address = "https://lh3.googleusercontent.com/a/same-pixels";
    let changed = "https://lh3.googleusercontent.com/a/new-pixels";
    TEST_REFERENCES.lock().unwrap().push((address.into(), png_data(64, [200, 120, 80, 255])));
    TEST_REFERENCES.lock().unwrap().push((changed.into(), png_data(64, [20, 120, 180, 255])));
    let fingerprint = digest(&avatars::artwork::reference(&png_data(64, [200, 120, 80, 255])).unwrap());
    let subject = person("pat@gmail.com", address);
    // No local server is set, so any request would fail as lost: Unchanged proves none was made.
    assert!(matches!(paint(&subject, Some(fingerprint.as_str()), &key()).await, Outcome::Unchanged));
    let missing = person("pat@gmail.com", "https://lh3.googleusercontent.com/a/not-supplied");
    assert!(matches!(paint(&missing, None, &key()).await, Outcome::NoReference));
    let server = Server::new(vec![(200, picture_reply())]).await;
    let client = reqwest::Client::builder().no_proxy().build().unwrap();
    let repainted = person("pat@gmail.com", changed);
    let outcome = openai::with_test_transport(client, server.origin.clone(), paint(&repainted, Some(fingerprint.as_str()), &key())).await;
    let Outcome::Painted { reference: Some(new), .. } = outcome else { panic!("a changed photo is painted") };
    assert_ne!(new, fingerprint);
    assert_eq!(server.requests()[0].0, "POST /v1/images/edits HTTP/1.1");
}

#[test]
fn a_changed_photo_is_checked_again_and_keeps_its_picture_until_then() {
    if isolated() {
        return;
    }
    let _fixture = fixture();
    let old = person("pat@gmail.com", "https://lh3.googleusercontent.com/a/old");
    let new = person("pat@gmail.com", "https://lh3.googleusercontent.com/a/new");
    let name = old.id();
    change(|_, state| assign(state, "one", &[("s1".into(), old.clone())], true, AT)).unwrap();
    let dir = directory(true).unwrap().unwrap();
    let mut state = read_state(&dir).unwrap();
    let painted = Outcome::Painted { jpeg: b"jpeg".to_vec(), cents: 6, reference: Some("abc".into()) };
    record(&dir, &mut state, &name, painted, AT, 0).unwrap();
    assert_eq!(state["subjects"][&name]["reference"], "abc");
    assert_eq!(state["subjects"][&name]["photo"], "https://lh3.googleusercontent.com/a/old");
    let due = assign(&mut state, "one", &[("s1".into(), new.clone())], true, AT).unwrap();
    assert_eq!(due, vec![(new.clone(), Some("abc".into()))]);
    assert_eq!(state["subjects"][&name]["state"], "recheck");
    record(&dir, &mut state, &name, Outcome::Unchanged, AT, 0).unwrap();
    assert_eq!(state["subjects"][&name]["state"], "painted");
    assert_eq!(state["subjects"][&name]["painted"], AT);
    // A photo that cannot be fetched three times leaves the current picture in place.
    state["subjects"][&name]["photo"] = json!("https://lh3.googleusercontent.com/a/older");
    assign(&mut state, "one", &[("s1".into(), new.clone())], true, AT).unwrap();
    for _ in 0..ATTEMPTS {
        record(&dir, &mut state, &name, Outcome::NoReference, AT, 0).unwrap();
    }
    assert_eq!(state["subjects"][&name]["state"], "painted");
}

#[test]
fn a_changed_key_stops_a_run_and_its_old_refusal_does_not_count() {
    if isolated() {
        return;
    }
    let _fixture = fixture();
    let mut state = json!({"keyGeneration": 2});
    assert!(!reserve(&mut state, AT, 1));
    assert!(reserve(&mut state, AT, 2));
    let subject = Subject::Monogram { letter: 'G' };
    let name = subject.id();
    state["subjects"] = json!({name.clone(): {"state":"waiting","attempts":0,"kind":"monogram"}});
    let dir = directory(true).unwrap().unwrap();
    let refusal = Outcome::Fault(openai::Fault::Key("pictures_key_invalid"));
    assert!(record(&dir, &mut state, &name, refusal, AT, 1).unwrap());
    assert!(state.get("problem").is_none());
    assert_eq!(spent_today(&state, AT), 0);
    assert_eq!(state["subjects"][&name]["state"], "waiting");
    // Late answers to the old key do not pause the new one.
    for fault in [openai::Fault::Billing, openai::Fault::RateLimited(None), openai::Fault::Model, openai::Fault::Lost { charged: false }] {
        assert!(record(&dir, &mut state, &name, Outcome::Fault(fault), AT, 1).unwrap());
        assert!(state.get("problem").is_none());
        assert!(blocking_problem(&state, AT).is_none());
    }
    assert_eq!(state["subjects"][&name]["attempts"], 1);
    assert!(record(&dir, &mut state, &name, Outcome::Fault(openai::Fault::Billing), AT, 2).unwrap());
    assert_eq!(state["problem"], "pictures_billing");
    // Before the keyring changes, a new generation keeps the pause; afterwards it clears it.
    change(|_, saved| {
        saved["problem"] = json!("pictures_billing");
        saved["retryAt"] = json!(AT + BILLING_WAIT);
        Ok(())
    })
    .unwrap();
    assert_eq!(key_changed(false)().unwrap(), 1);
    assert_eq!(read_state(&dir).unwrap()["problem"], "pictures_billing");
    assert_eq!(key_changed(true)().unwrap(), 2);
    assert!(read_state(&dir).unwrap().get("problem").is_none());
}

#[test]
fn spending_stops_at_the_daily_limit_and_starts_again_the_next_day() {
    let mut state = json!({});
    let mut reserved = 0;
    while reserve(&mut state, AT, 0) {
        reserved += 1;
    }
    assert_eq!(reserved, DAILY_LIMIT_CENTS / openai::ESTIMATE_CENTS);
    assert!(spent_today(&state, AT) <= DAILY_LIMIT_CENTS);
    assert!(reserve(&mut state, AT + 86_400_000, 0));
    assert_eq!(spent_today(&state, AT + 86_400_000), openai::ESTIMATE_CENTS);
    let mut stopped = json!({"problem":"pictures_key_invalid"});
    assert!(!reserve(&mut stopped, AT, 0));
    let mut waiting = json!({"problem":"pictures_rate_limited","retryAt":AT + 1});
    assert!(!reserve(&mut waiting, AT, 0));
    assert!(reserve(&mut waiting, AT + 1, 0));
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
    assert!(!record(&dir, &mut state, &name, Outcome::NoReference, AT, 0).unwrap());
    assert_eq!(state["subjects"][&name]["retryAt"], AT + RETRY_WAITS[0]);
    assert_eq!(spent_today(&state, AT), 0);
    record(&dir, &mut state, &name, Outcome::NoReference, AT, 0).unwrap();
    assert_eq!(state["subjects"][&name]["retryAt"], AT + RETRY_WAITS[1]);
    record(&dir, &mut state, &name, Outcome::NoReference, AT, 0).unwrap();
    assert_eq!(state["subjects"][&name]["state"], "failed");
    assert!(state["subjects"][&name].get("retryAt").is_none());

    setup(&mut state);
    assert!(!record(&dir, &mut state, &name, Outcome::Fault(openai::Fault::Refused), AT, 0).unwrap());
    assert_eq!(state["subjects"][&name]["state"], "waiting");
    assert_eq!(state["subjects"][&name]["reason"], "pictures_refused");
    assert_eq!(state["subjects"][&name]["retryAt"], AT + RETRY_WAITS[0]);
    record(&dir, &mut state, &name, Outcome::Fault(openai::Fault::Refused), AT, 0).unwrap();
    record(&dir, &mut state, &name, Outcome::Fault(openai::Fault::Refused), AT, 0).unwrap();
    assert_eq!(state["subjects"][&name]["state"], "failed");

    setup(&mut state);
    assert!(record(&dir, &mut state, &name, Outcome::Fault(openai::Fault::Key("pictures_key_invalid")), AT, 0).unwrap());
    assert_eq!(blocking_problem(&state, AT + 365 * 86_400_000), Some("pictures_key_invalid"));
    assert_eq!(state["subjects"][&name]["attempts"], 0);
    assert_eq!(spent_today(&state, AT), 0);

    setup(&mut state);
    state.as_object_mut().unwrap().remove("problem");
    assert!(record(&dir, &mut state, &name, Outcome::Fault(openai::Fault::Lost { charged: true }), AT, 0).unwrap());
    assert_eq!(spent_today(&state, AT), openai::ESTIMATE_CENTS);
    assert_eq!(blocking_problem(&state, AT), Some("pictures_unreachable"));
    assert_eq!(blocking_problem(&state, AT + LOST_WAIT), None);
    assert_eq!(state["subjects"][&name]["attempts"], 1);

    setup(&mut state);
    state.as_object_mut().unwrap().remove("problem");
    assert!(record(&dir, &mut state, &name, Outcome::Fault(openai::Fault::RateLimited(Some(5))), AT, 0).unwrap());
    assert_eq!(state["retryAt"], AT + RATE_WAIT);
    setup(&mut state);
    assert!(record(&dir, &mut state, &name, Outcome::Fault(openai::Fault::Billing), AT, 0).unwrap());
    assert_eq!(state["problem"], "pictures_billing");

    setup(&mut state);
    let before = revision();
    assert!(!record(&dir, &mut state, &name, Outcome::Painted { jpeg: b"jpeg".to_vec(), cents: 6, reference: None }, AT, 0).unwrap());
    assert_eq!(revision(), before + 1);
    assert_eq!(state["subjects"][&name]["state"], "painted");
    assert_eq!(spent_today(&state, AT), 6);
    assert!(fs::regular_readonly(&dir, &format!("{name}.jpg")).unwrap().is_some());
}

#[test]
fn rejected_settings_wait_and_a_run_of_them_pauses_painting() {
    if isolated() {
        return;
    }
    let _fixture = fixture();
    let names: Vec<String> = ['A', 'B', 'C', 'D', 'E'].iter().map(|letter| Subject::Monogram { letter: *letter }.id()).collect();
    let mut rows = serde_json::Map::new();
    for name in &names {
        rows.insert(name.clone(), json!({"state":"waiting","attempts":0,"kind":"monogram"}));
    }
    let dir = directory(true).unwrap().unwrap();
    // Each of the twelve requests below reserved the estimate before it was sent.
    let mut state = json!({"subjects": rows, "day": today(AT), "spentCents": 12 * openai::ESTIMATE_CENTS});
    let rejected = || Outcome::Fault(openai::Fault::Rejected);
    let waiting = |state: &Value, name: &str| state["subjects"][name]["state"] == "waiting";

    // Safety refusals belong to their pictures however many come in a row, and never pause painting.
    for name in &names[..3] {
        assert!(!record(&dir, &mut state, name, Outcome::Fault(openai::Fault::Refused), AT, 0).unwrap());
        assert!(waiting(&state, name));
        assert_eq!(state["subjects"][name]["reason"], "pictures_refused");
        assert_eq!(state["subjects"][name]["retryAt"], AT + RETRY_WAITS[0]);
    }
    assert!(blocking_problem(&state, AT).is_none());
    assert!(state.get("refusedRun").is_none());

    // A rejected setting never gives its picture up: it is asked for again a day later. A painted
    // picture ends the run.
    assert!(!record(&dir, &mut state, &names[0], rejected(), AT, 0).unwrap());
    assert!(waiting(&state, &names[0]));
    assert_eq!(state["subjects"][&names[0]]["retryAt"], AT + MODEL_WAIT);
    assert_eq!(state["subjects"][&names[0]]["reason"], "pictures_request_rejected");
    record(&dir, &mut state, &names[1], Outcome::Painted { jpeg: b"jpeg".to_vec(), cents: 2, reference: None }, AT, 0).unwrap();
    assert!(state.get("refusedRun").is_none());

    // An answer to a replaced key leaves the picture as it was and does not count.
    let before = state["subjects"][&names[2]].clone();
    assert!(!record(&dir, &mut state, &names[2], rejected(), AT, 7).unwrap());
    assert_eq!(state["subjects"][&names[2]], before);
    assert!(state.get("refusedRun").is_none());

    // Three in a row pause painting for a day; every picture in the run is still waiting.
    assert!(!record(&dir, &mut state, &names[2], rejected(), AT, 0).unwrap());
    assert!(!record(&dir, &mut state, &names[3], rejected(), AT, 0).unwrap());
    assert!(record(&dir, &mut state, &names[4], rejected(), AT, 0).unwrap());
    assert_eq!(blocking_problem(&state, AT), Some("pictures_request_rejected"));
    assert_eq!(blocking_problem(&state, AT + MODEL_WAIT), None);
    for name in &names[2..] {
        assert!(waiting(&state, name), "{name}");
        assert_eq!(state["subjects"][name]["retryAt"], AT + MODEL_WAIT);
    }
    assert_eq!(state["refusedRun"], json!([]));

    // A late answer from the other request in flight cannot shorten the pause.
    assert!(record(&dir, &mut state, &names[0], Outcome::Fault(openai::Fault::Lost { charged: false }), AT + 1, 0).unwrap());
    assert_eq!(state["problem"], "pictures_request_rejected");
    assert_eq!(state["retryAt"], AT + MODEL_WAIT);
    // A key refusal still replaces it, since it lasts until the key changes.
    assert!(record(&dir, &mut state, &names[0], Outcome::Fault(openai::Fault::Key("pictures_key_invalid")), AT + 2, 0).unwrap());
    assert_eq!(blocking_problem(&state, AT + 2 * MODEL_WAIT), Some("pictures_key_invalid"));
    // And nothing temporary replaces a key refusal.
    record(&dir, &mut state, &names[0], rejected(), AT + 3, 0).unwrap();
    assert_eq!(blocking_problem(&state, AT + 2 * MODEL_WAIT), Some("pictures_key_invalid"));

    // Refunded requests are not paid for; only the painted picture is.
    assert_eq!(spent_today(&state, AT), 2);
}

/// A local stand-in for OpenAI that records each request and answers with the queued replies.
/// A request line, its head and its body.
type Seen = (String, String, Vec<u8>);

struct Server {
    origin: String,
    requests: Arc<StdMutex<Vec<Seen>>>,
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
    fn requests(&self) -> Vec<Seen> {
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
    let due = change(|_, state| assign(state, &id(&["picture-account", "me@example.org"]), &assignments, true, now())).unwrap();
    let client = reqwest::Client::builder().no_proxy().build().unwrap();
    openai::with_test_transport(client, server.origin.clone(), paint_all(due, key(), 0)).await.unwrap();
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
    let (subject_name, painted_at) = painted("me@example.org", "kim@gmail.com").unwrap().unwrap();
    assert_eq!(subject_name, subject.id());
    let data = picture(&subject_name).unwrap().unwrap();
    assert!(data.starts_with("data:image/jpeg;base64,"));
    assert!(picture("../state").unwrap().is_none());
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
    assert!(text.contains("name=\"model\"\r\n\r\ngpt-image-2.5-sunburst\r\n"));
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
    let subjects = [Subject::Monogram { letter: 'A' }, Subject::Monogram { letter: 'B' }];
    let assignments: Vec<_> = subjects.iter().enumerate().map(|(n, subject)| (format!("s{n}"), subject.clone())).collect();
    let due = change(|_, state| assign(state, "owner", &assignments, true, now())).unwrap();
    let client = reqwest::Client::builder().no_proxy().build().unwrap();
    openai::with_test_transport(client, server.origin.clone(), paint_all(due, key(), 0)).await.unwrap();
    assert!(server.requests().len() <= 2);
    let dir = directory(false).unwrap().unwrap();
    let state = read_state(&dir).unwrap();
    assert_eq!(state["problem"], "pictures_key_invalid");
    assert!(state.to_string().find("Incorrect").is_none());
    assert_eq!(spent_today(&state, now()), 0);
    let again = change(|_, state| Ok(reserve(state, now(), 0))).unwrap();
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
    let server = Server::new(vec![(401, "{}".into()), (200, r#"{"id":"gpt-image-2.5-sunburst"}"#.into())]).await;
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
    // The key generation moved before and after the keyring changed.
    let dir = directory(false).unwrap().unwrap();
    assert_eq!(read_state(&dir).unwrap()["keyGeneration"], 2);
    let requests = server.requests();
    assert_eq!(requests.len(), 2);
    assert!(requests.iter().all(|(line, _, _)| line == "GET /v1/models/gpt-image-2.5-sunburst HTTP/1.1"));
}

#[test]
fn prepared_painted_avatars_of_removed_accounts_are_deleted() {
    if isolated() {
        return;
    }
    let _fixture = fixture();
    let rows = [
        ("avatar-kept", json!({"source":"painted","owner":"me@example.org","data":"x"})),
        ("avatar-gone", json!({"source":"painted","owner":"gone@example.org","data":"x"})),
        ("avatar-contact", json!({"source":"contact","owner":"gone@example.org","data":"x"})),
    ];
    for (name, value) in &rows {
        super::super::store::cache(name, value).unwrap();
    }
    avatars::forget_painted(&["me@example.org".to_owned()]).unwrap();
    assert!(super::super::store::read("avatar-kept").unwrap().is_some());
    assert!(super::super::store::read("avatar-gone").unwrap().is_none());
    assert!(super::super::store::read("avatar-contact").unwrap().is_some());
    avatars::forget_painted(&[]).unwrap();
    assert!(super::super::store::read("avatar-kept").unwrap().is_none());
}
