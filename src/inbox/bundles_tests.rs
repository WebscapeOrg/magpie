//! Bundles: every check the engine makes on what the writer proposes, with made-up mail in the
//! shape Gmail gives. Nothing reaches Google, Anthropic or OpenAI.
use super::super::{POINT_REVISION, describe, point_context, store};
use super::*;
use crate::mail::tests::{AccountFixture, account_fixture, isolated};
use crate::providers::gmail;
use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use std::sync::Arc;

const ACCOUNT: &str = "owner@example.test";
const OTHER: &str = "second@example.test";
const HOUR: i64 = 3_600_000;

fn gmail_says(domain: &str) -> String {
    format!(
        "mx.google.com;\r\n       dkim=pass header.i=@{domain} header.s=google header.b=abc;\r\n       spf=pass (google.com: domain of bounce@{domain} designates 192.0.2.1 as permitted sender) smtp.mailfrom=bounce@{domain};\r\n       dmarc=pass (p=REJECT sp=REJECT dis=NONE) header.from={domain}"
    )
}

fn mail(id: &str, thread: &str, date: i64, from: &str, auth: Option<&str>, labels: &[&str], subject: &str) -> Value {
    let body = format!("{subject}. This is a synthetic message body.");
    let mut headers = vec![json!({"name":"Delivered-To","value":ACCOUNT})];
    if let Some(auth) = auth {
        headers.push(json!({"name":"Authentication-Results","value":auth}));
    }
    headers.push(json!({"name":"From","value":from}));
    headers.push(json!({"name":"To","value":ACCOUNT}));
    headers.push(json!({"name":"Subject","value":subject}));
    json!({"id":id,"threadId":thread,"internalDate":date.to_string(),"labelIds":labels,"snippet":subject,
        "payload":{"mimeType":"text/plain","headers":headers,"body":{"data":URL_SAFE_NO_PAD.encode(&body),"size":body.len()}}})
}

const NOW: i64 = 1_790_000_000_000;
const ROBOT: &str = "UptimeRobot <alert@uptimerobot.example>";

fn down(id: &str, at: i64) -> Value {
    mail(id, id, at, ROBOT, Some(&gmail_says("uptimerobot.example")), &["INBOX", "UNREAD"], "Monitor is DOWN: example.com")
}

fn up(id: &str, at: i64) -> Value {
    mail(id, id, at, ROBOT, Some(&gmail_says("uptimerobot.example")), &["INBOX", "UNREAD"], "Monitor is UP: example.com back after 3 minutes")
}

fn quote() -> Value {
    json!("monitor is down: example.com")
}

struct World {
    _fixture: AccountFixture,
    gmail: Arc<gmail::Session>,
    local: Arc<LocalMail>,
}

impl World {
    fn new() -> Self {
        let fixture = account_fixture(json!({"version":1,"accounts":[{"provider":"gmail","email":ACCOUNT},{"provider":"gmail","email":OTHER}]}));
        Self { _fixture: fixture, gmail: Arc::new(gmail::Session::default()), local: Arc::new(LocalMail::default()) }
    }

    async fn seed(&self, account: &str, resource: &Value) {
        crate::cache::resource::put(account, resource["id"].as_str().unwrap(), resource).await.unwrap();
        self.local.read(account, resource["id"].as_str().unwrap(), &self.gmail).await.unwrap();
    }

    async fn seed_point(&self, account: &str, resource: &Value, extra: Value) {
        self.seed(account, resource).await;
        let id = resource["id"].as_str().unwrap().to_owned();
        store::update(&store::key(&["overviews", account]), |saved| {
            let mut row = json!({"state":"ready","text":"Went down, no recovery notice yet.","version":2,"promptRevision":POINT_REVISION,"updated":now(),"expiresAt":0});
            for (key, value) in extra.as_object().into_iter().flatten() {
                row[key] = value.clone();
            }
            saved[id.as_str()] = row;
            Ok(())
        })
        .unwrap();
    }

    /// The context the writer would have been given, read through the real Inbox listing.
    async fn context(&self) -> Value {
        let mut inbox = Vec::new();
        for account in [ACCOUNT, OTHER] {
            inbox.extend(point_context::listed(&self.local, account, "in:inbox", 40).await);
        }
        let mut context = json!({"inbox":inbox});
        add_points(&mut context);
        context
    }

    /// Runs `newer` through the writer's answer with `covers`, and reads the Inbox after it.
    async fn write(&self, newer: &Value, covers: Value) -> Value {
        self.write_with_context(ACCOUNT, newer, covers, self.context().await).await
    }

    async fn write_with_context(&self, account: &str, newer: &Value, covers: Value, context: Value) -> Value {
        self.seed(account, newer).await;
        let id = newer["id"].as_str().unwrap();
        let answer = json!({"overviews":[{"id":id,"text":"Back up after 3 minutes.","evidence":[{"source":"mail","quote":newer["payload"]["headers"][2]["value"].as_str().map(|_| "Monitor is").unwrap_or("Monitor")}],"covers":covers}]});
        let mut message = super::super::overview_message(id, newer).unwrap();
        message["owner"] = json!(account);
        let rows = describe::validate(&answer, &json!([message]), &context).unwrap();
        let token = crate::account::with_incarnation(None, Ok).unwrap();
        record(account, &rows, &token, &self.local).await;
        list_settled(account, &self.local).await.unwrap()
    }

    async fn list(&self, account: &str) -> Value {
        list_settled(account, &self.local).await.unwrap()
    }

    fn covers(&self, older: &str) -> Value {
        json!([{"id":older,"quote":quote()}])
    }

