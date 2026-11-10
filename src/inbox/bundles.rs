//! One Point for mail that is really one Point: when a new mail makes an earlier Inbox mail need no
//! separate attention, the earlier one moves behind it (a bundle). The Point writer proposes a
//! bundle; every check that decides it is made here, from the local copy of the mail.
//!
//! Each account keeps its own record, separate from the Points because those are replaced when
//! they are written again: `covered` (the older mail, its front and both Gmail dates), `refused`
//! (older mail the owner said "Not the same Point" about, never bundled again) and `proposals`
//! (bundles waiting for the owner's approval). Approved senders are kept once per device.
//!
//! Invariant: nothing the model says can hide a mail by itself. A cover is automatic only behind a
//! sender Gmail proved, and only for mail of that same sender or behind a sender the owner has
//! approved; never for the mail listed in `never_hidden`, and never across accounts.
//! Invariant: what shows is decided when the list is read, against the Inbox as it is then.
use super::{POINT_REVISION, now, overview_current, overview_due, point_context, rewrites, sender_proof::{self, Sender}, snooze::RETURNED_LABEL, store, todos};
use crate::local_mail::LocalMail;
use serde_json::{Map, Value, json};
use std::collections::HashSet;

/// How many covered or proposed mails one account remembers before the oldest are forgotten.
const RECORDS: usize = 5000;
/// How many refusals one account remembers.
const REFUSALS: usize = 20_000;
/// How many messages `inbox.refuseBundle` takes in one call.
const REFUSE_LIMIT: usize = 64;

type Book = Map<String, Value>;

fn book_key(account: &str) -> String {
    store::key(&["bundles", account])
}

fn approved_key() -> String {
    store::key(&["bundle-approved"])
}

fn section<'a>(book: &'a Book, name: &str) -> &'a Map<String, Value> {
    static EMPTY: std::sync::OnceLock<Map<String, Value>> = std::sync::OnceLock::new();
    book.get(name).and_then(Value::as_object).unwrap_or_else(|| EMPTY.get_or_init(Map::new))
}

fn section_mut<'a>(book: &'a mut Book, name: &str) -> &'a mut Map<String, Value> {
    let entry = book.entry(name.to_owned()).or_insert_with(|| json!({}));
    if !entry.is_object() {
        *entry = json!({});
    }
    entry.as_object_mut().expect("just made an object")
}

fn read_book(account: &str) -> Result<Book, &'static str> {
    Ok(store::read(&book_key(account))?.and_then(|book| book.as_object().cloned()).unwrap_or_default())
}

/// The Inbox ids the account's record currently hides behind another mail.
pub(super) fn covered_ids(account: &str) -> HashSet<String> {
    read_book(account).map(|book| section(&book, "covered").keys().cloned().collect()).unwrap_or_default()
}

/// Adds the Point written for each Inbox mail in `context` to the context, for the covers question.
pub(super) fn add_points(context: &mut Value) {
    let mut per_account: std::collections::HashMap<String, Value> = std::collections::HashMap::new();
    let at = now();
    let mut points = Vec::new();
    for entry in context["inbox"].as_array().map(Vec::as_slice).unwrap_or_default() {
        let (Some(id), Some(account)) = (entry["id"].as_str(), entry["account"].as_str()) else { continue };
        let saved = per_account.entry(account.to_owned()).or_insert_with(|| store::read(&store::key(&["overviews", account])).ok().flatten().unwrap_or_else(|| json!({})));
        let row = &saved[id];
        if overview_current(row, at) {
            points.push(json!({"id":id,"account":account,"point":row["text"]}));
        }
    }
    if !points.is_empty() {
        context["inboxPoints"] = json!(points);
    }
}

