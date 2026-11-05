//! What The Point reads each email against. Shared by every email in a run: the owner's bio and
//! their recent sent mail and other Inbox mail, from every account on this device. For each email:
//! the earlier messages in its thread and recent mail with the same sender.
//! Invariant: everything here is bounded in count and characters and read from the local replica
//! only, never from Gmail; a part that cannot be read is left out rather than failing the email.
//! The bio is the owner's own text, kept in this device's private state and never logged.
use super::{describe::ABOUT_YOU_LIMIT, store};
use serde_json::{Value, json};

const SENT: usize = 40;
const INBOX: usize = 40;
const THREAD: usize = 6;
const THREAD_CHARS: usize = 4000;
const RELATED: usize = 6;
const SNIPPET_CHARS: usize = 300;
const ADDRESSES: usize = 10;

fn about_key() -> String {
    store::key(&["about-you"])
}

/// The owner's bio as they last saved it, or None when they have not written one.
pub(crate) fn about_you() -> Result<Option<String>, &'static str> {
    Ok(store::read(&about_key())?
        .and_then(|saved| saved["text"].as_str().map(str::to_owned))
        .filter(|text| !text.trim().is_empty()))
}

/// Characters a bio may not hold: controls other than line breaks and tabs, invisible format
/// characters, and the markup brackets no list text may carry.
fn refused(c: char) -> bool {
    (c.is_control() && c != '\n' && c != '\t')
        || matches!(c as u32, 0x200b..=0x200f | 0x202a..=0x202e | 0x2060..=0x206f | 0xfeff)
        || c == '<'
        || c == '>'
}

/// Saves the bio, or removes it when the text is empty. Returns what is now saved.
pub(crate) fn set_about_you(text: &str) -> Result<Value, &'static str> {
    let text = text.trim();
    if text.chars().count() > ABOUT_YOU_LIMIT || text.chars().any(refused) {
        return Err("invalid_params");
    }
    if text.is_empty() {
        if store::read(&about_key())?.is_some() {
            store::remove(&about_key())?;
        }
        return Ok(json!({"text":"","updated":0}));
    }
    let saved = json!({"text":text,"updated":super::now()});
    store::replace(&about_key(), &saved)?;
    Ok(saved)
}

/// The saved bio for the settings screen.
pub(crate) fn about_you_page() -> Result<Value, &'static str> {
    let saved = store::read(&about_key())?.unwrap_or(json!({}));
    Ok(json!({"text":saved["text"].as_str().unwrap_or(""),"updated":saved["updated"].as_i64().unwrap_or(0),"limit":ABOUT_YOU_LIMIT}))
}

fn clipped(text: &str, limit: usize) -> String {
    let text = text.trim();
    if text.chars().count() <= limit {
        return text.to_owned();
    }
    let mut cut: String = text.chars().take(limit.saturating_sub(1)).collect();
    cut.push('…');
    cut
}

fn addresses(list: &Value) -> Value {
    json!(list.as_array().map(|items| items.iter().take(ADDRESSES).cloned().collect::<Vec<_>>()).unwrap_or_default())
}

/// One list row of mail as context: who, when, what, and its first lines.
fn entry(summary: &Value, account: &str) -> Value {
    json!({
        "id": summary["id"],
        "account": account,
        "from": summary["from"],
        "to": addresses(&summary["to"]),
        "cc": addresses(&summary["cc"]),
        "date": summary["date"],
        "subject": summary["subject"],
        "snippet": clipped(summary["snippet"].as_str().unwrap_or(""), SNIPPET_CHARS),
        "threadId": summary["threadId"],
        "hasAttachments": summary["hasAttachments"],
    })
}

async fn listed(local_mail: &crate::local_mail::LocalMail, account: &str, query: &str, limit: usize) -> Vec<Value> {
    let Ok(page) = local_mail
        .call("local.list", &json!({"accountId":account,"query":query,"limit":limit}))
        .await
    else {
        return Vec::new();
    };
    page["summaries"]
        .as_array()
        .map(|rows| rows.iter().take(limit).map(|summary| entry(summary, account)).collect())
        .unwrap_or_default()
}

fn newest(mut rows: Vec<Value>, limit: usize) -> Vec<Value> {
    rows.sort_by(|a, b| b["date"].as_str().unwrap_or("").cmp(a["date"].as_str().unwrap_or("")));
    rows.truncate(limit);
    rows
}

/// The accounts on this device.
pub(crate) fn accounts() -> Vec<String> {
    crate::account::list_readonly()
        .ok()
        .and_then(|list| {
            list["accounts"]
                .as_array()
                .map(|accounts| accounts.iter().filter_map(|account| account["id"].as_str().filter(|id| !id.is_empty()).map(str::to_owned)).collect())
        })
        .unwrap_or_default()
}