    async fn inbox_call(&self, method: &str, params: Value) -> Result<Value, &'static str> {
        super::call(method, &params, &self.local).await
    }
}

fn assert_separate(view: &Value, why: &str) {
    assert_eq!(view["bundles"], json!([]), "{why}: {view}");
    assert_eq!(view["proposals"], json!([]), "{why}: {view}");
}

fn assert_bundle(view: &Value, front: &str, covered: &[&str]) {
    assert_eq!(view["bundles"], json!([{"front":front,"covered":covered}]), "{view}");
    assert_eq!(view["proposals"], json!([]), "{view}");
}

#[tokio::test]
async fn the_uptimerobot_pair_writes_end_to_end_into_one_bundle_with_the_points_after_the_cache_point() {
    if isolated() {
        return;
    }
    let world = World::new();
    let older = down("down-1", NOW - HOUR);
    world.seed_point(ACCOUNT, &older, json!({})).await;
    let newer = up("up-1", NOW);
    world.seed(ACCOUNT, &newer).await;
    let context = world.context().await;
    let mut message = super::super::overview_message("up-1", &newer).unwrap();
    message["owner"] = json!(ACCOUNT);
    let messages = json!([message]);
    let answer = json!({"overviews":[{"id":"up-1","text":"Back up after 3 minutes.","evidence":[{"source":"mail","quote":"Monitor is UP"}],"until":null,"timeSensitive":false,"covers":[{"id":"down-1","quote":"Monitor is DOWN: example.com"}]}]});
    let mut shared = Vec::new();
    let mut tasks = Vec::new();
    let rows = describe::generate_with(&messages, &context, false, |prompt| {
        shared.push(prompt.shared);
        tasks.push(prompt.task);
        std::future::ready(Ok(answer.clone()))
    })
    .await
    .unwrap();
    assert_eq!(tasks.len(), 1, "a good answer is not repaired");
    assert!(tasks[0].contains("Went down, no recovery notice yet."), "the older mail's Point travels with the task");
    assert!(!shared[0].contains("Went down, no recovery notice yet."), "and stays out of the cached part");
    assert_eq!(rows[0]["covers"], json!([{"id":"down-1","quote":"Monitor is DOWN: example.com"}]));
    let token = crate::account::with_incarnation(None, Ok).unwrap();
    record(ACCOUNT, &rows, &token, &world.local).await;
    assert_bundle(&world.list(ACCOUNT).await, "up-1", &["down-1"]);
}

#[tokio::test]
async fn a_bad_covers_entry_loses_only_that_entry_and_never_fails_the_row_or_asks_for_a_repair() {
    if isolated() {
        return;
    }
    let world = World::new();
    let older = down("down-1", NOW - HOUR);
    world.seed_point(ACCOUNT, &older, json!({})).await;
    let newer = up("up-1", NOW);
    world.seed(ACCOUNT, &newer).await;
    let context = world.context().await;
    let mut message = super::super::overview_message("up-1", &newer).unwrap();
    message["owner"] = json!(ACCOUNT);
    let answer = json!({"overviews":[{"id":"up-1","text":"Back up after 3 minutes.","evidence":[{"source":"mail","quote":"Monitor is UP"}],"covers":[{"id":"no-such-mail","quote":"nothing like this anywhere"},{"id":"down-1","quote":"Monitor is DOWN: example.com"},{"quote":"no id"},"not an object"]}]});
    let mut calls = 0;
    let rows = describe::generate_with(&json!([message]), &context, false, |_| {
        calls += 1;
        std::future::ready(Ok(answer.clone()))
    })
    .await
    .unwrap();
    assert_eq!(calls, 1, "no repair pass");
    assert_eq!(rows[0]["text"], "Back up after 3 minutes.");
    assert_eq!(rows[0]["covers"], json!([{"id":"down-1","quote":"Monitor is DOWN: example.com"}]), "only the good entry stays");
}

#[test]
fn no_context_means_no_covers() {
    let answer = json!({"overviews":[{"id":"a","text":"Back up.","evidence":"Monitor is UP","covers":[{"id":"down-1","quote":"Monitor is DOWN: example.com"}]}]});
    let messages = json!([{"id":"a","owner":ACCOUNT,"date":"2026-11-09T10:00:00.000Z","body":"Monitor is UP"}]);
    assert!(describe::validate(&answer, &messages, &json!({})).unwrap()[0].get("covers").is_none());
}

#[tokio::test]
async fn another_accounts_mail_is_refused_even_when_the_id_exists_in_both() {
    if isolated() {
        return;
    }
    let world = World::new();
    // The same message number in both accounts: the other account's mail is the one shown.
    world.seed_point(OTHER, &down("shared-id", NOW - HOUR), json!({})).await;
    let newer = up("up-1", NOW);
    let view = world.write(&newer, world.covers("shared-id")).await;
    assert_separate(&view, "another account's mail");
    // And when this account also holds that id but only the other account's copy was shown.
    let mine = down("shared-id", NOW - HOUR);
    world.seed_point(ACCOUNT, &mine, json!({})).await;
    let mut context = world.context().await;
    context["inbox"].as_array_mut().unwrap().retain(|entry| entry["account"] == OTHER);
    context["inboxPoints"].as_array_mut().unwrap().retain(|entry| entry["account"] == OTHER);
    let view = world.write_with_context(ACCOUNT, &newer, world.covers("shared-id"), context).await;
    assert_separate(&view, "the id matched only by the other account's copy");
}