/// The ids to write this round: a mail waits for its sender's older mail that is still to be
/// written, so a cover (which needs the older mail's stored Point) works when several arrive at
/// once. The older mail is written in its place; the newer one is asked for again next round.
pub(super) async fn older_first(account: &str, ids: Vec<String>, retry: bool, background: bool, local_mail: &LocalMail) -> Vec<String> {
    let at = now();
    let saved = store::read(&store::key(&["overviews", account])).ok().flatten().unwrap_or_else(|| json!({}));
    let covered = covered_ids(account);
    let window = point_context::listed(local_mail, account, "in:inbox", point_context::INBOX).await;
    let candidates: HashSet<String> = local_mail.overview_candidates(account).await.unwrap_or_default().into_iter().collect();
    let due = |id: &str| {
        !covered.contains(id) && candidates.contains(id) && overview_due(&saved[id], false, at) && !(background && saved[id]["foreground"] == true)
    };
    let mut chosen = Vec::new();
    for id in ids {
        let older = window.iter().find(|row| row["id"] == id.as_str()).and_then(|mail| {
            let email = mail["from"]["email"].as_str().filter(|email| !email.is_empty())?;
            let date = mail["date"].as_str()?;
            window
                .iter()
                .filter(|other| other["from"]["email"].as_str().is_some_and(|sender| sender.eq_ignore_ascii_case(email)))
                .filter(|other| other["date"].as_str().is_some_and(|earlier| earlier < date))
                .filter(|other| other["id"].as_str().is_some_and(&due))
                .min_by_key(|other| other["date"].as_str().unwrap_or("").to_owned())
                .and_then(|other| other["id"].as_str().map(str::to_owned))
        });
        let pick = if retry { id } else { older.unwrap_or(id) };
        if !chosen.contains(&pick) {
            chosen.push(pick);
        }
    }
    chosen
}

/// The mail's date as Gmail recorded it. The sender writes the Date header; internalDate is Gmail's.
fn internal_date(raw: &Value) -> Option<i64> {
    match &raw["internalDate"] {
        Value::String(text) => text.parse().ok(),
        value => value.as_i64(),
    }
    .filter(|date| *date > 0)
}

fn invitation(part: &Value, depth: usize, budget: &mut usize) -> bool {
    if depth > 32 || *budget == 0 {
        return false;
    }
    *budget -= 1;
    let mime = part["mimeType"].as_str().unwrap_or("");
    if mime.eq_ignore_ascii_case("text/calendar") || mime.eq_ignore_ascii_case("application/ics") || part["filename"].as_str().is_some_and(|name| name.to_lowercase().ends_with(".ics")) {
        return true;
    }
    part["parts"].as_array().into_iter().flatten().any(|child| invitation(child, depth + 1, budget))
}

/// What the engine reads about one mail from the local copy.
struct Facts {
    id: String,
    date: i64,
    sender: Option<Sender>,
    summary: Value,
    raw: Value,
}

impl Facts {
    fn thread(&self) -> &str {
        self.summary["threadId"].as_str().unwrap_or("")
    }
    fn labelled(&self, label: &str) -> bool {
        self.labels().any(|found| found == label)
    }
    fn labels(&self) -> impl Iterator<Item = &str> {
        self.summary["labelIds"].as_array().into_iter().flatten().filter_map(Value::as_str)
    }
    fn from_owner(&self) -> Option<&str> {
        self.sender.as_ref().map(|sender| sender.email.as_str())
    }
}

/// Never reaches Gmail: a mail the local copy does not have cannot be checked, so it stays separate.
async fn facts(account: &str, id: &str, local_mail: &LocalMail) -> Option<Facts> {
    let raw = local_mail.resource(account, id).await.ok()??;
    let date = internal_date(&raw)?;
    let summary = crate::message::content::summarize(&raw, now()).ok()?;
    Some(Facts { id: id.to_owned(), date, sender: sender_proof::sender(&raw), summary, raw })
}

/// What decides whether a mail may be hidden, read once for a round.
struct Guards {
    owners: HashSet<String>,
    links: Value,
    returned: Option<String>,
    named_labels: HashSet<String>,
    returned_unmarked: HashSet<String>,
    drafts: HashSet<String>,
    saved: Value,
    at: i64,
}

