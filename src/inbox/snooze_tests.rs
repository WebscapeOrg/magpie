use super::*;
use std::collections::{BTreeMap, BTreeSet};
use std::sync::Mutex;

const ACCOUNT: &str = "one@example.org";
const HOUR: i64 = 3_600_000;

#[derive(Default)]
struct Mailbox {
    /// message id -> (thread id, label ids, received)
    messages: BTreeMap<String, (String, BTreeSet<String>, i64)>,
    /// label id -> name
    labels: BTreeMap<String, String>,
    serial: u32,
    offline: bool,
    refuse_create: bool,
    /// An error every message read returns, as Gmail's pacing or a lost message would.
    read_error: Option<&'static str>,
    /// Threads whose read fails.
    broken: BTreeSet<String>,
    refuse_modify: bool,
    /// Message reads that take a minute, as a Gmail that stops answering would.
    stall: bool,
    /// Labels Gmail's listing has not caught up with yet.
    unlisted: BTreeSet<String>,
    /// A labels answer that lists nothing, not even Gmail's own labels.
    empty_labels: bool,
    page_size: usize,
    accounts: Option<Vec<String>>,
    writes: Vec<String>,
    calls: Vec<String>,
}
struct Fake(Mutex<Mailbox>);
impl Fake {
    fn new(messages: &[(&str, &str, &[&str])]) -> Self {
        let mut mailbox = Mailbox {
            page_size: 100,
            ..Mailbox::default()
        };
        for (id, thread, labels) in messages {
            mailbox.messages.insert(
                (*id).into(),
                (
                    (*thread).into(),
                    labels.iter().map(|l| (*l).to_owned()).collect(),
                    0,
                ),
            );
        }
        Fake(Mutex::new(mailbox))
    }
    /// A message Gmail receives now.
    fn arrive(&self, id: &str, thread: &str, labels: &[&str]) {
        self.0.lock().unwrap().messages.insert(
            id.into(),
            (
                thread.into(),
                labels.iter().map(|l| (*l).to_owned()).collect(),
                now() + 1,
            ),
        );
    }
    fn labels_of(&self, id: &str) -> Vec<String> {
        let mailbox = self.0.lock().unwrap();
        mailbox.messages[id].1.iter().cloned().collect()
    }
    fn label_id(&self, name: &str) -> Option<String> {
        let mailbox = self.0.lock().unwrap();
        mailbox
            .labels
            .iter()
            .find(|(_, n)| n.as_str() == name)
            .map(|(id, _)| id.clone())
    }
    fn add_label(&self, name: &str) -> String {
        let mut mailbox = self.0.lock().unwrap();
        mailbox.serial += 1;
        let id = format!("Label_{}", mailbox.serial);
        mailbox.labels.insert(id.clone(), name.into());
        id
    }
    fn tag(&self, ids: &[&str], add: &[&str], remove: &[&str]) {
        let mut mailbox = self.0.lock().unwrap();
        for id in ids {
            let labels = &mut mailbox.messages.get_mut(*id).unwrap().1;
            for label in add {
                labels.insert((*label).into());
            }
            for label in remove {
                labels.remove(*label);
            }
        }
    }
    fn writes(&self) -> Vec<String> {
        std::mem::take(&mut self.0.lock().unwrap().writes)
    }
    fn calls(&self) -> Vec<String> {
        std::mem::take(&mut self.0.lock().unwrap().calls)
    }
    fn set(&self, offline: bool, refuse_create: bool) {
        let mut mailbox = self.0.lock().unwrap();
        mailbox.offline = offline;
        mailbox.refuse_create = refuse_create;
    }
    fn with(&self, change: impl FnOnce(&mut Mailbox)) {
        change(&mut self.0.lock().unwrap());
    }
}
impl Mail for Fake {
    async fn read(&self, _: &str, id: &str) -> Result<Value> {
        let stall = self.0.lock().unwrap().stall;
        if stall {
            tokio::time::sleep(Duration::from_secs(60)).await;
        }
        let mut mailbox = self.0.lock().unwrap();
        mailbox.calls.push(format!("read {id}"));
        if mailbox.offline {
            return Err("gmail_http_failed");
        }
        if let Some(error) = mailbox.read_error {
            return Err(error);
        }
        let (thread, labels, date) = mailbox.messages.get(id).ok_or("gmail_not_found")?;
        Ok(json!({"id":id,"threadId":thread,"labelIds":labels,"internalDate":date.to_string(),
            "payload":{"headers":[{"name":"Subject","value":format!("Subject of {id}")}]}}))
    }
    async fn thread(&self, _: &str, thread: &str) -> Result<Vec<Value>> {
        let mut mailbox = self.0.lock().unwrap();
        mailbox.calls.push(format!("thread {thread}"));
        if mailbox.offline || mailbox.broken.contains(thread) {
            return Err("gmail_http_failed");
        }
        let found: Vec<Value> = mailbox
            .messages
            .iter()
            .filter(|(_, (t, _, _))| t == thread)
            .map(|(id, (_, labels, date))| {
                json!({"id":id,"threadId":thread,"labelIds":labels,"internalDate":date.to_string()})
            })
            .collect();
        if found.is_empty() {
            return Err("gmail_not_found");
        }
        Ok(found)
    }
    async fn labels(&self, _: &str) -> Result<Value> {
        let mut mailbox = self.0.lock().unwrap();
        mailbox.calls.push("labels".into());
        if mailbox.offline {
            return Err("gmail_http_failed");
        }
        if mailbox.empty_labels {
            return Ok(json!([]));
        }
        let mut rows = vec![json!({"id":"INBOX","rawName":"INBOX","system":true})];
        rows.extend(
            mailbox
                .labels
                .iter()
                .map(|(id, name)| json!({"id":id,"rawName":name,"system":false})),
        );
        Ok(Value::Array(rows))
    }
    async fn create_label(&self, _: &str, name: &str) -> Result<Value> {
        let mut mailbox = self.0.lock().unwrap();
        if mailbox.offline || mailbox.refuse_create {
            return Err("gmail_http_failed");
        }
        if mailbox
            .labels
            .values()
            .any(|n| n.eq_ignore_ascii_case(name))
        {
            return Err("gmail_http_failed");
        }
        mailbox.serial += 1;
        let id = format!("Label_{}", mailbox.serial);
        mailbox.labels.insert(id.clone(), name.into());
        mailbox.writes.push(format!("create {name}"));
        Ok(json!({"id":id,"name":name}))
    }
    async fn delete_label(&self, _: &str, id: &str) -> Result<()> {
        let mut mailbox = self.0.lock().unwrap();
        if mailbox.offline {
            return Err("gmail_http_failed");
        }
        mailbox.labels.remove(id);
        for (_, labels, _) in mailbox.messages.values_mut() {
            labels.remove(id);
        }
        mailbox.writes.push(format!("delete {id}"));
        Ok(())
    }
    async fn modify(
        &self,
        _: &str,
        ids: &[String],
        add: &[String],
        remove: &[String],
    ) -> Result<()> {
        let mut mailbox = self.0.lock().unwrap();
        if mailbox.offline || mailbox.refuse_modify {
            return Err("gmail_http_failed");
        }
        for id in ids {
            let labels = &mut mailbox.messages.get_mut(id).ok_or("gmail_http_failed")?.1;
            for label in add {
                labels.insert(label.clone());
            }
            for label in remove {
                labels.remove(label);
            }
        }
        let write = format!(
            "modify {} +{} -{}",
            ids.join(","),
            add.join(","),
            remove.join(",")
        );
        mailbox.calls.push(write.clone());
        mailbox.writes.push(write);
        Ok(())
    }
    async fn list(&self, _: &str, label: &str, page: &str) -> Result<Value> {
        let mut mailbox = self.0.lock().unwrap();
        mailbox.calls.push(format!("list {label} {page}"));
        if mailbox.offline {
            return Err("gmail_http_failed");
        }
        let start: usize = if page.is_empty() { 0 } else { page.parse().unwrap() };
        let lagging = mailbox.unlisted.contains(label);
        let found: Vec<(String, String)> = mailbox
            .messages
            .iter()
            .filter(|(_, (_, labels, _))| {
                !lagging
                    && labels.contains(label)
                    && !labels.contains("TRASH")
                    && !labels.contains("SPAM")
            })
            .map(|(id, (thread, _, _))| (id.clone(), thread.clone()))
            .collect();
        let end = (start + mailbox.page_size).min(found.len());
        let next = if end < found.len() { end.to_string() } else { String::new() };
        let shown = &found[start..end];
        Ok(json!({"ids":shown.iter().map(|f| &f.0).collect::<Vec<_>>(),
            "threadIds":shown.iter().map(|f| &f.1).collect::<Vec<_>>(),"nextPageToken":next}))
    }
    async fn accounts(&self) -> Result<Vec<String>> {
        Ok(self
            .0
            .lock()
            .unwrap()
            .accounts
            .clone()
            .unwrap_or_else(|| vec![ACCOUNT.into()]))
    }
}