#[tokio::test]
async fn a_quote_from_the_other_accounts_copy_of_the_same_id_is_refused() {
    if isolated() {
        return;
    }
    let world = World::new();
    world.seed_point(OTHER, &down("shared-id", NOW - HOUR), json!({})).await;
    let mine = mail("shared-id", "shared-id", NOW - HOUR, ROBOT, Some(&gmail_says("uptimerobot.example")), &["INBOX", "UNREAD"], "Unrelated invoice for October");
    world.seed_point(ACCOUNT, &mine, json!({})).await;
    let mut context = world.context().await;
    // Both copies are shown and this account's has a Point; the other account's copy comes first.
    context["inbox"].as_array_mut().unwrap().sort_by_key(|entry| entry["account"] != OTHER);
    assert_eq!(context["inbox"][0]["account"], OTHER);
    let newer = up("up-1", NOW);
    let view = world.write_with_context(ACCOUNT, &newer, world.covers("shared-id"), context.clone()).await;
    assert_separate(&view, "a quote that only the other account's copy contains");
    let own_quote = json!([{"id":"shared-id","quote":"unrelated invoice for october"}]);
    let view = world.write_with_context(ACCOUNT, &newer, own_quote, context).await;
    assert_bundle(&view, "up-1", &["shared-id"]);
}

#[tokio::test]
async fn a_date_in_the_writers_context_never_outweighs_the_date_in_gmails_copy() {
    if isolated() {
        return;
    }
    let world = World::new();
    world.seed_point(ACCOUNT, &down("equal", NOW), json!({})).await;
    world.seed_point(ACCOUNT, &down("newer-than-front", NOW + HOUR), json!({})).await;
    let newer = up("up-1", NOW);
    let mut context = world.context().await;
    for entry in context["inbox"].as_array_mut().unwrap() {
        entry["date"] = json!("2000-01-01T00:00:00Z");
    }
    let view = world.write_with_context(ACCOUNT, &newer, world.covers("equal"), context.clone()).await;
    assert_separate(&view, "the same time in Gmail's copy");
    let view = world.write_with_context(ACCOUNT, &newer, world.covers("newer-than-front"), context).await;
    assert_separate(&view, "later than the front in Gmail's copy");
}

#[tokio::test]
async fn a_mail_not_shown_the_mail_itself_and_a_bad_or_trivial_quote_are_refused() {
    if isolated() {
        return;
    }
    let world = World::new();
    let older = down("down-1", NOW - HOUR);
    world.seed_point(ACCOUNT, &older, json!({})).await;
    let newer = up("up-1", NOW);
    let context = world.context().await;
    let mut hidden = context.clone();
    hidden["inbox"].as_array_mut().unwrap().retain(|entry| entry["id"] != "down-1");
    assert_separate(&world.write_with_context(ACCOUNT, &newer, world.covers("down-1"), hidden).await, "a mail not shown");
    assert_separate(&world.write(&newer, json!([{"id":"up-1","quote":"Monitor is UP: example.com"}])).await, "the mail itself");
    for bad in ["Monitor went away for a while", "", "ok", "is DOWN", "example.com", "Monitor is DOWN: other.example"] {
        assert_separate(&world.write(&newer, json!([{"id":"down-1","quote":bad}])).await, bad);
    }
    assert_bundle(&world.write(&newer, world.covers("down-1")).await, "up-1", &["down-1"]);
}

#[tokio::test]
async fn at_most_five_mails_are_covered_by_one_answer() {
    if isolated() {
        return;
    }
    let world = World::new();
    let mut covers = Vec::new();
    for index in 0..7 {
        let id = format!("down-{index}");
        world.seed_point(ACCOUNT, &down(&id, NOW - HOUR * (index + 1)), json!({})).await;
        covers.push(json!({"id":id,"quote":quote()}));
    }
    let view = world.write(&up("up-1", NOW), json!(covers)).await;
    let covered = view["bundles"][0]["covered"].as_array().unwrap();
    assert_eq!(covered.len(), 5, "{view}");
    for not_covered in ["down-5", "down-6"] {
        assert!(!covered.iter().any(|id| id == not_covered), "{view}");
    }
}

#[tokio::test]
async fn older_mail_must_be_strictly_older_by_gmails_date_and_have_a_point_written_under_todays_rules() {
    if isolated() {
        return;
    }
    let world = World::new();
    world.seed_point(ACCOUNT, &down("equal", NOW), json!({})).await;
    world.seed_point(ACCOUNT, &down("no-point", NOW - HOUR), json!({"state":"failed"})).await;
    world.seed_point(ACCOUNT, &down("old-rules", NOW - HOUR), json!({"promptRevision":POINT_REVISION - 1})).await;
    let newer = up("up-1", NOW);
    assert_separate(&world.write(&newer, world.covers("equal")).await, "equal dates");
    assert_separate(&world.write(&newer, world.covers("no-point")).await, "no stored Point");
    assert_separate(&world.write(&newer, world.covers("old-rules")).await, "a Point written before today's rules");
    world.seed_point(ACCOUNT, &down("newer-than-front", NOW + HOUR), json!({})).await;
    assert_separate(&world.write(&newer, world.covers("newer-than-front")).await, "mail newer than the front");
}