impl Guards {
    /// None when anything that decides whether a mail may be hidden could not be read, so that
    /// nothing is hidden on a guess.
    async fn load(account: &str, local_mail: &LocalMail) -> Option<Self> {
        let at = now();
        let links = match todos::link_state(at) {
            todos::LinkState::NotConnected => json!({}),
            todos::LinkState::Known(links) => links,
            todos::LinkState::Unknown => return None,
        };
        Some(Self {
            owners: owner_addresses()?,
            links,
            returned: local_mail.label_id(account, RETURNED_LABEL).await.ok()?,
            named_labels: local_mail.known_label_ids(account).await.ok()?,
            returned_unmarked: super::snooze::returned_unmarked(account).ok()?,
            drafts: local_mail.draft_threads(account).await.ok()?,
            saved: store::read(&store::key(&["overviews", account])).ok()?.unwrap_or_else(|| json!({})),
            at,
        })
    }
    /// A current Point for the older mail, written under today's rules so its end date is known.
    fn point_written(&self, id: &str) -> bool {
        let row = &self.saved[id];
        overview_current(row, self.at) && row["promptRevision"] == POINT_REVISION
    }
}

/// The accounts on this device and their aliases, lower-cased.
fn owner_addresses() -> Option<HashSet<String>> {
    let mut owners = HashSet::new();
    let list = crate::account::list_readonly().ok()?;
    for account in list["accounts"].as_array()? {
        if let Some(id) = account["id"].as_str() {
            owners.insert(id.to_lowercase());
        }
        for alias in account["aliases"].as_array().map(Vec::as_slice).unwrap_or_default() {
            if let Some(email) = alias["email"].as_str() {
                owners.insert(email.trim().to_lowercase());
            }
        }
    }
    Some(owners)
}

/// Why a mail may never be hidden behind another, whatever the writer says; None when it may be.
fn never_hidden(mail: &Facts, guards: &Guards) -> Option<&'static str> {
    if mail.labelled("STARRED") {
        return Some("starred");
    }
    if mail.labelled("DRAFT") {
        return Some("draft");
    }
    if mail.labelled("SENT") {
        return Some("sent");
    }
    if mail.from_owner().is_some_and(|email| guards.owners.contains(email)) {
        return Some("owner");
    }
    if mail.summary["hasAttachments"] == true {
        return Some("attachment");
    }
    if invitation(&mail.raw["payload"], 0, &mut 4000) {
        return Some("invitation");
    }
    if guards.returned.as_deref().is_some_and(|label| mail.labelled(label)) || guards.returned_unmarked.contains(&mail.id) {
        return Some("snooze_returned");
    }
    // Invariant: a label this copy cannot name could be the return mark, so the mail stays in view.
    if mail.labels().any(|label| label.starts_with("Label_") && !guards.named_labels.contains(label)) {
        return Some("unnamed_label");
    }
    if !mail.thread().is_empty() && guards.drafts.contains(mail.thread()) {
        return Some("reply_draft");
    }
    if !rewrites::linked(&guards.links, &mail.id, mail.thread()).is_empty() {
        return Some("todo");
    }
    if guards.saved[mail.id.as_str()]["untilAt"].as_i64().is_some_and(|until| until > guards.at) {
        return Some("end_date_ahead");
    }
    None
}

#[derive(Clone, Debug, PartialEq)]
enum Decision {
    Cover,
    Propose,
    Separate,
}

/// Who may stand in front of whom. Only the newer mail's sender needs approving, because that is
/// the mail shown; an unproven newer mail never bundles anything, even with approval, since a
/// proposal or approval would then hide mail behind an address Gmail did not check.
fn decide(front: &Sender, older: Option<&Sender>, approved: &[Value]) -> Decision {
    if !front.proven {
        return Decision::Separate;
    }
    // Invariant: the older mail must be proven too, whoever asks: without Gmail's check of who sent
    // what goes behind it nothing is hidden, and nothing is offered that a tap could never bundle.
    let Some(older) = older.filter(|older| older.proven) else {
        return Decision::Separate;
    };
    if front.same_as(older) || is_approved(front, approved) {
        Decision::Cover
    } else {
        Decision::Propose
    }
}

fn sender_key(sender: &Sender) -> Value {
    json!({"email":sender.email,"name":sender.name})
}

fn is_approved(sender: &Sender, approved: &[Value]) -> bool {
    let wanted = sender_key(sender);
    approved.iter().any(|entry| entry["email"] == wanted["email"] && entry["name"] == wanted["name"])
}