fn fixture() -> crate::mail::tests::AccountFixture {
    crate::mail::tests::account_fixture(json!({"version":1,"accounts":[
        {"email":ACCOUNT,"provider":"gmail","clientId":"synthetic.apps.googleusercontent.com"}]}))
}
fn row(id: &str) -> Option<Value> {
    rows().unwrap().remove(&store::key(&[ACCOUNT, id]))
}
fn edit(id: &str, field: &str, value: Value) {
    change(|rows| {
        rows.get_mut(&store::key(&[ACCOUNT, id])).unwrap()[field] = value;
        Ok(())
    })
    .unwrap();
}
/// Deletes a label as Gmail's settings would, taking it off every message.
fn delete_in_gmail(fake: &Fake, label: &str) {
    fake.with(|mailbox| {
        mailbox.labels.remove(label);
        for (_, labels, _) in mailbox.messages.values_mut() {
            labels.remove(label);
        }
    });
}
/// Lets the next tick discover again, as a minute passing would.
fn forget_discovery() {
    store::write(&store::key(&["snooze-labels", ACCOUNT]), &json!({})).unwrap();
}
/// Lets the next tick discover again, as if more than a minute had passed since the last time.
fn a_minute_later() {
    let name = store::key(&["snooze-labels", ACCOUNT]);
    let mut marks = store::read(&name).unwrap().unwrap_or(json!({}));
    marks.as_object_mut().unwrap().remove("checked");
    if let Some(empty) = marks["empty"].as_object_mut() {
        for first in empty.values_mut() {
            *first = json!(first.as_i64().unwrap() - DISCOVER_EVERY - 1);
        }
    }
    store::write(&name, &marks).unwrap();
}
/// Makes the next tick skip discovery, as if it had just run, so wakes meet Gmail unprepared.
fn skip_discovery() {
    store::write(
        &store::key(&["snooze-labels", ACCOUNT]),
        &json!({"checked":now()}),
    )
    .unwrap();
}
#[tokio::test]
async fn undo_of_a_snooze_returns_the_mail_as_it_was() {
    if crate::mail::tests::isolated() {
        return;
    }
    let _fixture = fixture();
    let fake = Fake::new(&[("u1", "t1", &["INBOX"])]);
    let until = now() + 2 * HOUR;
    let (_, name) = slot(until).unwrap();
    assert_eq!(snooze_at(&fake, "u1", until).await.unwrap()["ok"], true);
    let label = fake.label_id(&name).unwrap();
    call("inbox.wake", &json!({"accountId":ACCOUNT,"id":"u1","restore":true}), &fake)
        .await
        .unwrap();
    assert_eq!(fake.writes().last().unwrap(), &format!("modify u1 +INBOX -{label}"));
    assert_eq!(fake.label_id(RETURNED_LABEL), None, "Undo leaves no return mark");
    assert_eq!(
        call("inbox.wake", &json!({"accountId":ACCOUNT,"id":"u1","restore":"yes"}), &fake).await,
        Err("invalid_params")
    );
}

#[tokio::test]
async fn undo_of_a_snooze_returns_only_the_mail_that_was_in_the_inbox() {
    if crate::mail::tests::isolated() {
        return;
    }
    let _fixture = fixture();
    let fake = Fake::new(&[("archived", "t1", &["CATEGORY_UPDATES"]), ("reply", "t1", &["SENT"]), ("u1", "t1", &["INBOX"])]);
    let until = now() + 2 * HOUR;
    let (_, name) = slot(until).unwrap();
    assert_eq!(snooze_at(&fake, "u1", until).await.unwrap()["ok"], true);
    let label = fake.label_id(&name).unwrap();
    call("inbox.wake", &json!({"accountId":ACCOUNT,"id":"u1","restore":true}), &fake).await.unwrap();
    let writes = fake.writes();
    assert_eq!(writes[writes.len() - 2], format!("modify u1 +INBOX -{label}"), "{writes:?}");
    assert_eq!(writes[writes.len() - 1], format!("modify archived,reply + -{label}"), "the rest only lose the snooze label: {writes:?}");
}

#[tokio::test]
async fn undo_returns_the_mail_when_a_second_snooze_replaced_the_first() {
    if crate::mail::tests::isolated() {
        return;
    }
    let _fixture = fixture();
    let fake = Fake::new(&[("a", "t1", &["INBOX"]), ("b", "t1", &["INBOX"]), ("archived", "t1", &["CATEGORY_UPDATES"])]);
    let until = now() + 2 * HOUR;
    let (_, name) = slot(until).unwrap();
    assert_eq!(snooze_at(&fake, "a", until).await.unwrap()["ok"], true);
    assert_eq!(snooze_at(&fake, "b", until).await.unwrap()["ok"], true);
    let label = fake.label_id(&name).unwrap();
    call("inbox.wake", &json!({"accountId":ACCOUNT,"id":"b","restore":true}), &fake).await.unwrap();
    let writes = fake.writes();
    assert!(writes.contains(&format!("modify a,b +INBOX -{label}")), "both return: {writes:?}");
    assert!(writes.contains(&format!("modify archived + -{label}")), "the other mail only loses the label: {writes:?}");
}

/// A conversation snoozed on another device, as this engine learns of it: both mails carry the slot
/// label and neither is in the Inbox.
async fn snoozed_elsewhere(fake: &Fake, until: i64) -> String {
    let label = fake.add_label(&slot(until).unwrap().1);
    fake.tag(&["g1", "g2"], &[&label], &[]);
    call("inbox.tick", &json!({}), fake).await.unwrap();
    assert_eq!(row("g1").unwrap()["ids"], json!(["g1", "g2"]));
    assert!(row("g1").unwrap().get("inbox").is_none(), "discovery cannot know what was in the Inbox");
    label
}

#[tokio::test]
async fn undo_returns_all_the_mail_of_a_snooze_made_elsewhere() {
    if crate::mail::tests::isolated() {
        return;
    }
    let _fixture = fixture();
    let fake = Fake::new(&[("g1", "t7", &[]), ("g2", "t7", &[])]);
    let label = snoozed_elsewhere(&fake, now() + 24 * HOUR).await;
    call("inbox.wake", &json!({"accountId":ACCOUNT,"id":"g1","restore":true}), &fake).await.unwrap();
    let writes = fake.writes();
    assert!(writes.contains(&format!("modify g1,g2 +INBOX -{label}")), "{writes:?}");
}

#[tokio::test]
async fn undo_returns_the_mail_when_a_new_snooze_replaced_one_made_elsewhere() {
    if crate::mail::tests::isolated() {
        return;
    }
    let _fixture = fixture();
    let fake = Fake::new(&[("g1", "t7", &[]), ("g2", "t7", &[]), ("later", "t7", &[])]);
    let until = now() + 24 * HOUR;
    let label = snoozed_elsewhere(&fake, until).await;
    fake.tag(&["later"], &["INBOX"], &[]);
    assert_eq!(snooze_at(&fake, "later", until).await.unwrap()["ok"], true);
    call("inbox.wake", &json!({"accountId":ACCOUNT,"id":"later","restore":true}), &fake).await.unwrap();
    let returned = fake.writes().into_iter().find(|write| write.contains("+INBOX")).expect("a write returned the mail");
    for id in ["g1", "g2", "later"] {
        assert!(returned.contains(id), "{id} returns too: {returned}");
    }
    assert!(returned.ends_with(&format!("-{label}")), "{returned}");
}

fn arrives_in_inbox(fake: &Fake, id: &str) {
    fake.with(|mailbox| {
        mailbox.messages.insert(id.into(), ("t7".into(), std::iter::once("INBOX".to_owned()).collect(), 0));
    });
}

/// Another device snoozes the conversation to a later slot, moving this device's snooze.
fn moved_elsewhere(fake: &Fake, ids: &[&str], old_until: i64, until: i64) -> i64 {
    let label = fake.add_label(&slot(until).unwrap().1);
    let old = fake.label_id(&slot(old_until).unwrap().1).unwrap();
    fake.tag(ids, &[&label], &["INBOX", &old]);
    until
}