/// The context every email in a run shares, ordered from what changes least to what changes most,
/// so a cached request stays the same for as long as possible.
/// With `network` false (the iPhone's short background run) the calendar is what was read before.
pub(crate) async fn shared(local_mail: &crate::local_mail::LocalMail, gmail: &crate::providers::gmail::Session, network: bool) -> Value {
    let accounts = accounts();
    let mut sent = Vec::new();
    let mut inbox = Vec::new();
    for account in &accounts {
        sent.extend(listed(local_mail, account, "in:sent newer_than:14d", SENT).await);
        inbox.extend(listed(local_mail, account, "in:inbox", INBOX).await);
    }
    let mut context = json!({"sent":newest(sent, SENT),"inbox":newest(inbox, INBOX)});
    let calendar = super::calendar::events(gmail, &accounts, network).await;
    if !calendar.is_empty() {
        context["calendar"] = json!(calendar);
    }
    if let Ok(Some(about)) = about_you() {
        context["aboutYou"] = json!(clipped(&about, ABOUT_YOU_LIMIT));
    }
    context
}

/// An address the local search may be asked about: plain characters only, so it is never read as
/// more than one search term.
fn searchable(email: &str) -> Option<&str> {
    let (name, domain) = email.split_once('@')?;
    let plain = |part: &str, extra: &[u8]| !part.is_empty() && part.bytes().all(|b| b.is_ascii_alphanumeric() || extra.contains(&b));
    (email.len() <= 254 && plain(name, b"._%+-") && plain(domain, b".-") && domain.contains('.')).then_some(email)
}

/// Adds the earlier messages of the email's thread and recent mail with its sender, both from
/// this account's local replica.
pub(crate) async fn add_related(account: &str, raw: &Value, message: &mut Value, local_mail: &crate::local_mail::LocalMail) {
    let Ok(summary) = crate::message::content::summarize(raw, super::now()) else {
        return;
    };
    let id = summary["id"].as_str().unwrap_or("").to_owned();
    let mut thread = Vec::new();
    let mut seen = std::collections::HashSet::from([id.clone()]);
    if let Some(thread_id) = summary["threadId"].as_str().filter(|thread| !thread.is_empty()) {
        for other in local_mail.thread_ids(account, thread_id, THREAD + 1).await.unwrap_or_default() {
            if !seen.insert(other.clone()) || thread.len() == THREAD {
                continue;
            }
            let Ok(Some(resource)) = local_mail.resource(account, &other).await else { continue };
            let Ok(prepared) = crate::message::content::prepare(&resource, super::now()) else { continue };
            let earlier = &prepared["summary"];
            thread.push(json!({
                "id": other,
                "from": earlier["from"],
                "to": addresses(&earlier["to"]),
                "date": earlier["date"],
                "subject": earlier["subject"],
                "sentByOwner": earlier["isSent"],
                "body": clipped(prepared["body"]["text"].as_str().unwrap_or(""), THREAD_CHARS),
            }));
        }
    }
    let mut related = Vec::new();
    let sender = summary["from"]["email"].as_str().unwrap_or("").to_lowercase();
    if let Some(sender) = searchable(&sender).filter(|sender| *sender != account.to_lowercase()) {
        let mut rows = listed(local_mail, account, &format!("from:{sender} newer_than:60d"), RELATED).await;
        rows.extend(listed(local_mail, account, &format!("in:sent to:{sender} newer_than:60d"), RELATED).await);
        for row in newest(rows, RELATED * 2) {
            let Some(other) = row["id"].as_str() else { continue };
            if seen.insert(other.to_owned()) && related.len() < RELATED {
                related.push(row);
            }
        }
    }
    if !thread.is_empty() {
        message["thread"] = json!(thread);
    }
    if !related.is_empty() {
        message["related"] = json!(related);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_a_plain_address_is_searched() {
        assert_eq!(searchable("sam.o'neil@example.test"), None);
        assert_eq!(searchable("sam@example.test OR in:trash"), None);
        assert_eq!(searchable("sam@localhost"), None);
        assert_eq!(searchable("sam+news@mail.example.test"), Some("sam+news@mail.example.test"));
    }

    #[test]
    fn context_text_is_cut_at_its_limit_with_an_ellipsis() {
        assert_eq!(clipped("  short  ", 10), "short");
        let cut = clipped(&"é".repeat(400), SNIPPET_CHARS);
        assert_eq!(cut.chars().count(), SNIPPET_CHARS);
        assert!(cut.ends_with('…'));
    }

    #[test]
    fn a_bio_refuses_invisible_and_control_characters_but_keeps_line_breaks() {
        assert!(!refused('\n') && !refused('\t') && !refused('é'));
        for c in ['\u{0}', '\r', '\u{202e}', '\u{200b}', '\u{feff}', '<', '>'] {
            assert!(refused(c), "{c:?}");
        }
    }

    #[test]
    fn the_newest_rows_come_first_and_the_list_is_bounded() {
        let rows = (0..50).map(|day| json!({"id":day.to_string(),"date":format!("2026-10-{:02}T00:00:00.000Z", day % 28 + 1)})).collect();
        let kept = newest(rows, SENT);
        assert_eq!(kept.len(), SENT);
        assert!(kept.windows(2).all(|pair| pair[0]["date"].as_str() >= pair[1]["date"].as_str()));
    }
}