/// The senders approved on this device, oldest approval first.
pub(super) fn approved_senders() -> Result<Vec<Value>, &'static str> {
    Ok(store::read(&approved_key())?.and_then(|saved| saved["senders"].as_array().cloned()).unwrap_or_default())
}

fn approve_sender(sender: &Sender, at: i64) -> Result<(), &'static str> {
    store::update(&approved_key(), |saved| {
        if !saved.is_object() {
            *saved = json!({});
        }
        let mut senders = saved["senders"].as_array().cloned().unwrap_or_default();
        if !is_approved(sender, &senders) {
            let mut entry = sender_key(sender);
            entry["approved"] = json!(at);
            senders.push(entry);
        }
        saved["senders"] = json!(senders);
        Ok(())
    })
}

/// One proposed or automatic cover, ready to be written under the record's lock.
#[derive(Clone)]
struct Claim {
    older: String,
    front: String,
    older_date: i64,
    front_date: i64,
    sender: Option<Value>,
}

/// Writes the claims, each older mail keeping the newest front to claim it.
fn apply(book: &mut Book, claims: Vec<Claim>, at: i64) {
    for claim in claims {
        if section(book, "refused").contains_key(&claim.older) {
            continue;
        }
        let existing_front = section(book, "covered").get(&claim.older).and_then(|row| row["frontDate"].as_i64());
        let record = json!({"front":claim.front,"frontDate":claim.front_date,"date":claim.older_date,"at":at});
        match claim.sender {
            None => {
                if existing_front.is_none_or(|date| date < claim.front_date) {
                    section_mut(book, "covered").insert(claim.older.clone(), record);
                    section_mut(book, "proposals").remove(&claim.older);
                }
            }
            Some(sender) => {
                let proposal_front = section(book, "proposals").get(&claim.older).and_then(|row| row["frontDate"].as_i64());
                if existing_front.is_none() && proposal_front.is_none_or(|date| date < claim.front_date) {
                    let mut proposal = record;
                    proposal["sender"] = sender;
                    section_mut(book, "proposals").insert(claim.older.clone(), proposal);
                }
            }
        }
    }
    for (name, limit) in [("covered", RECORDS), ("proposals", RECORDS), ("refused", REFUSALS)] {
        let entries = section_mut(book, name);
        if entries.len() <= limit {
            continue;
        }
        let mut oldest: Vec<(i64, String)> = entries.iter().map(|(id, row)| (row["at"].as_i64().or(row.as_i64()).unwrap_or(0), id.clone())).collect();
        oldest.sort();
        for (_, id) in oldest.into_iter().take(entries.len() - limit) {
            entries.remove(&id);
        }
    }
}

/// After a Point batch is stored: turns each accepted row's covers into bundles or proposals,
/// checking everything the writer's answer alone could not.
/// A failure here costs only the bundle; the Points are already saved.
pub(super) async fn record(account: &str, rows: &Value, incarnation: &str, local_mail: &LocalMail) {
    let wanted: Vec<&Value> = rows.as_array().map(Vec::as_slice).unwrap_or_default().iter().filter(|row| row["covers"].is_array() && row["text"].is_string()).collect();
    if wanted.is_empty() {
        return;
    }
    let Ok(inbox) = local_mail.inbox_ids(account).await else { return };
    let Some(guards) = Guards::load(account, local_mail).await else { return };
    let approved = approved_senders().unwrap_or_default();
    let mut claims = Vec::new();
    for row in wanted {
        let Some(front) = row["id"].as_str().filter(|id| inbox.contains(*id)) else { continue };
        let Some(front) = facts(account, front, local_mail).await else { continue };
        let Some(front_sender) = front.sender.clone() else { continue };
        if front.labelled("SENT") || front.labelled("DRAFT") {
            continue;
        }
        for cover in row["covers"].as_array().into_iter().flatten() {
            let Some(id) = cover["id"].as_str().filter(|id| *id != front.id && inbox.contains(*id)) else { continue };
            let Some(older) = facts(account, id, local_mail).await else { continue };
            if older.date >= front.date || !guards.point_written(id) || never_hidden(&older, &guards).is_some() {
                continue;
            }
            match decide(&front_sender, older.sender.as_ref(), &approved) {
                Decision::Separate => {}
                Decision::Cover => claims.push(Claim { older: id.to_owned(), front: front.id.clone(), older_date: older.date, front_date: front.date, sender: None }),
                Decision::Propose => claims.push(Claim { older: id.to_owned(), front: front.id.clone(), older_date: older.date, front_date: front.date, sender: Some(sender_key(&front_sender)) }),
            }
        }
    }
    if claims.is_empty() {
        return;
    }
    let at = now();
    let written = crate::account::with_incarnation(Some(incarnation), |_| {
        crate::mail::resolve_account(account)?;
        store::update(&book_key(account), |value| {
            let book = value.as_object_mut().ok_or("inbox_storage_invalid")?;
            apply(book, claims, at);
            Ok(())
        })
    });
    if let Err(error) = written {
        eprintln!("magpie: bundles not recorded: {error}");
    }
}