#[tokio::test]
async fn a_faked_sender_is_never_automatic() {
    if isolated() {
        return;
    }
    let world = World::new();
    let older = down("down-1", NOW - HOUR);
    world.seed_point(ACCOUNT, &older, json!({})).await;
    let added_by_someone_else = "relay.evil.example; dmarc=pass header.from=uptimerobot.example";
    let wrong_domain = gmail_says("evil.example");
    let forged_second = gmail_says("uptimerobot.example");
    for (name, auth, also) in [
        ("added by a non-Gmail server", Some(added_by_someone_else), None),
        ("a pass for a non-aligned domain", Some(wrong_domain.as_str()), None),
        ("a missing header", None, None),
        ("a forged second result", Some(forged_second.as_str()), Some(forged_second.as_str())),
    ] {
        let mut fake = mail("fake-1", "fake-1", NOW, ROBOT, auth, &["INBOX"], "Monitor is UP: example.com");
        if let Some(extra) = also {
            fake["payload"]["headers"].as_array_mut().unwrap().push(json!({"name":"Authentication-Results","value":extra}));
        }
        assert_separate(&world.write(&fake, world.covers("down-1")).await, name);
    }
    // The newer mail really is from UptimeRobot, but the older one is not proven.
    let mut unproven = down("old-unproven", NOW - HOUR);
    unproven["payload"]["headers"].as_array_mut().unwrap().retain(|header| header["name"] != "Authentication-Results");
    world.seed_point(ACCOUNT, &unproven, json!({})).await;
    let view = world.write(&up("up-1", NOW), world.covers("old-unproven")).await;
    assert_eq!(view["bundles"], json!([]), "a proven newer mail never automatically hides an unproven older one: {view}");
    assert_eq!(view["proposals"], json!([]), "a tap could never bundle it, so it is not offered: {view}");
}

#[tokio::test]
async fn a_differing_display_name_or_reply_to_is_not_the_same_sender() {
    if isolated() {
        return;
    }
    let world = World::new();
    world.seed_point(ACCOUNT, &down("down-1", NOW - HOUR), json!({})).await;
    let other_name = mail("named", "named", NOW, "UptimeRobot Billing <alert@uptimerobot.example>", Some(&gmail_says("uptimerobot.example")), &["INBOX"], "Monitor is UP: example.com");
    let view = world.write(&other_name, world.covers("down-1")).await;
    assert_eq!(view["bundles"], json!([]), "{view}");
    assert_eq!(view["proposals"].as_array().unwrap().len(), 1, "a differing display name asks: {view}");
    world.inbox_call("inbox.refuseBundle", json!({"accountId":ACCOUNT,"ids":["down-1"]})).await.unwrap();
    world.seed_point(ACCOUNT, &down("down-2", NOW - HOUR), json!({})).await;
    let mut reply_to = up("reply-to", NOW);
    reply_to["payload"]["headers"].as_array_mut().unwrap().push(json!({"name":"Reply-To","value":"attacker@example.test"}));
    let view = world.write(&reply_to, world.covers("down-2")).await;
    assert_eq!(view["bundles"], json!([]), "a differing Reply-To is not automatic: {view}");
}

#[tokio::test]
async fn a_reply_into_someone_elses_conversation_does_not_bundle() {
    if isolated() {
        return;
    }
    let world = World::new();
    let alice = mail("alice-1", "thread-1", NOW - HOUR, "Alice <alice@example.test>", Some(&gmail_says("example.test")), &["INBOX"], "Monitor is DOWN: example.com");
    world.seed_point(ACCOUNT, &alice, json!({})).await;
    let stranger = mail("evil-1", "thread-1", NOW, "Mallory <mallory@evil.example>", Some(&gmail_says("evil.example")), &["INBOX"], "Monitor is UP: example.com");
    let view = world.write(&stranger, world.covers("alice-1")).await;
    assert_eq!(view["bundles"], json!([]), "one Gmail conversation is not one sender: {view}");
    assert_eq!(view["proposals"].as_array().unwrap().len(), 1, "a stranger in front waits for approval: {view}");
}

#[tokio::test]
async fn an_unproven_stranger_in_front_is_not_even_offered() {
    if isolated() {
        return;
    }
    let world = World::new();
    world.seed_point(ACCOUNT, &down("down-1", NOW - HOUR), json!({})).await;
    let stranger = mail("stranger-1", "stranger-1", NOW, "Stranger <x@evil.example>", None, &["INBOX"], "Monitor is UP: example.com");
    assert_separate(&world.write(&stranger, world.covers("down-1")).await, "an unproven stranger");
}