async fn undo_a_new_snooze_of(fake: &Fake, id: &str, until: i64) {
    arrives_in_inbox(fake, id);
    assert_eq!(snooze_at(fake, id, until).await.unwrap()["ok"], true);
    call("inbox.wake", &json!({"accountId":ACCOUNT,"id":id,"restore":true}), fake).await.unwrap();
}

async fn undo_returns_mail_another_device_put_to_sleep(tick: bool) {
    let _fixture = fixture();
    let fake = Fake::new(&[("a", "t7", &["INBOX"])]);
    let until = now() + 24 * HOUR;
    assert_eq!(snooze_at(&fake, "a", until).await.unwrap()["ok"], true);
    arrives_in_inbox(&fake, "b");
    let moved = moved_elsewhere(&fake, &["a", "b"], until, until + 24 * HOUR);
    if tick {
        call("inbox.tick", &json!({}), &fake).await.unwrap();
    }
    undo_a_new_snooze_of(&fake, "c", moved).await;
    for id in ["a", "b", "c"] {
        assert!(fake.labels_of(id).contains(&"INBOX".to_owned()), "{id}: {:?}", fake.labels_of(id));
    }
}

#[tokio::test]
async fn undo_returns_mail_another_device_put_to_sleep_once_this_device_has_seen_it() {
    if crate::mail::tests::isolated() {
        return;
    }
    undo_returns_mail_another_device_put_to_sleep(true).await;
}

#[tokio::test]
async fn undo_returns_mail_another_device_put_to_sleep_before_this_device_has_seen_it() {
    if crate::mail::tests::isolated() {
        return;
    }
    undo_returns_mail_another_device_put_to_sleep(false).await;
}

async fn undo_does_not_believe_a_list_after_a_move(tick: bool) {
    let _fixture = fixture();
    let fake = Fake::new(&[("a", "t7", &["INBOX"]), ("x", "t7", &[])]);
    let until = now() + 24 * HOUR;
    assert_eq!(snooze_at(&fake, "a", until).await.unwrap()["ok"], true);
    assert_eq!(row("a").unwrap()["inbox"], json!(["a"]));
    let moved = moved_elsewhere(&fake, &["a", "x"], until, until - 12 * HOUR);
    if tick {
        call("inbox.tick", &json!({}), &fake).await.unwrap();
        let adopted = row("a").unwrap();
        assert_eq!(adopted["label"], json!(slot(moved).unwrap().1), "this device follows the move");
        assert!(adopted.get("inbox").is_none(), "{adopted}");
    }
    undo_a_new_snooze_of(&fake, "c", moved).await;
    assert!(fake.labels_of("x").contains(&"INBOX".to_owned()), "{:?}", fake.labels_of("x"));
}

#[tokio::test]
async fn undo_does_not_believe_a_list_once_a_move_is_seen() {
    if crate::mail::tests::isolated() {
        return;
    }
    undo_does_not_believe_a_list_after_a_move(true).await;
}

#[tokio::test]
async fn undo_does_not_believe_a_list_before_a_move_is_seen() {
    if crate::mail::tests::isolated() {
        return;
    }
    undo_does_not_believe_a_list_after_a_move(false).await;
}

#[tokio::test]
async fn undo_leaves_archived_mail_out_when_the_list_is_still_good() {
    if crate::mail::tests::isolated() {
        return;
    }
    let _fixture = fixture();
    let fake = Fake::new(&[("a", "t7", &["INBOX"]), ("x", "t7", &[])]);
    let until = now() + 24 * HOUR;
    assert_eq!(snooze_at(&fake, "a", until).await.unwrap()["ok"], true);
    undo_a_new_snooze_of(&fake, "c", until).await;
    assert!(fake.labels_of("a").contains(&"INBOX".to_owned()));
    assert!(fake.labels_of("c").contains(&"INBOX".to_owned()));
    assert!(fake.labels_of("x").is_empty(), "{:?}", fake.labels_of("x"));
}

#[tokio::test]
async fn undo_of_a_snooze_made_elsewhere_gives_sent_mail_no_inbox() {
    if crate::mail::tests::isolated() {
        return;
    }
    let _fixture = fixture();
    let fake = Fake::new(&[("g1", "t7", &[]), ("sent", "t7", &["SENT"])]);
    let label = fake.add_label(&slot(now() + 24 * HOUR).unwrap().1);
    fake.tag(&["g1", "sent"], &[&label], &[]);
    call("inbox.tick", &json!({}), &fake).await.unwrap();
    assert!(row("g1").unwrap().get("inbox").is_none());
    call("inbox.wake", &json!({"accountId":ACCOUNT,"id":"g1","restore":true}), &fake).await.unwrap();
    assert!(fake.labels_of("g1").contains(&"INBOX".to_owned()));
    assert_eq!(fake.labels_of("sent"), ["SENT"]);
}

#[tokio::test]
async fn undo_returns_mail_a_retry_found_under_the_snoozes_own_label() {
    if crate::mail::tests::isolated() {
        return;
    }
    let _fixture = fixture();
    let fake = Fake::new(&[("a", "t7", &["INBOX"])]);
    let until = now() + 24 * HOUR;
    fake.with(|mailbox| mailbox.refuse_modify = true);
    assert_eq!(snooze_at(&fake, "a", until).await, Err("snooze_pending_retry"));
    fake.with(|mailbox| mailbox.refuse_modify = false);
    assert_eq!(row("a").unwrap()["inbox"], json!(["a"]));
    arrives_in_inbox(&fake, "b");
    let label = fake.label_id(&slot(until).unwrap().1).expect("the failed snooze made its label");
    fake.tag(&["a", "b"], &[&label], &["INBOX"]);
    call("inbox.tick", &json!({}), &fake).await.unwrap();
    let confirmed = row("a").unwrap();
    assert_eq!(confirmed["state"], "sleeping");
    assert_eq!(confirmed["ids"], json!(["a", "b"]));
    assert!(confirmed.get("inbox").is_none(), "{confirmed}");
    undo_a_new_snooze_of(&fake, "c", until).await;
    for id in ["a", "b", "c"] {
        assert!(fake.labels_of(id).contains(&"INBOX".to_owned()), "{id}: {:?}", fake.labels_of(id));
    }
}

#[tokio::test]
async fn a_snooze_that_cannot_read_the_labels_saves_no_list_of_inbox_mail() {
    if crate::mail::tests::isolated() {
        return;
    }
    let _fixture = fixture();
    let fake = Fake::new(&[("a", "t7", &["INBOX"]), ("x", "t7", &[])]);
    fake.with(|mailbox| mailbox.empty_labels = true);
    assert_eq!(snooze_at(&fake, "a", now() + 24 * HOUR).await, Err("snooze_pending_retry"));
    assert!(row("a").unwrap().get("inbox").is_none());
}

async fn snooze_at(fake: &Fake, id: &str, until: i64) -> Result<Value> {
    call(
        "inbox.snooze",
        &json!({"accountId":ACCOUNT,"id":id,"until":until}),
        fake,
    )
    .await
}

#[test]
fn slot_labels_round_up_and_only_exact_names_are_magpie_slots() {
    let (at, name) = slot(1_793_595_600_000 + 1).unwrap();
    assert_eq!(at, 1_793_595_600_000 + SLOT);
    assert_eq!(name, "Magpie-snooze-2026-11-02-0505-UTC");
    assert_eq!(slot(at).unwrap(), (at, name.clone()));
    assert_eq!(slot_time(&name), Some(at));
    assert_eq!(slot_time("magpie-snooze-2026-11-02-0505-utc"), Some(at));
    for other in [
        "Magpie-snooze-2026-11-02-0503-UTC",
        "Magpie-snooze-2026-11-02-505-UTC",
        "Magpie-snooze-2026-11-02-0505",
        "Magpie-snooze-2026-11-02-0505-UTC-copy",
        "Magpie snooze 2026-11-02-0505-UTC",
        "Magpie-snooze-2026-13-02-0505-UTC",
        "Magpie-snooze-+2026-11-02-0505-UTC",
        "Receipts",
    ] {
        assert_eq!(slot_time(other), None, "{other}");
    }
    let listed = slots(&json!([
        {"id":"Label_2","rawName":"Magpie-snooze-2026-11-03-0500-UTC","system":false},
        {"id":"Label_1","rawName":"Magpie-snooze-2026-11-02-0500-UTC","system":false},
        {"id":"Label_3","rawName":"Magpie-snooze-2026-11-02-0501-UTC","system":false},
        {"id":"../x","rawName":"Magpie-snooze-2026-11-04-0500-UTC","system":false},
        {"id":"SYS","rawName":"Magpie-snooze-2026-11-05-0500-UTC","system":true}
    ]));
    assert_eq!(
        listed.iter().map(|s| s.id.as_str()).collect::<Vec<_>>(),
        ["Label_1", "Label_2"]
    );
}

