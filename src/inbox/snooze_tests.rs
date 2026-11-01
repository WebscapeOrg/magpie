use super::*;
use std::collections::{BTreeMap, BTreeSet};
use std::sync::Mutex;

const ACCOUNT: &str = "one@example.org";
const HOUR: i64 = 3_600_000;

#[derive(Default)]
struct Mailbox {
    /// message id -> (thread id, label ids)
    messages: BTreeMap<String, (String, BTreeSet<String>)>,
    /// label id -> name
    labels: BTreeMap<String, String>,
    serial: u32,
    offline: bool,
    refuse_create: bool,
    writes: Vec<String>,
}
struct Fake(Mutex<Mailbox>);
impl Fake {
    fn new(messages: &[(&str, &str, &[&str])]) -> Self {
        let mut mailbox = Mailbox::default();
        for (id, thread, labels) in messages {
            mailbox.messages.insert(
                (*id).into(),
                (
                    (*thread).into(),
                    labels.iter().map(|l| (*l).to_owned()).collect(),
                ),
            );
        }
        Fake(Mutex::new(mailbox))
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
    fn set(&self, offline: bool, refuse_create: bool) {
        let mut mailbox = self.0.lock().unwrap();
        mailbox.offline = offline;
        mailbox.refuse_create = refuse_create;
    }
}
impl Mail for Fake {
    async fn read(&self, _: &str, id: &str) -> Result<Value> {
        let mailbox = self.0.lock().unwrap();
        if mailbox.offline {
            return Err("gmail_http_failed");
        }
        let (thread, labels) = mailbox.messages.get(id).ok_or("gmail_not_found")?;
        Ok(json!({"id":id,"threadId":thread,"labelIds":labels,
            "payload":{"headers":[{"name":"Subject","value":format!("Subject of {id}")}]}}))
    }
    async fn thread(&self, _: &str, thread: &str) -> Result<Vec<Value>> {
        let mailbox = self.0.lock().unwrap();
        if mailbox.offline {
            return Err("gmail_http_failed");
        }
        Ok(mailbox
            .messages
            .iter()
            .filter(|(_, (t, _))| t == thread)
            .map(|(id, (_, labels))| json!({"id":id,"threadId":thread,"labelIds":labels}))
            .collect())
    }
    async fn labels(&self, _: &str) -> Result<Value> {
        let mailbox = self.0.lock().unwrap();
        if mailbox.offline {
            return Err("gmail_http_failed");
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
        for (_, labels) in mailbox.messages.values_mut() {
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
        if mailbox.offline {
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
        mailbox.writes.push(format!(
            "modify {} +{} -{}",
            ids.join(","),
            add.join(","),
            remove.join(",")
        ));
        Ok(())
    }
    async fn list(&self, _: &str, label: &str) -> Result<Value> {
        let mailbox = self.0.lock().unwrap();
        if mailbox.offline {
            return Err("gmail_http_failed");
        }
        let found: Vec<(&String, &String)> = mailbox
            .messages
            .iter()
            .filter(|(_, (_, labels))| {
                labels.contains(label) && !labels.contains("TRASH") && !labels.contains("SPAM")
            })
            .map(|(id, (thread, _))| (id, thread))
            .collect();
        Ok(json!({"ids":found.iter().map(|f| f.0).collect::<Vec<_>>(),
            "threadIds":found.iter().map(|f| f.1).collect::<Vec<_>>(),"nextPageToken":""}))
    }
    async fn accounts(&self) -> Result<Vec<String>> {
        Ok(vec![ACCOUNT.into()])
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
/// Lets the next tick discover again, as a minute passing would.
fn forget_discovery() {
    store::write(&store::key(&["snooze-labels", ACCOUNT]), &json!({})).unwrap();
}
/// Makes the next tick skip discovery, as if it had just run, so wakes meet Gmail unprepared.
fn skip_discovery() {
    store::write(
        &store::key(&["snooze-labels", ACCOUNT]),
        &json!({"checked":now()}),
    )
    .unwrap();
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
    assert_eq!(
        fake.writes(),
        [format!("modify a1,a2 +INBOX,UNREAD -{moved}")]
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
    fake.set(false, false);
    forget_discovery();
    call("inbox.tick", &json!({}), &fake).await.unwrap();
    let settled = row("b1").unwrap();
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
    fake.writes();
    skip_discovery();
    let result = call("inbox.tick", &json!({}), &fake).await.unwrap();
    assert_eq!(result, json!({"woke":2,"failures":0}));
    let writes = fake.writes();
    assert!(
        writes.contains(&format!("modify c1 +INBOX,UNREAD -{label}")),
        "{writes:?}"
    );
    assert!(
        writes.contains(&"modify f1 +INBOX,UNREAD -".to_owned()),
        "{writes:?}"
    );
    assert!(
        !writes.iter().any(|w| w.contains("d1") || w.contains("e1")),
        "{writes:?}"
    );
    assert!(row("c1").is_none() && row("d1").is_none() && row("f1").is_none());
    let moved = row("e1").unwrap();
    assert_eq!(moved["labelId"], later.as_str());
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
    let past = fake.add_label(&slot(now() - HOUR).unwrap().1);
    fake.add_label("Receipts");
    call("inbox.tick", &json!({}), &fake).await.unwrap();
    let found = row("g1").unwrap();
    assert_eq!(found["state"], "sleeping");
    assert_eq!(found["ids"], json!(["g1", "g2"]));
    assert_eq!(found["until"], tomorrow.0);
    assert_eq!(found["subject"], "Subject of g1");
    assert_eq!(fake.writes(), [format!("delete {past}")]);
    assert!(fake.label_id("Receipts").is_some());

    // The other Magpie returns the thread; this one drops its copy without touching Gmail.
    fake.tag(&["g1", "g2"], &["INBOX"], &[&elsewhere]);
    forget_discovery();
    call("inbox.tick", &json!({}), &fake).await.unwrap();
    assert!(row("g1").is_none());
    assert_eq!(fake.writes(), Vec::<String>::new());
    // Its label is deleted elsewhere: a mirrored row of it goes too.
    fake.tag(&["h1"], &[&elsewhere], &[]);
    forget_discovery();
    call("inbox.tick", &json!({}), &fake).await.unwrap();
    assert!(row("h1").is_some());
    fake.0.lock().unwrap().labels.remove(&elsewhere);
    forget_discovery();
    call("inbox.tick", &json!({}), &fake).await.unwrap();
    assert!(row("h1").is_none());
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
            until: 0,
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
}