/// The older mail that goes back to being its own row, and the proposals that became covers,
/// against the current Inbox. Every older mail whose front has left or which may no longer be
/// hidden is released.
fn settle(book: &mut Book, inbox: &HashSet<String>, blocked: &HashSet<String>, converted: Vec<Claim>, at: i64) -> Vec<String> {
    apply(book, converted, at);
    let mut released = Vec::new();
    let gone: Vec<String> = section(book, "covered")
        .iter()
        .filter(|(older, row)| {
            let front = row["front"].as_str().unwrap_or("");
            inbox.contains(*older) && (!inbox.contains(front) || blocked.contains(*older))
        })
        .map(|(older, _)| older.clone())
        .collect();
    for older in gone {
        section_mut(book, "covered").remove(&older);
        released.push(older);
    }
    let stale: Vec<String> = section(book, "proposals")
        .iter()
        .filter(|(older, row)| !inbox.contains(*older) || !row["front"].as_str().is_some_and(|front| inbox.contains(front)) || section(book, "covered").contains_key(*older) || blocked.contains(*older))
        .map(|(older, _)| older.clone())
        .collect();
    for older in stale {
        section_mut(book, "proposals").remove(&older);
    }
    released
}

/// The account's bundles as the Inbox is now: each row's front and the mail behind it, a chain of
/// follow-ups flattened into one bundle, newest bundle first, each newest mail first.
fn resolved(book: &Book, inbox: &HashSet<String>) -> Value {
    use std::collections::BTreeMap;
    let covered = section(book, "covered");
    let root = |older: &str| -> Option<String> {
        let mut seen = HashSet::from([older.to_owned()]);
        let mut current = covered.get(older)?["front"].as_str()?.to_owned();
        while let Some(next) = covered.get(&current).filter(|_| inbox.contains(&current)).and_then(|row| row["front"].as_str()) {
            if !seen.insert(next.to_owned()) {
                return None;
            }
            current = next.to_owned();
        }
        inbox.contains(&current).then_some(current)
    };
    let mut groups: BTreeMap<String, Vec<(i64, String)>> = BTreeMap::new();
    for (older, row) in covered {
        if inbox.contains(older)
            && let Some(front) = root(older)
        {
            groups.entry(front).or_default().push((row["date"].as_i64().unwrap_or(0), older.clone()));
        }
    }
    let front_date = |front: &str| covered.get(front).and_then(|row| row["date"].as_i64()).unwrap_or(0).max(covered.values().filter(|row| row["front"] == front).filter_map(|row| row["frontDate"].as_i64()).max().unwrap_or(0));
    let mut bundles: Vec<(i64, Value)> = groups
        .into_iter()
        .map(|(front, mut members)| {
            members.sort_by(|a, b| b.cmp(a));
            let date = front_date(&front);
            (date, json!({"front":front,"covered":members.into_iter().map(|(_, id)| id).collect::<Vec<_>>()}))
        })
        .collect();
    bundles.sort_by(|a, b| b.0.cmp(&a.0));
    json!(bundles.into_iter().map(|(_, bundle)| bundle).collect::<Vec<_>>())
}