#[tokio::test]
async fn mail_that_may_never_be_hidden_stays_separate_whatever_the_ai_says() {
    if isolated() {
        return;
    }
    let world = World::new();
    world.local.test_set_label_name(ACCOUNT, "Label_returned", RETURNED_LABEL).await.unwrap();
    let older = |id: &str| down(id, NOW - HOUR);
    let mut with_attachment = older("attachment");
    with_attachment["payload"] = json!({"mimeType":"multipart/mixed","headers":with_attachment["payload"]["headers"],"parts":[{"mimeType":"text/plain","body":{"data":URL_SAFE_NO_PAD.encode("Monitor is DOWN: example.com"),"size":28}},{"mimeType":"application/pdf","filename":"report.pdf","headers":[{"name":"Content-Disposition","value":"attachment; filename=report.pdf"}],"body":{"attachmentId":"A1","size":100}}]});
    let mut invitation_mail = older("invitation");
    invitation_mail["payload"] = json!({"mimeType":"multipart/alternative","headers":invitation_mail["payload"]["headers"],"parts":[{"mimeType":"text/plain","body":{"data":URL_SAFE_NO_PAD.encode("Monitor is DOWN: example.com"),"size":28}},{"mimeType":"text/calendar","body":{"data":URL_SAFE_NO_PAD.encode("BEGIN:VCALENDAR"),"size":15}}]});
    let mut starred = older("starred");
    starred["labelIds"] = json!(["INBOX", "STARRED"]);
    let mut draft = older("draft");
    draft["labelIds"] = json!(["INBOX", "DRAFT"]);
    let mut sent = older("sent");
    sent["labelIds"] = json!(["INBOX", "SENT"]);
    let from_owner = mail("own", "own", NOW - HOUR, &format!("Me <{ACCOUNT}>"), Some(&gmail_says("example.test")), &["INBOX"], "Monitor is DOWN: example.com");
    let from_other_account = mail("other-account", "other-account", NOW - HOUR, &format!("Me <{OTHER}>"), Some(&gmail_says("example.test")), &["INBOX"], "Monitor is DOWN: example.com");
    let mut returned = older("returned");
    returned["labelIds"] = json!(["INBOX", "Label_returned"]);
    for (id, resource, extra) in [
        ("starred", starred, json!({})),
        ("draft", draft, json!({})),
        ("sent", sent, json!({})),
        ("own", from_owner, json!({})),
        ("other-account", from_other_account, json!({})),
        ("attachment", with_attachment, json!({})),
        ("invitation", invitation_mail, json!({})),
        ("returned", returned, json!({})),
        ("deadline", older("deadline"), json!({"untilAt":now() + 86_400_000})),
    ] {
        world.seed_point(ACCOUNT, &resource, extra).await;
        assert_separate(&world.write(&up(&format!("up-{id}"), NOW + 1), world.covers(id)).await, id);
    }
    // A Point whose end date has passed, or which only expires at midnight, does not stop the bundle.
    world.seed_point(ACCOUNT, &older("past"), json!({"untilAt":now() - 1, "expiresAt":now() + HOUR})).await;
    assert_bundle(&world.write(&up("up-past", NOW + 1), world.covers("past")).await, "up-past", &["past"]);
    // A linked todo, by the mail's thread or its Gmail id.
    let at = now();
    store::write(&store::key(&["todos", "atlas"]), &json!({"read":at - 60_000,"links":{"t:todo-thread":["7:open"],"g:by-id":["8:open"]}})).unwrap();
    let mut by_thread = older("by-thread");
    by_thread["threadId"] = json!("todo-thread");
    world.seed_point(ACCOUNT, &by_thread, json!({})).await;
    world.seed_point(ACCOUNT, &older("by-id"), json!({})).await;
    let view = world.write(&up("up-todo", NOW + 2), json!([{"id":"by-thread","quote":quote()},{"id":"by-id","quote":quote()}])).await;
    assert_eq!(view["bundles"], json!([{"front":"up-past","covered":["past"]}]), "linked todos stay separate: {view}");
    // An unsent reply draft in the older mail's thread.
    let thread_draft = mail("reply-draft", "draft-thread", NOW, &format!("Me <{ACCOUNT}>"), None, &["DRAFT"], "Re: monitor");
    world.seed(ACCOUNT, &thread_draft).await;
    let mut in_thread = older("has-draft");
    in_thread["threadId"] = json!("draft-thread");
    world.seed_point(ACCOUNT, &in_thread, json!({})).await;
    let view = world.write(&up("up-draft", NOW + 3), world.covers("has-draft")).await;
    assert_eq!(view["bundles"], json!([{"front":"up-past","covered":["past"]}]), "a reply draft stays separate: {view}");
}

#[tokio::test]
async fn a_hidden_mail_that_is_starred_later_comes_back() {
    if isolated() {
        return;
    }
    let world = World::new();
    world.seed_point(ACCOUNT, &down("down-1", NOW - HOUR), json!({})).await;
    assert_bundle(&world.write(&up("up-1", NOW), world.covers("down-1")).await, "up-1", &["down-1"]);
    world.local.test_set_labels(ACCOUNT, "down-1", json!(["INBOX", "STARRED"])).await.unwrap();
    assert_separate(&world.list(ACCOUNT).await, "starred after bundling");
    assert_eq!(store::read(&store::key(&["overviews", ACCOUNT])).unwrap().unwrap()["down-1"]["contextChanged"], true);
}

#[tokio::test]
async fn one_mail_claimed_by_two_newer_mails_goes_behind_the_newest() {
    if isolated() {
        return;
    }
    let world = World::new();
    world.seed_point(ACCOUNT, &down("down-1", NOW - HOUR), json!({})).await;
    world.write(&up("up-newer", NOW), world.covers("down-1")).await;
    let view = world.write(&up("up-older", NOW - 1), world.covers("down-1")).await;
    assert_bundle(&view, "up-newer", &["down-1"]);
}

#[tokio::test]
async fn a_chain_of_follow_ups_is_flattened_into_one_bundle() {
    if isolated() {
        return;
    }
    let world = World::new();
    world.seed_point(ACCOUNT, &down("a", NOW - 3 * HOUR), json!({})).await;
    world.write(&down("b", NOW - 2 * HOUR), world.covers("a")).await;
    world.seed_point(ACCOUNT, &down("b", NOW - 2 * HOUR), json!({})).await;
    let view = world.write(&up("c", NOW), json!([{"id":"b","quote":quote()}])).await;
    assert_bundle(&view, "c", &["b", "a"]);
    assert_eq!(view["bundles"].as_array().unwrap().len(), 1);
}