#[tokio::test]
async fn snooze_labels_and_archives_the_thread_in_one_change_and_a_chosen_wake_returns_it() {
    if crate::mail::tests::isolated() {
        return;
    }
    let _fixture = fixture();
    let fake = Fake::new(&[
        ("a1", "t1", &["INBOX"]),
        ("a2", "t1", &["INBOX", "SENT"]),
        ("a3", "t1", &["TRASH"]),
    ]);
    let until = now() + 2 * HOUR;
    let (_, name) = slot(until).unwrap();
    assert_eq!(snooze_at(&fake, "a1", until).await.unwrap()["ok"], true);
    let label = fake.label_id(&name).unwrap();
    assert_eq!(
        fake.writes(),
        [
            format!("create {name}"),
            format!("modify a1,a2 +{label} -INBOX")
        ]
    );
    let saved = row("a1").unwrap();
    assert_eq!(saved["state"], "sleeping");
    assert_eq!(saved["labelId"], label.as_str());
    assert_eq!(saved["label"], name.as_str());
    assert_eq!(saved["ids"], json!(["a1", "a2"]));
    assert_eq!(saved["subject"], "Subject of a1");
    assert_eq!(saved["until"], until);

    // Snoozing again moves the thread to the new slot and drops the old one in the same change.
    let later = until + 24 * HOUR;
    let (_, second) = slot(later).unwrap();
    snooze_at(&fake, "a2", later).await.unwrap();
    let moved = fake.label_id(&second).unwrap();
    assert_eq!(
        fake.writes(),
        [
            format!("create {second}"),
            format!("modify a1,a2 +{moved} -INBOX,{label}")
        ]
    );
    assert!(row("a1").is_none(), "one row per thread");
    assert_eq!(snapshot(ACCOUNT).unwrap().as_array().unwrap().len(), 1);

    assert_eq!(
        call("inbox.wake", &json!({"accountId":ACCOUNT,"id":"a2"}), &fake)
            .await
            .unwrap(),
        json!({"ok":true})
    );
    let mark = fake.label_id(RETURNED_LABEL).unwrap();
    assert_eq!(
        fake.writes(),
        [
            format!("create {RETURNED_LABEL}"),
            format!("modify a1,a2 +INBOX,UNREAD,{mark} -{moved}")
        ],
        "the return mark goes in the same Gmail change as the wake"
    );
    assert!(fake.labels_of("a3").contains(&"TRASH".to_owned()));
    assert!(!fake.labels_of("a3").contains(&"INBOX".to_owned()));
    assert_eq!(snapshot(ACCOUNT).unwrap(), json!([]));
    assert_eq!(
        call("inbox.wake", &json!({"accountId":ACCOUNT,"id":"a2"}), &fake).await,
        Err("snooze_missing")
    );
    assert_eq!(
        snooze_at(&fake, "a3", until).await,
        Err("snooze_invalid_folder"),
        "mail in Trash is never snoozed"
    );
    assert_eq!(
        call(
            "inbox.snooze",
            &json!({"accountId":ACCOUNT,"id":"a1","until":until,"threadId":"t9"}),
            &fake
        )
        .await,
        Err("invalid_params"),
        "the caller never names the thread"
    );
}

#[tokio::test]
async fn an_offline_snooze_waits_unresolved_and_tick_takes_its_thread_from_gmail() {
    if crate::mail::tests::isolated() {
        return;
    }
    let _fixture = fixture();
    let fake = Fake::new(&[("b1", "t2", &["INBOX"]), ("b2", "t2", &["INBOX"])]);
    fake.set(true, false);
    let until = now() + 3 * HOUR;
    assert_eq!(
        call(
            "inbox.snooze",
            &json!({"accountId":ACCOUNT,"id":"b1","until":until,"subject":"Shown\u{0}subject"}),
            &fake
        )
        .await,
        Err("snooze_pending_retry")
    );
    let pending = row("b1").unwrap();
    assert_eq!(pending["state"], "pending");
    assert_eq!(pending["ids"], json!([]));
    assert_eq!(pending["threadId"], "");
    assert_eq!(pending["subject"], "Shown subject");
    // Still offline: tick keeps it.
    call("inbox.tick", &json!({}), &fake).await.unwrap();
    assert_eq!(row("b1").unwrap()["state"], "pending");
    assert_eq!(row("b1").unwrap()["attempts"], 1, "a failed retry waits before the next");
    fake.set(false, false);
    forget_discovery();
    edit("b1", "retryAt", Value::Null);
    call("inbox.tick", &json!({}), &fake).await.unwrap();
    let settled = row("b1").unwrap();
    assert!(settled.get("attempts").is_none() && settled.get("retryAt").is_none());
    assert_eq!(settled["state"], "sleeping");
    assert_eq!(settled["threadId"], "t2");
    assert_eq!(settled["ids"], json!(["b1", "b2"]));
    assert_eq!(settled["subject"], "Subject of b1");
    let label = settled["labelId"].as_str().unwrap().to_owned();
    assert!(fake.labels_of("b2").contains(&label));
    assert!(!fake.labels_of("b2").contains(&"INBOX".to_owned()));

    // An offline snooze whose wake time passes before Gmail is reached never touches Gmail.
    fake.set(true, false);
    snooze_at(&fake, "b2", now() + HOUR).await.unwrap_err();
    edit("b2", "until", json!(now() - 1));
    fake.set(false, false);
    fake.writes();
    forget_discovery();
    call("inbox.tick", &json!({}), &fake).await.unwrap();
    assert!(row("b2").is_none());
    assert!(fake.writes().iter().all(|w| !w.starts_with("modify")));
}

#[tokio::test]
async fn tick_wakes_due_threads_and_leaves_threads_returned_or_moved_elsewhere() {
    if crate::mail::tests::isolated() {
        return;
    }
    let _fixture = fixture();
    let fake = Fake::new(&[
        ("c1", "t3", &["INBOX"]),
        ("d1", "t4", &["INBOX"]),
        ("e1", "t5", &["INBOX"]),
        ("f1", "t6", &[]),
    ]);
    let until = now() + HOUR;
    for id in ["c1", "d1", "e1"] {
        snooze_at(&fake, id, until).await.unwrap();
    }
    let label = row("c1").unwrap()["labelId"].as_str().unwrap().to_owned();
    // Another Magpie returned d1 already, and snoozed e1 again for later.
    fake.tag(&["d1"], &["INBOX"], &[&label]);
    let later = fake.add_label(&slot(until + 24 * HOUR).unwrap().1);
    fake.tag(&["e1"], &[&later], &[&label]);
    // A snooze saved by an older Magpie has no label.
    change(|rows| {
        rows.insert(
            store::key(&[ACCOUNT, "f1"]),
            json!({"generation":"g","operationId":null,"accountId":ACCOUNT,"id":"f1","ids":["f1"],"until":now()-1,"state":"sleeping","subject":"Old","threadId":"t6"}),
        );
        Ok(())
    })
    .unwrap();
    for id in ["c1", "d1", "e1"] {
        edit(id, "until", json!(now() - 1));
    }
    let before = row("e1").unwrap()["generation"].clone();
    fake.writes();
    skip_discovery();
    let result = call("inbox.tick", &json!({}), &fake).await.unwrap();
    assert_eq!(result, json!({"woke":2,"failures":0}));
    let writes = fake.writes();
    let mark = fake.label_id(RETURNED_LABEL).unwrap();
    assert!(
        writes.contains(&format!("modify c1 +INBOX,UNREAD,{mark} -{label}")),
        "{writes:?}"
    );
    assert!(
        writes.contains(&format!("modify f1 +INBOX,UNREAD,{mark} -")),
        "{writes:?}"
    );
    assert!(
        !writes.iter().any(|w| w.contains("d1") || w.contains("e1")),
        "{writes:?}"
    );
    assert!(row("c1").is_none() && row("d1").is_none() && row("f1").is_none());
    let moved = row("e1").unwrap();
    assert_eq!(moved["labelId"], later.as_str());
    assert!(moved["generation"].is_string());
    assert_ne!(
        moved["generation"], before,
        "the move gives the row a new generation"
    );
    assert_eq!(
        moved["until"],
        slot_time(&slot(until + 24 * HOUR).unwrap().1).unwrap()
    );
    assert!(
        fake.labels_of("e1").contains(&later),
        "the later snooze stays"
    );
}