/// The proposals waiting for one tap, grouped by the mail that would stand in front.
fn proposals_view(book: &Book, inbox: &HashSet<String>) -> Value {
    use std::collections::BTreeMap;
    let mut groups: BTreeMap<String, (Value, Vec<(i64, String)>)> = BTreeMap::new();
    for (older, row) in section(book, "proposals") {
        let Some(front) = row["front"].as_str() else { continue };
        if !inbox.contains(older) || !inbox.contains(front) {
            continue;
        }
        groups.entry(front.to_owned()).or_insert_with(|| (row["sender"].clone(), Vec::new())).1.push((row["date"].as_i64().unwrap_or(0), older.clone()));
    }
    json!(
        groups
            .into_iter()
            .map(|(front, (sender, mut members))| {
                members.sort_by(|a, b| b.cmp(a));
                json!({"front":front,"covered":members.into_iter().map(|(_, id)| id).collect::<Vec<_>>(),"sender":sender})
            })
            .collect::<Vec<_>>()
    )
}

/// Asks for each released mail's Point to be written again, since it may be out of date by now.
fn mark_for_rewrite(account: &str, released: &[String]) -> Result<(), &'static str> {
    if released.is_empty() {
        return Ok(());
    }
    let at = now();
    store::update(&store::key(&["overviews", account]), |saved| {
        for id in released {
            if let Some(row) = saved.get_mut(id.as_str()).filter(|row| overview_current(row, at)) {
                row["contextChanged"] = json!(true);
            }
        }
        Ok(())
    })
}

/// The covered mail that may no longer be hidden, and the proposals that may now be automatic.
async fn survey(book: &Book, account: &str, inbox: &HashSet<String>, approved: &[Value], local_mail: &LocalMail) -> Option<(HashSet<String>, Vec<Claim>)> {
    let guards = Guards::load(account, local_mail).await?;
    let mut blocked = HashSet::new();
    let older_mail: Vec<String> = section(book, "covered").keys().chain(section(book, "proposals").keys()).filter(|id| inbox.contains(*id)).cloned().collect();
    for id in older_mail {
        // Invariant: a mail whose local copy cannot be read cannot be shown to be safe to hide.
        let may_hide = facts(account, &id, local_mail).await.is_some_and(|older| never_hidden(&older, &guards).is_none());
        if !may_hide {
            blocked.insert(id);
        }
    }
    let mut converted = Vec::new();
    for (older_id, row) in section(book, "proposals") {
        let Some(front_id) = row["front"].as_str() else { continue };
        if blocked.contains(older_id) || !inbox.contains(older_id) || !inbox.contains(front_id) {
            continue;
        }
        let (Some(older), Some(front)) = (facts(account, older_id, local_mail).await, facts(account, front_id, local_mail).await) else { continue };
        let older_proven = older.sender.as_ref().is_some_and(|sender| sender.proven);
        if older_proven && front.sender.as_ref().is_some_and(|sender| sender.proven && is_approved(sender, approved)) && older.date < front.date {
            converted.push(Claim { older: older_id.clone(), front: front_id.to_owned(), older_date: older.date, front_date: front.date, sender: None });
        }
    }
    Some((blocked, converted))
}

/// Settles the account's record against the Inbox now and returns what the clients show.
async fn list_settled(account: &str, local_mail: &LocalMail) -> Result<Value, &'static str> {
    let inbox = local_mail.inbox_ids(account).await?;
    let approved = approved_senders()?;
    let book = read_book(account)?;
    // Invariant: while a guard cannot be read nothing is hidden, and the record is left as it is.
    let Some((blocked, converted)) = survey(&book, account, &inbox, &approved, local_mail).await else {
        return Ok(json!({"bundles":[],"proposals":[]}));
    };
    let at = now();
    let mut settled = book.clone();
    let released = settle(&mut settled, &inbox, &blocked, converted.clone(), at);
    // Reading the list changes nothing unless the Inbox has moved on since the last read.
    if settled == book {
        return Ok(json!({"bundles":resolved(&settled, &inbox),"proposals":proposals_view(&settled, &inbox)}));
    }
    // Asked before the record changes, so a failure here is tried again at the next list.
    mark_for_rewrite(account, &released)?;
    let (view, also_released) = crate::account::with_incarnation(None, |_| {
        crate::mail::resolve_account(account)?;
        store::update(&book_key(account), |value| {
            let book = value.as_object_mut().ok_or("inbox_storage_invalid")?;
            let released = settle(book, &inbox, &blocked, converted, at);
            Ok((json!({"bundles":resolved(book, &inbox),"proposals":proposals_view(book, &inbox)}), released))
        })
    })?;
    mark_for_rewrite(account, &also_released)?;
    Ok(view)
}