#[tokio::test]
async fn a_stranger_goes_in_front_of_someone_elses_mail_only_after_approval_and_approval_is_then_lasting() {
    if isolated() {
        return;
    }
    let world = World::new();
    world.seed_point(ACCOUNT, &down("alice", NOW - 2 * HOUR), json!({})).await;
    let front = mail("carrier-1", "carrier-1", NOW, "Courier <news@courier.example>", Some(&gmail_says("courier.example")), &["INBOX"], "Monitor is UP: example.com");
    let view = world.write(&front, world.covers("alice")).await;
    assert_eq!(view["bundles"], json!([]), "not without approval: {view}");
    assert_eq!(view["proposals"], json!([{"front":"carrier-1","covered":["alice"],"sender":{"email":"news@courier.example","name":"Courier"}}]));
    assert_eq!(world.inbox_call("inbox.approvedSenders", json!({})).await.unwrap(), json!({"senders":[]}));
    let view = world.inbox_call("inbox.approveBundle", json!({"accountId":ACCOUNT,"front":"carrier-1"})).await.unwrap();
    assert_bundle(&view, "carrier-1", &["alice"]);
    let listed = world.inbox_call("inbox.approvedSenders", json!({})).await.unwrap();
    assert_eq!(listed["senders"][0]["email"], "news@courier.example");
    // From now on the same proven sender covers someone else's mail without asking.
    world.seed_point(ACCOUNT, &down("bob", NOW - HOUR), json!({})).await;
    let next = mail("carrier-2", "carrier-2", NOW + HOUR, "Courier <news@courier.example>", Some(&gmail_says("courier.example")), &["INBOX"], "Monitor is UP: example.com");
    let view = world.write(&next, world.covers("bob")).await;
    assert_eq!(view["bundles"].as_array().unwrap().len(), 2, "{view}");
    // Removed from the set, and the next such mail waits for approval again.
    let removed = world.inbox_call("inbox.removeApprovedSender", json!({"email":"news@courier.example","name":"Courier"})).await.unwrap();
    assert_eq!(removed["senders"], json!([]));
    world.seed_point(ACCOUNT, &down("carol", NOW - HOUR), json!({})).await;
    let third = mail("carrier-3", "carrier-3", NOW + 2 * HOUR, "Courier <news@courier.example>", Some(&gmail_says("courier.example")), &["INBOX"], "Monitor is UP: example.com");
    let view = world.write(&third, world.covers("carol")).await;
    assert_eq!(view["proposals"].as_array().unwrap().len(), 1, "{view}");
}

#[tokio::test]
async fn an_approved_sender_hides_only_mail_gmail_proved_and_offers_nothing_it_could_not_bundle() {
    if isolated() {
        return;
    }
    let world = World::new();
    let courier = |id: &str, at: i64| mail(id, id, at, "Courier <news@courier.example>", Some(&gmail_says("courier.example")), &["INBOX"], "Monitor is UP: example.com");
    world.seed_point(ACCOUNT, &down("alice", NOW - 2 * HOUR), json!({})).await;
    world.write(&courier("carrier-1", NOW), world.covers("alice")).await;
    world.inbox_call("inbox.approveBundle", json!({"accountId":ACCOUNT,"front":"carrier-1"})).await.unwrap();
    let mut unproven = down("no-proof", NOW - HOUR);
    unproven["payload"]["headers"].as_array_mut().unwrap().retain(|header| header["name"] != "Authentication-Results");
    world.seed_point(ACCOUNT, &unproven, json!({})).await;
    let two = mail("two-senders", "two-senders", NOW - HOUR, "A <a@x.example>, B <b@y.example>", Some(&gmail_says("x.example")), &["INBOX"], "Monitor is DOWN: example.com");
    world.seed_point(ACCOUNT, &two, json!({})).await;
    let view = world.write(&courier("carrier-2", NOW + HOUR), json!([{"id":"no-proof","quote":quote()},{"id":"two-senders","quote":quote()}])).await;
    assert_eq!(view["bundles"], json!([{"front":"carrier-1","covered":["alice"]}]), "{view}");
    assert_eq!(view["proposals"], json!([]), "a tap could never bundle these, so no tap is offered: {view}");
    let again = world.list(ACCOUNT).await;
    assert_eq!(again["bundles"], view["bundles"], "a later list never makes them automatic: {again}");
    assert_eq!(again["proposals"], json!([]), "{again}");
}

#[tokio::test]
async fn while_the_todo_list_is_unknown_nothing_is_hidden_and_the_record_is_kept() {
    if isolated() {
        return;
    }
    let world = World::new();
    world.seed_point(ACCOUNT, &down("down-1", NOW - HOUR), json!({})).await;
    assert_bundle(&world.write(&up("up-1", NOW), world.covers("down-1")).await, "up-1", &["down-1"]);
    let at = now();
    let saved = store::key(&["todos", "atlas"]);
    store::write(&saved, &json!({"read":at - 2 * 86_400_000,"state":"unavailable","links":{}})).unwrap();
    assert_separate(&world.list(ACCOUNT).await, "a to-do list last read two days ago");
    store::write(&saved, &json!({"read":null,"state":"unauthorized","links":null})).unwrap();
    assert_separate(&world.list(ACCOUNT).await, "a refused to-do list");
    store::write(&saved, &json!({"read":at - 60_000,"state":"ready","links":{}})).unwrap();
    assert_bundle(&world.list(ACCOUNT).await, "up-1", &["down-1"]);
    store::write(&saved, &json!({"read":null,"state":"off","todos":[]})).unwrap();
    assert_bundle(&world.list(ACCOUNT).await, "up-1", &["down-1"]);
}

#[tokio::test]
async fn while_the_todo_list_is_unknown_no_new_bundle_is_made() {
    if isolated() {
        return;
    }
    let world = World::new();
    world.seed_point(ACCOUNT, &down("down-1", NOW - HOUR), json!({})).await;
    store::write(&store::key(&["todos", "atlas"]), &json!({"read":now() - 2 * 86_400_000,"state":"unavailable","links":{}})).unwrap();
    world.write(&up("up-1", NOW), world.covers("down-1")).await;
    store::remove(&store::key(&["todos", "atlas"])).unwrap();
    assert_separate(&world.list(ACCOUNT).await, "the claim was made while the list was unknown");
}