#[tokio::test]
async fn discovery_mirrors_snoozes_made_elsewhere_and_deletes_due_empty_labels() {
    if crate::mail::tests::isolated() {
        return;
    }
    let _fixture = fixture();
    let fake = Fake::new(&[("g1", "t7", &[]), ("g2", "t7", &[]), ("h1", "t8", &[])]);
    let tomorrow = slot(now() + 24 * HOUR).unwrap();
    let elsewhere = fake.add_label(&tomorrow.1);
    fake.tag(&["g1", "g2"], &[&elsewhere], &[]);
    let past = fake.add_label(&slot(now() - KEEP_DUE - HOUR).unwrap().1);
    let recent = fake.add_label(&slot(now() - HOUR).unwrap().1);
    fake.add_label("Receipts");
    call("inbox.tick", &json!({}), &fake).await.unwrap();
    let found = row("g1").unwrap();
    assert_eq!(found["state"], "sleeping");
    assert_eq!(found["ids"], json!(["g1", "g2"]));
    assert_eq!(found["until"], tomorrow.0);
    assert_eq!(found["subject"], "Subject of g1");
    assert_eq!(
        fake.writes(),
        Vec::<String>::new(),
        "an empty due label is kept until a second listing a minute later"
    );
    a_minute_later();
    fake.calls();
    call("inbox.tick", &json!({}), &fake).await.unwrap();
    assert_eq!(fake.writes(), [format!("delete {past}")]);
    assert!(fake.label_id("Receipts").is_some());
    // A label emptied less than KEEP_DUE after its time stays, and is not listed again until then.
    fake.with(|mailbox| assert!(mailbox.labels.contains_key(&recent)));
    assert!(!fake.calls().iter().any(|c| c.starts_with(&format!("list {recent} "))));

    // The other Magpie returns the thread; this one drops its copy without touching Gmail.
    fake.tag(&["g1", "g2"], &["INBOX"], &[&elsewhere]);
    forget_discovery();
    call("inbox.tick", &json!({}), &fake).await.unwrap();
    assert!(row("g1").is_none());
    assert_eq!(fake.writes(), Vec::<String>::new());
    // Its label is deleted before its time, as in Gmail's settings: the snooze carries on, and
    // the next tick labels the thread again.
    fake.tag(&["h1"], &[&elsewhere], &[]);
    forget_discovery();
    call("inbox.tick", &json!({}), &fake).await.unwrap();
    assert!(row("h1").is_some());
    fake.with(|mailbox| {
        mailbox.labels.remove(&elsewhere);
        for (_, labels, _) in mailbox.messages.values_mut() {
            labels.remove(&elsewhere);
        }
    });
    forget_discovery();
    call("inbox.tick", &json!({}), &fake).await.unwrap();
    let kept = row("h1").unwrap();
    assert!(kept.get("labelId").is_none() && kept["state"] == "sleeping");
    fake.writes();
    skip_discovery();
    call("inbox.tick", &json!({}), &fake).await.unwrap();
    let again = fake.label_id(&tomorrow.1).unwrap();
    assert_eq!(
        fake.writes(),
        [format!("create {}", tomorrow.1), format!("modify h1 +{again} -")]
    );
    assert_eq!(row("h1").unwrap()["labelId"], again.as_str());

    // A label gone more than KEEP_DUE after its time went because another Magpie returned the
    // thread, and Dave may have archived it since: this Magpie drops its copy and leaves the
    // thread alone.
    edit("h1", "until", json!(now() - KEEP_DUE - 1));
    delete_in_gmail(&fake, &again);
    forget_discovery();
    call("inbox.tick", &json!({}), &fake).await.unwrap();
    assert!(row("h1").is_none());
    assert_eq!(fake.writes(), Vec::<String>::new());
}

#[tokio::test]
async fn a_labels_answer_without_gmails_own_labels_returns_no_mail_and_waits() {
    if crate::mail::tests::isolated() {
        return;
    }
    let _fixture = fixture();
    let fake = Fake::new(&[("jj1", "tj", &["INBOX"])]);
    snooze_at(&fake, "jj1", now() + HOUR).await.unwrap();
    edit("jj1", "until", json!(now() - 1));
    // An answer that lists no labels must not read as Dave having deleted the snooze label.
    fake.with(|mailbox| mailbox.empty_labels = true);
    fake.writes();
    forget_discovery();
    let first = call("inbox.tick", &json!({}), &fake).await.unwrap();
    assert_eq!(first, json!({"woke":0,"failures":1}));
    assert_eq!(fake.writes(), Vec::<String>::new());
    assert!(row("jj1").is_some());
    fake.with(|mailbox| mailbox.empty_labels = false);
    edit("jj1", "retryAt", Value::Null);
    skip_discovery();
    let second = call("inbox.tick", &json!({}), &fake).await.unwrap();
    assert_eq!(second, json!({"woke":1,"failures":0}));
    assert!(row("jj1").is_none());
}

#[tokio::test]
async fn a_label_deleted_before_its_time_while_no_magpie_looked_still_returns_the_mail() {
    if crate::mail::tests::isolated() {
        return;
    }
    let _fixture = fixture();
    let fake = Fake::new(&[("ff1", "tg", &["INBOX"]), ("ff2", "tg", &["INBOX"])]);
    snooze_at(&fake, "ff1", now() + HOUR).await.unwrap();
    let label = row("ff1").unwrap()["labelId"].as_str().unwrap().to_owned();
    // Dave deletes the label in Gmail's settings while every Magpie is off, and its time passes.
    delete_in_gmail(&fake, &label);
    edit("ff1", "until", json!(now() - 1));
    // The first wake fails; discovery keeps the snooze for the next one.
    fake.with(|mailbox| {
        mailbox.broken.insert("tg".into());
    });
    forget_discovery();
    let first = call("inbox.tick", &json!({}), &fake).await.unwrap();
    assert_eq!(first, json!({"woke":0,"failures":1}));
    assert!(row("ff1").is_some());
    fake.with(|mailbox| {
        mailbox.broken.clear();
    });
    edit("ff1", "retryAt", Value::Null);
    fake.writes();
    skip_discovery();
    let second = call("inbox.tick", &json!({}), &fake).await.unwrap();
    assert_eq!(second, json!({"woke":1,"failures":0}));
    let writes = fake.writes();
    let mark = fake.label_id(RETURNED_LABEL).unwrap();
    assert_eq!(writes.last().unwrap(), &format!("modify ff1,ff2 +INBOX,UNREAD,{mark} -"), "{writes:?}");
    assert!(row("ff1").is_none());
}

#[tokio::test]
async fn a_label_created_by_another_magpie_at_the_same_moment_is_used() {
    if crate::mail::tests::isolated() {
        return;
    }
    let _fixture = fixture();
    let fake = Fake::new(&[("k1", "t9", &["INBOX"])]);
    let until = now() + HOUR;
    let (_, name) = slot(until).unwrap();
    // The label appears between this Magpie's listing and its create, which Gmail refuses.
    fake.set(false, true);
    let other = fake.add_label(&name);
    let known = slots(&json!([]));
    assert_eq!(ensure(&fake, ACCOUNT, &name, &known).await.unwrap(), other);
    fake.0.lock().unwrap().labels.remove(&other);
    assert_eq!(
        ensure(&fake, ACCOUNT, &name, &known).await,
        Err("gmail_http_failed"),
        "a refusal with no label behind it is still a failure"
    );
    fake.set(false, false);
    // At the label limit, a snooze needing a new label is refused and leaves no row.
    let full: Vec<Slot> = (0..LABELS)
        .map(|n| Slot {
            id: format!("Label_x{n}"),
            name: format!("n{n}"),
            until: until + n as i64,
        })
        .collect();
    assert_eq!(
        ensure(&fake, ACCOUNT, &name, &full).await,
        Err("snooze_limit")
    );
    for n in 0..LABELS as i64 {
        fake.add_label(&slot(until + (n + 1) * 24 * HOUR).unwrap().1);
    }
    assert_eq!(snooze_at(&fake, "k1", until).await, Err("snooze_limit"));
    assert!(row("k1").is_none());
    assert!(fake.labels_of("k1").contains(&"INBOX".to_owned()));
    // Labels whose time has passed wait to be deleted and do not count against the limit.
    let past: Vec<Slot> = (0..LABELS)
        .map(|n| Slot {
            id: format!("Label_p{n}"),
            name: format!("p{n}"),
            until: now() - HOUR,
        })
        .collect();
    let (_, unused) = slot(until + 500 * 24 * HOUR).unwrap();
    assert!(ensure(&fake, ACCOUNT, &unused, &past).await.is_ok());
}