/// The older mail ids a client passes to refuse: real Gmail ids only.
fn valid_ids(params: &Value) -> Result<Vec<String>, &'static str> {
    let values = params["ids"].as_array().filter(|values| !values.is_empty() && values.len() <= REFUSE_LIMIT).ok_or("invalid_params")?;
    let mut ids = Vec::new();
    for value in values {
        let id = value.as_str().ok_or("invalid_params")?;
        crate::mail::action::validate_message_id(crate::mail::Provider::Gmail, id)?;
        if !ids.iter().any(|known| known == id) {
            ids.push(id.to_owned());
        }
    }
    Ok(ids)
}

/// The sender of one mail, for an approval; refuses a mail Gmail did not prove.
async fn proven_sender(account: &str, id: &str, local_mail: &LocalMail) -> Result<Sender, &'static str> {
    facts(account, id, local_mail).await.and_then(|mail| mail.sender).filter(|sender| sender.proven).ok_or("bundle_not_proven")
}

/// The clients' API. Every id here is the client's, so it is checked like any Gmail id, and every
/// lookup stays within the named account.
pub(super) async fn call(method: &str, params: &Value, local_mail: &LocalMail) -> Result<Value, &'static str> {
    match method {
        "inbox.bundles" => {
            super::fields(params, &["accountId"])?;
            let account = super::account(params)?;
            list_settled(&account, local_mail).await
        }
        "inbox.approveBundle" => {
            super::fields(params, &["accountId", "front"])?;
            let account = super::account(params)?;
            let front = params["front"].as_str().ok_or("invalid_params")?;
            crate::mail::action::validate_message_id(crate::mail::Provider::Gmail, front)?;
            if !section(&read_book(&account)?, "proposals").values().any(|row| row["front"] == front) {
                return Err("bundle_not_found");
            }
            let sender = proven_sender(&account, front, local_mail).await?;
            approve_sender(&sender, now())?;
            list_settled(&account, local_mail).await
        }
        "inbox.refuseBundle" => {
            super::fields(params, &["accountId", "ids"])?;
            let account = super::account(params)?;
            let ids = valid_ids(params)?;
            let at = now();
            // Invariant: marked before the record changes, as when a list releases mail.
            let current = read_book(&account)?;
            let released: Vec<String> = ids.iter().filter(|id| section(&current, "covered").contains_key(*id)).cloned().collect();
            mark_for_rewrite(&account, &released)?;
            crate::account::with_incarnation(None, |_| {
                crate::mail::resolve_account(&account)?;
                store::update(&book_key(&account), |value| {
                    let book = value.as_object_mut().ok_or("inbox_storage_invalid")?;
                    for id in &ids {
                        section_mut(book, "refused").insert(id.clone(), json!(at));
                        section_mut(book, "proposals").remove(id);
                        section_mut(book, "covered").remove(id);
                    }
                    apply(book, Vec::new(), at);
                    Ok(())
                })
            })?;
            list_settled(&account, local_mail).await
        }
        "inbox.approvedSenders" => {
            super::fields(params, &[])?;
            Ok(json!({"senders":approved_senders()?}))
        }
        "inbox.removeApprovedSender" => {
            super::fields(params, &["email", "name"])?;
            let email = params["email"].as_str().filter(|email| !email.is_empty() && email.len() <= 320).ok_or("invalid_params")?.to_lowercase();
            let name = params["name"].as_str().ok_or("invalid_params")?;
            store::update(&approved_key(), |saved| {
                if !saved.is_object() {
                    *saved = json!({});
                }
                let mut senders = saved["senders"].as_array().cloned().unwrap_or_default();
                senders.retain(|entry| !(entry["email"] == email.as_str() && entry["name"] == name));
                saved["senders"] = json!(senders);
                Ok(())
            })?;
            Ok(json!({"senders":approved_senders()?}))
        }
        _ => Err("unknown_method"),
    }
}

#[cfg(test)]
#[path = "bundles_tests.rs"]
mod tests;