#[tokio::test]
async fn a_label_this_copy_cannot_name_keeps_the_mail_in_view() {
    if isolated() {
        return;
    }
    let world = World::new();
    let mut older = down("unnamed", NOW - HOUR);
    older["labelIds"] = json!(["INBOX", "Label_999"]);
    world.seed_point(ACCOUNT, &older, json!({})).await;
    assert_separate(&world.write(&up("up-1", NOW), world.covers("unnamed")).await, "it could be the return mark");
}

#[tokio::test]
async fn mail_returned_without_its_mark_is_never_hidden() {
    if isolated() {
        return;
    }
    let world = World::new();
    world.seed_point(ACCOUNT, &down("came-back", NOW - HOUR), json!({})).await;
    store::write(&store::key(&["returned-unmarked", ACCOUNT]), &json!({"came-back":now()})).unwrap();
    assert_separate(&world.write(&up("up-1", NOW), world.covers("came-back")).await, "snooze returned it");
}

#[tokio::test]
async fn an_approvals_file_that_is_not_an_object_is_treated_as_empty() {
    if isolated() {
        return;
    }
    let world = World::new();
    store::write(&approved_key(), &json!([1, 2])).unwrap();
    world.seed_point(ACCOUNT, &down("alice", NOW - 2 * HOUR), json!({})).await;
    let front = mail("carrier-1", "carrier-1", NOW, "Courier <news@courier.example>", Some(&gmail_says("courier.example")), &["INBOX"], "Monitor is UP: example.com");
    world.write(&front, world.covers("alice")).await;
    let view = world.inbox_call("inbox.approveBundle", json!({"accountId":ACCOUNT,"front":"carrier-1"})).await.unwrap();
    assert_bundle(&view, "carrier-1", &["alice"]);
}

#[tokio::test]
async fn faking_an_approved_sender_fails_gmails_check() {
    if isolated() {
        return;
    }
    let world = World::new();
    store::write(&approved_key(), &json!({"senders":[{"email":"news@courier.example","name":"Courier","approved":1}]})).unwrap();
    world.seed_point(ACCOUNT, &down("alice", NOW - HOUR), json!({})).await;
    let fake = mail("fake", "fake", NOW, "Courier <news@courier.example>", Some("relay.evil.example; dmarc=pass header.from=courier.example"), &["INBOX"], "Monitor is UP: example.com");
    assert_separate(&world.write(&fake, world.covers("alice")).await, "a faked approved sender");
}

#[tokio::test]
async fn not_the_same_point_is_kept_on_the_older_mail_alone() {
    if isolated() {
        return;
    }
    let world = World::new();
    world.seed_point(ACCOUNT, &down("down-1", NOW - HOUR), json!({})).await;
    assert_bundle(&world.write(&up("up-1", NOW), world.covers("down-1")).await, "up-1", &["down-1"]);
    let view = world.inbox_call("inbox.refuseBundle", json!({"accountId":ACCOUNT,"ids":["down-1"]})).await.unwrap();
    assert_separate(&view, "refused");
    assert_eq!(store::read(&store::key(&["overviews", ACCOUNT])).unwrap().unwrap()["down-1"]["contextChanged"], true);
    world.seed_point(ACCOUNT, &down("down-1", NOW - HOUR), json!({})).await;
    assert_separate(&world.write(&up("up-2", NOW + HOUR), world.covers("down-1")).await, "never bundled again");
    assert_separate(&world.write(&mail("x", "x", NOW + 2 * HOUR, "Courier <n@c.example>", Some(&gmail_says("c.example")), &["INBOX"], "Monitor is UP: example.com"), world.covers("down-1")).await, "by anyone");
    assert!(world.inbox_call("inbox.refuseBundle", json!({"accountId":ACCOUNT,"ids":[]})).await.is_err());
}

#[tokio::test]
async fn when_the_front_leaves_the_inbox_the_older_mail_comes_back_and_its_point_is_written_again() {
    if isolated() {
        return;
    }
    let world = World::new();
    world.seed_point(ACCOUNT, &down("down-1", NOW - HOUR), json!({})).await;
    assert_bundle(&world.write(&up("up-1", NOW), world.covers("down-1")).await, "up-1", &["down-1"]);
    world.local.test_set_labels(ACCOUNT, "up-1", json!(["UNREAD"])).await.unwrap();
    assert_separate(&world.list(ACCOUNT).await, "the front left");
    assert_eq!(store::read(&store::key(&["overviews", ACCOUNT])).unwrap().unwrap()["down-1"]["contextChanged"], true, "its Point is out of date by now");
    assert!(covered_ids(ACCOUNT).is_empty());
    // The refusal list stays clean, so a later mail can still bundle it.
    world.seed_point(ACCOUNT, &down("down-1", NOW - HOUR), json!({})).await;
    assert_bundle(&world.write(&up("up-2", NOW + HOUR), world.covers("down-1")).await, "up-2", &["down-1"]);
}

#[tokio::test]
async fn a_mail_that_left_the_inbox_is_not_listed_and_its_front_still_shows_the_others() {
    if isolated() {
        return;
    }
    let world = World::new();
    world.seed_point(ACCOUNT, &down("down-1", NOW - HOUR), json!({})).await;
    world.seed_point(ACCOUNT, &down("down-2", NOW - 2 * HOUR), json!({})).await;
    world.write(&up("up-1", NOW), json!([{"id":"down-1","quote":quote()},{"id":"down-2","quote":quote()}])).await;
    world.local.test_set_labels(ACCOUNT, "down-1", json!(["UNREAD"])).await.unwrap();
    assert_bundle(&world.list(ACCOUNT).await, "up-1", &["down-2"]);
}