fn insert(id: &str, row: Value) {
    change(|rows| {
        rows.insert(store::key(&[ACCOUNT, id]), row);
        Ok(())
    })
    .unwrap();
}

#[tokio::test]
async fn a_wake_that_keeps_failing_waits_and_never_holds_up_other_snoozes() {
    if crate::mail::tests::isolated() {
        return;
    }
    let _fixture = fixture();
    let mut messages: Vec<(String, String)> = (0..WORK_PER_RUN)
        .map(|n| (format!("m{n}"), format!("bad{n}")))
        .collect();
    messages.push(("ok1".into(), "good".into()));
    messages.push(("gone1".into(), "lost".into()));
    let listed: Vec<(&str, &str, &[&str])> = messages
        .iter()
        .map(|(id, thread)| (id.as_str(), thread.as_str(), &["INBOX"][..]))
        .collect();
    let fake = Fake::new(&listed);
    let until = now() + HOUR;
    for (id, _) in &messages {
        snooze_at(&fake, id, until).await.unwrap();
    }
    for (n, (id, _)) in messages.iter().enumerate() {
        edit(id, "until", json!(now() - 1000 + n as i64));
    }
    // Ten threads fail to read every time; one thread was deleted for good.
    fake.with(|mailbox| {
        mailbox.broken = (0..WORK_PER_RUN).map(|n| format!("bad{n}")).collect();
        mailbox.messages.remove("gone1");
    });
    fake.writes();
    skip_discovery();
    let first = call("inbox.tick", &json!({}), &fake).await.unwrap();
    assert_eq!(first, json!({"woke":0,"failures":WORK_PER_RUN}));
    assert_eq!(row("m0").unwrap()["attempts"], 1);
    assert!(row("m0").unwrap()["retryAt"].as_i64().unwrap() > now());
    skip_discovery();
    let second = call("inbox.tick", &json!({}), &fake).await.unwrap();
    assert_eq!(
        second,
        json!({"woke":1,"failures":WORK_PER_RUN}),
        "rows waiting out a pause are still held back"
    );
    assert!(row("ok1").is_none(), "the good thread came back");
    assert!(row("gone1").is_none(), "a deleted thread ends its snooze");
    assert!(row("m0").is_some(), "a failing thread is kept for later");
}

#[tokio::test]
async fn a_short_tick_returns_due_mail_before_looking_for_snoozes_made_elsewhere() {
    if crate::mail::tests::isolated() {
        return;
    }
    let _fixture = fixture();
    let fake = Fake::new(&[("n1", "tn", &["INBOX"]), ("o1", "to", &[])]);
    snooze_at(&fake, "n1", now() + HOUR).await.unwrap();
    edit("n1", "until", json!(now() - 1));
    let elsewhere = fake.add_label(&slot(now() + 24 * HOUR).unwrap().1);
    fake.tag(&["o1"], &[&elsewhere], &[]);
    forget_discovery();
    fake.calls();
    call("inbox.tick", &json!({"seconds":1}), &fake).await.unwrap();
    let calls = fake.calls();
    let woke = calls.iter().position(|c| c.starts_with("modify n1 +INBOX")).unwrap();
    let listed = calls.iter().position(|c| c.starts_with("list ")).unwrap();
    assert!(woke < listed, "{calls:?}");
}

#[tokio::test]
async fn a_late_retry_snoozes_only_the_mail_dave_snoozed() {
    if crate::mail::tests::isolated() {
        return;
    }
    let _fixture = fixture();
    let fake = Fake::new(&[("p1", "tp", &["INBOX"]), ("q1", "tq", &["INBOX"])]);
    // Offline: the snooze is saved before its thread is known.
    fake.set(true, false);
    snooze_at(&fake, "p1", now() + HOUR).await.unwrap_err();
    fake.set(false, false);
    // Gmail could read q1's thread, but the change's outcome was lost.
    fake.with(|mailbox| mailbox.refuse_modify = true);
    assert_eq!(snooze_at(&fake, "q1", now() + HOUR).await, Err("snooze_pending_retry"));
    fake.with(|mailbox| mailbox.refuse_modify = false);
    assert_eq!(row("q1").unwrap()["ids"], json!(["q1"]));
    // Replies arrive in both threads before the snoozes reach Gmail.
    fake.arrive("p2", "tp", &["INBOX"]);
    fake.arrive("q2", "tq", &["INBOX"]);
    skip_discovery();
    call("inbox.tick", &json!({}), &fake).await.unwrap();
    assert_eq!(row("p1").unwrap()["ids"], json!(["p1"]));
    assert_eq!(row("q1").unwrap()["ids"], json!(["q1"]));
    for (snoozed, reply) in [("p1", "p2"), ("q1", "q2")] {
        assert!(!fake.labels_of(snoozed).contains(&"INBOX".to_owned()));
        assert!(fake.labels_of(reply).contains(&"INBOX".to_owned()), "{reply} stays in the Inbox");
    }
}

#[tokio::test]
async fn a_retry_keeps_the_snooze_unless_gmail_says_the_message_is_gone() {
    if crate::mail::tests::isolated() {
        return;
    }
    let _fixture = fixture();
    let fake = Fake::new(&[("r1", "tr", &["INBOX"])]);
    fake.set(true, false);
    snooze_at(&fake, "r1", now() + HOUR).await.unwrap_err();
    fake.set(false, false);
    for error in ["gmail_request_deferred", "gmail_unauthorized", "gmail_token_missing"] {
        fake.with(|mailbox| mailbox.read_error = Some(error));
        edit("r1", "retryAt", Value::Null);
        skip_discovery();
        call("inbox.tick", &json!({}), &fake).await.unwrap();
        assert_eq!(row("r1").unwrap()["state"], "pending", "{error}");
    }
    assert_eq!(row("r1").unwrap()["attempts"], 3);
    // Lost Google access is tried again within five minutes however often it failed, so the snooze
    // finishes soon after Dave signs in again; a fault in the message itself waits longer.
    for (error, longest) in [
        ("gmail_unauthorized", BACKOFF_OFFLINE),
        ("gmail_forbidden", BACKOFF_OFFLINE),
        ("gmail_invalid_response", BACKOFF_MAX),
    ] {
        fake.with(|mailbox| mailbox.read_error = Some(error));
        edit("r1", "retryAt", Value::Null);
        edit("r1", "attempts", json!(12));
        skip_discovery();
        call("inbox.tick", &json!({}), &fake).await.unwrap();
        let wait = row("r1").unwrap()["retryAt"].as_i64().unwrap() - now();
        assert!(wait > longest - 60_000 && wait <= longest, "{error}: {wait}");
    }
    fake.with(|mailbox| mailbox.read_error = Some("gmail_not_found"));
    edit("r1", "retryAt", Value::Null);
    skip_discovery();
    call("inbox.tick", &json!({}), &fake).await.unwrap();
    assert!(row("r1").is_none());
}

#[tokio::test]
async fn an_unconfirmed_snooze_gives_way_to_a_later_change_made_elsewhere() {
    if crate::mail::tests::isolated() {
        return;
    }
    let _fixture = fixture();
    let fake = Fake::new(&[("s1", "ts", &["INBOX"]), ("u1", "tu", &["INBOX"])]);
    // s1: snoozed here offline, then snoozed on another device to another time.
    fake.set(true, false);
    snooze_at(&fake, "s1", now() + HOUR).await.unwrap_err();
    fake.set(false, false);
    let other = fake.add_label(&slot(now() + 48 * HOUR).unwrap().1);
    fake.tag(&["s1"], &[&other], &["INBOX"]);
    // u1: snoozed here, then snoozed again here offline; another device returned it early.
    snooze_at(&fake, "u1", now() + 2 * HOUR).await.unwrap();
    let first = row("u1").unwrap()["labelId"].as_str().unwrap().to_owned();
    let first_name = row("u1").unwrap()["label"].clone();
    fake.set(true, false);
    snooze_at(&fake, "u1", now() + 72 * HOUR).await.unwrap_err();
    fake.set(false, false);
    assert_eq!(row("u1").unwrap()["over"], first_name);
    fake.tag(&["u1"], &["INBOX"], &[&first]);
    fake.writes();
    skip_discovery();
    call("inbox.tick", &json!({}), &fake).await.unwrap();
    assert!(row("s1").is_none() && row("u1").is_none());
    assert!(fake.writes().iter().all(|w| !w.starts_with("modify")));
    assert!(fake.labels_of("s1").contains(&other));
    assert!(fake.labels_of("u1").contains(&"INBOX".to_owned()));
}

#[tokio::test]
async fn snoozes_saved_without_labels_get_one_and_return_only_mail_still_out_of_the_inbox() {
    if crate::mail::tests::isolated() {
        return;
    }
    let _fixture = fixture();
    let fake = Fake::new(&[
        ("v1", "tv", &[]),
        ("v2", "tv", &["INBOX"]),
        ("w1", "tw", &["INBOX"]),
        ("x1", "tx", &[]),
        ("y1", "ty", &[]),
    ]);
    let until = now() + 5 * HOUR;
    let old = |id: &str, thread: &str, until: i64| {
        json!({"generation":"g","operationId":null,"accountId":ACCOUNT,"id":id,"ids":[id],"until":until,"state":"sleeping","subject":"Old","threadId":thread})
    };
    // Saved by an older Magpie: v's thread is still archived, w is back in the Inbox already.
    let mut v = old("v1", "tv", until);
    v["ids"] = json!(["v1", "v2"]);
    insert("v1", v);
    insert("w1", old("w1", "tw", until));
    // x was snoozed again on another device since.
    let later = fake.add_label(&slot(until + 24 * HOUR).unwrap().1);
    fake.tag(&["x1"], &[&later], &[]);
    insert("x1", old("x1", "tx", until));
    skip_discovery();
    call("inbox.tick", &json!({}), &fake).await.unwrap();
    let (_, name) = slot(until).unwrap();
    let label = fake.label_id(&name).unwrap();
    assert!(fake.labels_of("v1").contains(&label));
    assert!(!fake.labels_of("v2").contains(&label), "mail already in the Inbox is not labelled");
    let v = row("v1").unwrap();
    assert_eq!((v["label"].as_str(), v["labelId"].as_str()), (Some(name.as_str()), Some(label.as_str())));
    assert!(row("w1").is_none(), "Dave already has w back");
    assert_eq!(row("x1").unwrap()["labelId"], later.as_str());
    fake.writes();
    skip_discovery();
    call("inbox.tick", &json!({}), &fake).await.unwrap();
    assert_eq!(fake.writes(), Vec::<String>::new(), "labelled once");

    // A due snooze without a label leaves mail already in the Inbox as it is, read or not.
    insert("y1", old("y1", "ty", now() - 1));
    fake.arrive("y2", "ty", &["INBOX"]);
    change(|rows| {
        rows.get_mut(&store::key(&[ACCOUNT, "y1"])).unwrap()["ids"] = json!(["y1", "y2"]);
        Ok(())
    })
    .unwrap();
    skip_discovery();
    call("inbox.tick", &json!({}), &fake).await.unwrap();
    let writes = fake.writes();
    let mark = fake.label_id(RETURNED_LABEL).unwrap();
    assert_eq!(writes.last().unwrap(), &format!("modify y1 +INBOX,UNREAD,{mark} -"), "{writes:?}");

    // Move to Inbox finds a snooze by any of its messages.
    assert_eq!(
        call("inbox.wake", &json!({"accountId":ACCOUNT,"id":"v1"}), &fake).await.unwrap(),
        json!({"ok":true})
    );
    assert!(fake.labels_of("v1").contains(&"INBOX".to_owned()));
}

#[tokio::test]
async fn move_to_inbox_returns_the_mail_even_when_its_label_was_removed() {
    if crate::mail::tests::isolated() {
        return;
    }
    let _fixture = fixture();
    let fake = Fake::new(&[("z1", "tz", &["INBOX"]), ("z2", "tz", &["INBOX"])]);
    snooze_at(&fake, "z1", now() + HOUR).await.unwrap();
    let label = row("z1").unwrap()["labelId"].as_str().unwrap().to_owned();
    fake.tag(&["z1", "z2"], &[], &[&label]);
    fake.writes();
    call("inbox.wake", &json!({"accountId":ACCOUNT,"id":"z2"}), &fake)
        .await
        .unwrap();
    let writes = fake.writes();
    let mark = fake.label_id(RETURNED_LABEL).unwrap();
    assert_eq!(writes.last().unwrap(), &format!("modify z1,z2 +INBOX,UNREAD,{mark} -"), "{writes:?}");
    assert!(row("z1").is_none());
}

#[tokio::test]
async fn discovery_reads_every_page_of_a_slot() {
    if crate::mail::tests::isolated() {
        return;
    }
    let _fixture = fixture();
    let fake = Fake::new(&[("aa1", "ta", &[]), ("bb1", "tb", &[]), ("cc1", "tc", &[])]);
    let elsewhere = fake.add_label(&slot(now() + 24 * HOUR).unwrap().1);
    fake.tag(&["aa1", "bb1", "cc1"], &[&elsewhere], &[]);
    fake.with(|mailbox| mailbox.page_size = 2);
    call("inbox.tick", &json!({}), &fake).await.unwrap();
    for id in ["aa1", "bb1", "cc1"] {
        assert_eq!(row(id).unwrap()["labelId"], elsewhere.as_str(), "{id}");
    }
}

#[tokio::test]
async fn a_listing_that_lags_a_new_label_neither_ends_a_snooze_nor_deletes_its_label() {
    if crate::mail::tests::isolated() {
        return;
    }
    let _fixture = fixture();
    let fake = Fake::new(&[("dd1", "td", &["INBOX"]), ("ee1", "tf", &["INBOX"])]);
    snooze_at(&fake, "dd1", now() + HOUR).await.unwrap();
    let future = row("dd1").unwrap()["labelId"].as_str().unwrap().to_owned();
    // ee1 sits in a slot that may be deleted, but its wake keeps failing, so its row still names
    // the slot.
    let past = slot(now() - KEEP_DUE - HOUR).unwrap().1;
    let due = fake.add_label(&past);
    fake.tag(&["ee1"], &[&due], &["INBOX"]);
    insert(
        "ee1",
        json!({"generation":"g","operationId":null,"accountId":ACCOUNT,"id":"ee1","ids":["ee1"],"until":now()-KEEP_DUE-HOUR,"state":"sleeping","subject":"S","threadId":"tf","label":past,"labelId":due}),
    );
    fake.with(|mailbox| {
        mailbox.unlisted = [future.clone(), due.clone()].into();
        mailbox.broken.insert("tf".into());
    });
    fake.writes();
    forget_discovery();
    call("inbox.tick", &json!({}), &fake).await.unwrap();
    a_minute_later();
    call("inbox.tick", &json!({}), &fake).await.unwrap();
    assert!(row("dd1").is_some(), "the thread still carries its label");
    assert!(row("ee1").is_some());
    assert_eq!(fake.writes(), Vec::<String>::new());
    assert!(fake.label_id(&past).is_some());
}