#[tokio::test]
async fn a_sender_s_older_mail_is_written_before_the_newer_one() {
    if isolated() {
        return;
    }
    let world = World::new();
    world.seed(ACCOUNT, &down("down-1", NOW - HOUR)).await;
    world.seed(ACCOUNT, &up("up-1", NOW)).await;
    let picked = older_first(ACCOUNT, vec!["up-1".into()], false, false, &world.local).await;
    assert_eq!(picked, ["down-1"], "the older mail goes first");
    assert_eq!(older_first(ACCOUNT, vec!["up-1".into()], true, false, &world.local).await, ["up-1"], "Retry asks for exactly that mail");
    // A background run leaves the older mail if it waits for the app.
    store::update(&store::key(&["overviews", ACCOUNT]), |saved| {
        saved["down-1"] = json!({"state":"waiting","foreground":true,"updated":1,"version":2});
        Ok(())
    })
    .unwrap();
    assert_eq!(older_first(ACCOUNT, vec!["up-1".into()], false, true, &world.local).await, ["up-1"], "the background run does not wait for it");
    // Once the older mail has its Point the newer one goes.
    world.seed_point(ACCOUNT, &down("down-1", NOW - HOUR), json!({})).await;
    assert_eq!(older_first(ACCOUNT, vec!["up-1".into()], false, false, &world.local).await, ["up-1"]);
}

#[tokio::test]
async fn mail_behind_a_bundle_is_not_told_to_be_written_again_until_it_comes_back() {
    if isolated() {
        return;
    }
    let world = World::new();
    world.seed_point(ACCOUNT, &down("down-1", NOW - HOUR), json!({"contextChanged":true})).await;
    let saved = store::read(&store::key(&["overviews", ACCOUNT])).unwrap().unwrap();
    assert!(saved["down-1"]["contextChanged"] == true && overview_due(&saved["down-1"], false, now()), "a marked Point would be written again");
    assert_bundle(&world.write(&up("up-1", NOW), world.covers("down-1")).await, "up-1", &["down-1"]);
    let mut shown = super::super::overview_snapshot(store::read(&store::key(&["overviews", ACCOUNT])).unwrap().unwrap(), now()).unwrap();
    assert_eq!(shown["down-1"]["refresh"], true, "the row alone says write again");
    super::super::no_refresh_for_covered(ACCOUNT, &mut shown);
    assert!(shown["down-1"].get("refresh").is_none(), "the bundle says it is kept as it is");
    assert_eq!(older_first(ACCOUNT, vec!["up-1".into()], false, false, &world.local).await, ["up-1"], "and is not picked ahead of its front");
}

#[test]
fn a_point_written_under_earlier_rules_is_written_again_once_with_its_end_date() {
    use super::super::{finish_overviews_protected, overview_due};
    let at = now();
    let mut saved = json!({"m":{"state":"ready","text":"Old.","version":2,"promptRevision":POINT_REVISION - 1,"updated":at,"expiresAt":0}});
    assert!(overview_due(&saved["m"], false, at), "written again under the new rules");
    let ids = ["m".to_string()];
    saved["m"]["rewriteState"] = json!("running");
    saved["m"]["rewriteAt"] = json!(at);
    finish_overviews_protected(&mut saved, &ids, &Ok(json!([{"id":"m","text":"Meeting moved to Friday.","expiresAt":0,"untilAt":at + 86_400_000,"personal":true}])), &Default::default()).unwrap();
    assert_eq!(saved["m"]["untilAt"], at + 86_400_000, "the writer's end date is kept as its own field");
    assert_eq!(saved["m"]["promptRevision"], POINT_REVISION);
    assert!(!overview_due(&saved["m"], false, at));
}

#[test]
fn the_end_date_answer_is_kept_apart_from_the_midnight_expiry() {
    let at = now();
    let later = (at + 6 * 86_400_000) / 1000;
    let until = chrono::DateTime::from_timestamp(later, 0).unwrap().to_rfc3339();
    let messages = json!([{"id":"a","owner":ACCOUNT,"date":"2026-11-09T10:00:00.000Z","body":"Payment due today.","validUntil":at + 3_600_000}]);
    let answer = json!({"overviews":[{"id":"a","text":"Payment due today.","evidence":[{"source":"mail","quote":"Payment due today."}],"until":until,"timeSensitive":true}]});
    let rows = describe::validate(&answer, &messages, &json!({})).unwrap();
    assert_eq!(rows[0]["expiresAt"], at + 3_600_000, "today means midnight");
    assert!(rows[0]["untilAt"].as_i64().unwrap() >= later * 1000 - 1000, "and the end date is still the model's own");
}

#[test]
fn the_api_takes_only_gmail_ids_and_known_fields() {
    let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
    runtime.block_on(async {
        if isolated() {
            return;
        }
        let world = World::new();
        assert_eq!(world.inbox_call("inbox.bundles", json!({"accountId":ACCOUNT,"extra":1})).await, Err("invalid_params"));
        assert_eq!(world.inbox_call("inbox.approveBundle", json!({"accountId":ACCOUNT,"front":"bad\u{1}id"})).await, Err("invalid_params"));
        assert_eq!(world.inbox_call("inbox.approveBundle", json!({"accountId":ACCOUNT,"front":"up-1"})).await, Err("bundle_not_found"));
        assert_eq!(world.inbox_call("inbox.refuseBundle", json!({"accountId":ACCOUNT,"ids":["bad\u{1}id"]})).await, Err("invalid_params"));
        assert_eq!(world.inbox_call("inbox.removeApprovedSender", json!({"email":"","name":""})).await, Err("invalid_params"));
    });
}