#[tokio::test]
async fn accounts_signed_out_lose_their_snoozes_and_bookkeeping() {
    if crate::mail::tests::isolated() {
        return;
    }
    let _fixture = fixture();
    let fake = Fake::new(&[("ee1", "te", &["INBOX"])]);
    snooze_at(&fake, "ee1", now() + HOUR).await.unwrap();
    call("inbox.tick", &json!({}), &fake).await.unwrap();
    assert!(store::read(&store::key(&["snooze-labels", ACCOUNT])).unwrap().is_some());
    fake.with(|mailbox| mailbox.accounts = Some(vec![]));
    call("inbox.tick", &json!({}), &fake).await.unwrap();
    assert!(row("ee1").is_none());
    assert!(store::read(&store::key(&["snooze-labels", ACCOUNT])).unwrap().is_none());
    assert!(store::read(&store::key(&["snooze-revisions", ACCOUNT])).unwrap().is_none());

    // An account whose snoozes all ended before it signed out loses its bookkeeping too.
    fake.with(|mailbox| mailbox.accounts = None);
    snooze_at(&fake, "ee1", now() + HOUR).await.unwrap();
    call("inbox.wake", &json!({"accountId":ACCOUNT,"id":"ee1"}), &fake)
        .await
        .unwrap();
    forget_discovery();
    call("inbox.tick", &json!({}), &fake).await.unwrap();
    assert!(row("ee1").is_none());
    assert!(store::read(&store::key(&["snooze-labels", ACCOUNT])).unwrap().is_some());
    // Revisions an older Magpie kept for paired phones go with the account too.
    store::replace(&store::key(&["snooze-revisions", ACCOUNT]), &json!({"te":{"revision":"r"}})).unwrap();
    fake.with(|mailbox| mailbox.accounts = Some(vec![]));
    call("inbox.tick", &json!({}), &fake).await.unwrap();
    assert!(store::read(&store::key(&["snooze-labels", ACCOUNT])).unwrap().is_none());
    assert!(store::read(&store::key(&["snooze-revisions", ACCOUNT])).unwrap().is_none());
}

#[tokio::test]
async fn damaged_bookkeeping_is_started_again_and_never_stops_snooze() {
    if crate::mail::tests::isolated() {
        return;
    }
    let fixture = fixture();
    let fake = Fake::new(&[("kk1", "tk", &["INBOX"]), ("kk2", "tl", &["INBOX"])]);
    snooze_at(&fake, "kk1", now() + HOUR).await.unwrap();
    snooze_at(&fake, "kk2", now() + HOUR).await.unwrap();
    let files = [
        store::key(&["snooze-accounts"]),
        store::key(&["snooze-labels", ACCOUNT]),
    ];
    for file in &files {
        let path = fixture.state.join("omamail/inbox").join(file);
        std::fs::write(&path, b"{damaged").unwrap();
        #[cfg(unix)]
        std::fs::set_permissions(&path, std::os::unix::fs::PermissionsExt::from_mode(0o600)).unwrap();
        assert_eq!(store::read(file), Err("inbox_storage_invalid"));
    }
    edit("kk1", "until", json!(now() - 1));
    edit("kk2", "until", json!(now() - 1));
    let ticked = call("inbox.tick", &json!({}), &fake).await.unwrap();
    assert_eq!(ticked, json!({"woke":2,"failures":0}));
    assert!(
        store::read(&files[1]).unwrap().unwrap()["checked"].is_i64(),
        "discovery runs again"
    );
    snooze_at(&fake, "kk1", now() + HOUR).await.unwrap();
    assert_eq!(
        store::read(&files[0]).unwrap().unwrap()["accounts"],
        json!([ACCOUNT])
    );
}

#[tokio::test]
async fn an_offline_snooze_from_another_message_of_a_snoozed_thread_moves_that_snooze() {
    if crate::mail::tests::isolated() {
        return;
    }
    let _fixture = fixture();
    let fake = Fake::new(&[("hh1", "ti", &["INBOX"])]);
    snooze_at(&fake, "hh1", now() + HOUR).await.unwrap();
    let first = row("hh1").unwrap()["labelId"].as_str().unwrap().to_owned();
    // A reply arrives while the thread sleeps; Dave opens it in All mail and snoozes it offline.
    fake.arrive("hh2", "ti", &[]);
    fake.set(true, false);
    snooze_at(&fake, "hh2", now() + 72 * HOUR).await.unwrap_err();
    fake.set(false, false);
    skip_discovery();
    call("inbox.tick", &json!({}), &fake).await.unwrap();
    let moved = row("hh2").unwrap();
    assert_eq!(moved["state"], "sleeping");
    let later = moved["labelId"].as_str().unwrap();
    assert_ne!(later, first);
    assert!(row("hh1").is_none(), "the thread keeps one snooze");
    for id in ["hh1", "hh2"] {
        let labels = fake.labels_of(id);
        assert!(labels.contains(&later.to_owned()) && !labels.contains(&first), "{id}: {labels:?}");
    }
}

#[tokio::test]
async fn a_snoozed_thread_dave_moved_to_the_bin_leaves_the_snoozed_list() {
    if crate::mail::tests::isolated() {
        return;
    }
    let _fixture = fixture();
    let fake = Fake::new(&[("ii1", "tj", &["INBOX"])]);
    snooze_at(&fake, "ii1", now() + HOUR).await.unwrap();
    fake.tag(&["ii1"], &["TRASH"], &[]);
    fake.writes();
    forget_discovery();
    call("inbox.tick", &json!({}), &fake).await.unwrap();
    assert!(row("ii1").is_none());
    assert_eq!(fake.writes(), Vec::<String>::new());
}

#[tokio::test(start_paused = true)]
async fn a_snooze_that_cannot_read_its_thread_in_time_is_saved_to_finish_later() {
    if crate::mail::tests::isolated() {
        return;
    }
    let _fixture = fixture();
    let fake = Fake::new(&[("jj1", "tk", &["INBOX"])]);
    fake.with(|mailbox| mailbox.stall = true);
    assert_eq!(snooze_at(&fake, "jj1", now() + HOUR).await, Err("snooze_pending_retry"));
    let saved = row("jj1").unwrap();
    assert_eq!((saved["state"].as_str(), saved["ids"].clone()), (Some("pending"), json!([])));
    fake.with(|mailbox| mailbox.stall = false);
    skip_discovery();
    call("inbox.tick", &json!({}), &fake).await.unwrap();
    assert_eq!(row("jj1").unwrap()["state"], "sleeping");
    assert!(!fake.labels_of("jj1").contains(&"INBOX".to_owned()));
}

#[tokio::test]
async fn a_wake_keeps_returning_mail_when_the_mark_cannot_be_made_for_good_and_retries_when_it_is_only_offline() {
    if crate::mail::tests::isolated() {
        return;
    }
    let _fixture = fixture();
    let fake = Fake::new(&[("c1", "t1", &["INBOX"])]);
    snooze_at(&fake, "c1", now() + HOUR).await.unwrap();
    edit("c1", "until", json!(now() - 1));
    fake.set(true, false);
    call("inbox.tick", &json!({}), &fake).await.unwrap();
    assert!(!fake.labels_of("c1").contains(&"INBOX".to_owned()), "offline: the wake waits for its next try");
    fake.set(false, true);
    edit("c1", "retryAt", json!(0));
    call("inbox.tick", &json!({}), &fake).await.unwrap();
    assert!(fake.label_id(RETURNED_LABEL).is_none());
    assert!(!fake.labels_of("c1").contains(&"INBOX".to_owned()), "a refused label is a network failure in the fake, so the wake waits");
    fake.set(false, false);
    edit("c1", "retryAt", json!(0));
    call("inbox.tick", &json!({}), &fake).await.unwrap();
    assert!(fake.labels_of("c1").contains(&"INBOX".to_owned()));
    assert!(fake.labels_of("c1").contains(&fake.label_id(RETURNED_LABEL).unwrap()), "both devices can see it came back");
}

#[test]
fn the_return_mark_stays_out_of_label_lists_and_is_not_a_slot() {
    assert!(is_snooze_label(RETURNED_LABEL));
    assert!(slot_time(RETURNED_LABEL).is_none(), "it is never a wake time");
    let shown = crate::providers::gmail::normalize_labels(json!({"labels":[
        {"id":"INBOX","name":"INBOX","type":"system"},
        {"id":"Label_1","name":"Receipts"},
        {"id":"Label_2","name":RETURNED_LABEL}
    ]}));
    assert!(shown.as_array().unwrap().iter().all(|label| label["id"] != "Label_2"));
}

#[test]
fn snooze_slot_labels_stay_out_of_the_labels_magpie_shows() {
    assert!(is_snooze_label("Magpie-snooze-2026-11-02-0505-UTC"));
    assert!(!is_snooze_label("Magpie-snooze notes"));
    let shown = crate::providers::gmail::normalize_labels(json!({"labels":[
        {"id":"INBOX","name":"INBOX","type":"system"},
        {"id":"Label_1","name":"Receipts"},
        {"id":"Label_2","name":"Magpie-snooze-2026-11-02-0505-UTC"}
    ]}));
    let ids: Vec<&str> = shown
        .as_array()
        .unwrap()
        .iter()
        .filter_map(|label| label["id"].as_str())
        .collect();
    assert_eq!(ids, ["INBOX", "Label_1"]);
}
