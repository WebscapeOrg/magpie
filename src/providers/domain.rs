//! Authoritative mail capability and query mappings; labels and icons stay in QML.
use serde_json::{Value, json};
use std::sync::LazyLock;
static QUERIES: LazyLock<Value> =
    LazyLock::new(|| serde_json::from_str(include_str!("domain_queries.json")).unwrap());
fn provider(value: &Value) -> &str {
    match value.as_str().unwrap_or("").trim() {
        id if QUERIES.get(id).is_some() => id,
        _ => "gmail",
    }
}
/// Canonical mailbox query shared by native background readers and UI snapshots.
pub fn mailbox_query(id: &str, mailbox: &str) -> Option<&'static str> {
    QUERIES.get(id)?.get(mailbox)?.as_str()
}
/// Canonical mailbox names are public; provider query keys may use an alias.
pub fn query_mailbox(id: &str, mailbox: &str) -> Option<String> {
    let mapped = match (id, mailbox) {
        ("gmail", "archive") => "all",
        _ => mailbox,
    };
    mailbox_query(id, mapped)
        .is_some()
        .then(|| mapped.to_owned())
}
fn quoted(text: &str) -> String {
    serde_json::to_string(text).unwrap()
}
fn gmail_label(text: &str) -> String {
    if text
        .chars()
        .all(|character| character.is_alphanumeric() || "_-/.".contains(character))
    {
        return format!("label:{text}");
    }
    format!("label:{}", quoted(text))
}
fn search_operators() -> Value {
    json!([
        {"operator":"from","values":["me"],"example":"from:ada@example.org","description":"Messages from a sender","primary":true},
        {"operator":"to","values":["me"],"example":"to:me","description":"Messages sent to a recipient","primary":true},
        {"operator":"subject","values":[],"example":"subject:invoice","description":"Words in the subject","primary":true},
        {"operator":"is","values":["read","unread","starred","important"],"example":"is:unread","description":"Read, unread, starred or important messages","primary":true},
        {"operator":"label","values":[],"example":"label:\"Work projects\"","description":"Messages with a label","primary":true},
        {"operator":"in","values":["inbox","sent","drafts","spam","trash","anywhere"],"example":"in:inbox","description":"Messages in a folder","primary":true},
        {"operator":"has","values":["attachment"],"example":"has:attachment","description":"Messages with file attachments","primary":true},
        {"operator":"filename","values":[],"example":"filename:pdf","description":"An attachment name or file type","primary":true},
        {"operator":"after","values":[],"example":"after:2026/10/01","description":"Messages after a date in Pacific Standard Time","primary":true},
        {"operator":"before","values":[],"example":"before:2026/11/01","description":"Messages before a date in Pacific Standard Time","primary":true},
        {"operator":"newer_than","values":[],"example":"newer_than:7d","description":"Messages newer than days, months or years","primary":false},
        {"operator":"older_than","values":[],"example":"older_than:1y","description":"Messages older than days, months or years","primary":false}
    ])
}
fn imap_search(text: &str) -> String {
    static TERMS: LazyLock<regex::Regex> = LazyLock::new(|| {
        regex::Regex::new(r#"(?i)(from|to|subject):\s*(?:"([^"]*)"|(\S*))|(\S+)"#).unwrap()
    });
    let mut words = Vec::new();
    let mut parts = Vec::new();
    for term in TERMS.captures_iter(text) {
        if let Some(field) = term.get(1) {
            let value = term
                .get(2)
                .or_else(|| term.get(3))
                .map(|v| v.as_str())
                .unwrap_or("")
                .replace('*', "");
            if value.is_empty() {
                words.push(term[0].to_owned());
            } else {
                parts.push(format!(
                    "{} {}",
                    field.as_str().to_uppercase(),
                    quoted(&value)
                ));
            }
        } else if let Some(word) = term.get(4) {
            words.push(word.as_str().into());
        }
    }
    let plain = words.join(" ");
    if !plain.trim().is_empty() {
        parts.push(format!("TEXT {}", quoted(plain.trim())));
    }
    if parts.is_empty() {
        parts.push(format!("TEXT {}", quoted(text)));
    }
    format!("search:{}", parts.join(" "))
}
fn search(id: &str, text: &str) -> String {
    if text.is_empty() {
        return String::new();
    }
    match id {
        "imap" | "outlook" => imap_search(text),
        "hey" => format!("search:{text}"),
        "jmap" => format!("text:{text}"),
        _ => text.into(),
    }
}
fn encode(text: &str) -> String {
    let mut out = String::new();
    for b in text.bytes() {
        if b.is_ascii_alphanumeric() || b"-_.!~*'()".contains(&b) {
            out.push(b as char);
        } else {
            use std::fmt::Write;
            write!(&mut out, "%{b:02X}").unwrap();
        }
    }
    out
}
pub fn snapshot() -> Value {
    let mut snapshot = json!({});
    for provider in super::list().as_array().unwrap() {
        let id = provider["id"].as_str().unwrap();
        snapshot[id] = json!({"capabilities":provider["capabilities"],"queries":QUERIES[id],"nativeSync":true,"inheritedDefault":"in:inbox","addressSearch":matches!(id,"gmail"|"hey"|"imap"),"webHomeUrl":match id {"gmail"=>"https://mail.google.com/mail/u/0/","hey"=>"https://app.hey.com","outlook"=>"https://outlook.live.com/mail/",_=>""}});
        if id == "gmail" {
            snapshot[id]["searchSyntax"] = json!("gmail");
            snapshot[id]["searchOperators"] = search_operators();
        }
    }
    snapshot
}
pub fn resolve(params: &Value) -> Result<Value, &'static str> {
    if !params.is_object() {
        return Err("invalid_params");
    }
    let canonical = params["provider"]
        .as_str()
        .unwrap_or("")
        .trim()
        .to_lowercase();
    let id = provider(&Value::String(canonical)).to_owned();
    let value = params["value"].as_str().unwrap_or("");
    let text = value.trim();
    if ["value", "search", "defaultQuery"].iter().any(|key| {
        params[*key].as_str().is_some_and(|value| {
            value.len() > 32768 || value.chars().any(|character| character.is_control())
        })
    }) {
        return Err("invalid_params");
    }
    let result = match params["operation"].as_str().unwrap_or("query") {
        "query" => {
            let search_text = params["search"].as_str().unwrap_or("").trim();
            let custom = params["defaultQuery"].as_str().unwrap_or("").trim();
            let mailbox = params["mailbox"].as_str().unwrap_or("inbox");
            if !search_text.is_empty() {
                search(&id, search_text)
            } else if mailbox == "inbox"
                && !custom.is_empty()
                && (id == "gmail" || custom != "in:inbox")
            {
                custom.into()
            } else {
                QUERIES[&id]
                    .get(mailbox)
                    .unwrap_or(&QUERIES[&id]["inbox"])
                    .as_str()
                    .unwrap_or("")
                    .into()
            }
        }
        "labelQuery" => {
            if text.is_empty() {
                String::new()
            } else {
                match id.as_str() {
                    "imap" | "outlook" => format!("folder:{}", quoted(text)),
                    "jmap" => format!("mailbox:{text}"),
                    "gmail" => gmail_label(text),
                    _ => format!("label:{text}"),
                }
            }
        }
        "addressQuery" => {
            if text.is_empty() {
                String::new()
            } else {
                let to = params["field"] == "to";
                match id.as_str() {
                    "gmail"
                        if !text
                            .chars()
                            .any(|character| character.is_whitespace() || character == '"') =>
                    {
                        format!("{}:{text}", if to { "to" } else { "from" })
                    }
                    "imap" => format!("search:{} {}", if to { "TO" } else { "FROM" }, quoted(text)),
                    "hey" => format!("search:{text}"),
                    _ => String::new(),
                }
            }
        }
        "webMessageUrl" => match id.as_str() {
            "gmail" => format!("https://mail.google.com/mail/u/0/#all/{}", encode(value)),
            "hey" => {
                let topic = text.split(':').nth(1).unwrap_or("").trim();
                if topic.is_empty() {
                    "https://app.hey.com".into()
                } else {
                    format!("https://app.hey.com/topics/{topic}")
                }
            }
            _ => String::new(),
        },
        "webBoxUrl" => {
            if id == "gmail" {
                format!("https://mail.google.com/mail/u/0/#search/{}", encode(value))
            } else {
                String::new()
            }
        }
        _ => return Err("invalid_params"),
    };
    let mut response = json!({"value":result});
    if id == "gmail" && params["operation"].as_str().unwrap_or("query") == "query" {
        let input = params["search"].as_str().unwrap_or("").trim();
        if !input.is_empty() {
            let account = match params.get("accountId") {
                None => "",
                Some(Value::String(value))
                    if value.len() <= 1024 && !value.chars().any(char::is_control) =>
                {
                    value.as_str()
                }
                _ => return Err("invalid_params"),
            };
            let as_of = match params.get("asOf") {
                None => chrono::Utc::now().timestamp_millis(),
                Some(value) => value
                    .as_i64()
                    .filter(|value| (0..=9_007_199_254_740_991).contains(value))
                    .ok_or("invalid_params")?,
            };
            response["search"] = crate::local_mail::search_metadata(input, account, as_of);
        }
    }
    Ok(response)
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn gmail_operator_catalogue_is_explicit_and_does_not_change_other_providers() {
        let facts = snapshot();
        assert_eq!(facts["gmail"]["searchSyntax"], "gmail");
        let operators = facts["gmail"]["searchOperators"].as_array().unwrap();
        assert_eq!(operators.len(), 12);
        assert_eq!(
            operators
                .iter()
                .filter(|entry| entry["primary"] == true)
                .count(),
            10
        );
        for provider in ["imap", "outlook", "hey", "jmap"] {
            assert!(facts[provider].get("searchSyntax").is_none());
            assert!(facts[provider].get("searchOperators").is_none());
        }
        for entry in operators {
            let metadata = crate::local_mail::search_metadata(
                entry["example"].as_str().unwrap(),
                "reader@example.org",
                1_792_665_600_000,
            );
            assert_eq!(metadata["valid"], true, "{entry}");
            assert_eq!(metadata["localSupported"], true, "{entry}");
        }
    }

    #[test]
    fn gmail_query_preparation_preserves_text_and_returns_parser_metadata() {
        let query = r#"from:me (is:unread OR label:"Work (2026)") newer_than:7d"#;
        let result = resolve(&json!({"provider":"gmail","operation":"query",
            "accountId":"reader@example.org","asOf":1_792_665_600_000_i64,"search":query}))
        .unwrap();
        assert_eq!(result["value"], query);
        assert_eq!(result["search"]["valid"], true);
        assert_eq!(result["search"]["localSupported"], true);
        assert_eq!(result["search"]["structured"], true);
        assert!(result["search"]["error"].is_null());
        let unsupported = resolve(&json!({"provider":"gmail","search":"larger:1M"})).unwrap();
        assert_eq!(unsupported["value"], "larger:1M");
        assert_eq!(unsupported["search"]["valid"], true);
        assert_eq!(unsupported["search"]["localSupported"], false);
        let malformed = resolve(&json!({"provider":"gmail","search":"from:"})).unwrap();
        assert_eq!(malformed["search"]["valid"], false);
        assert!(
            malformed["search"]["error"]
                .as_str()
                .is_some_and(|value| !value.is_empty())
        );
        let plain = resolve(&json!({"provider":"gmail","search":"invoice"})).unwrap();
        assert_eq!(plain["search"]["structured"], false);
        let oversized = resolve(&json!({"provider":"gmail","search":"é".repeat(4097)})).unwrap();
        assert_eq!(oversized["search"]["valid"], false);
        assert_eq!(oversized["search"]["error"], "local_search_too_long");
        let imap = resolve(&json!({"provider":"imap","search":"from:me"})).unwrap();
        assert_eq!(imap["value"], r#"search:FROM "me""#);
        assert!(imap.get("search").is_none());
    }

    #[test]
    fn gmail_preparation_rejects_untyped_context_before_returning_a_query() {
        for invalid in [
            json!(-1),
            json!(9_007_199_254_740_992_i64),
            json!(1.5),
            json!("now"),
            Value::Null,
        ] {
            assert_eq!(
                resolve(&json!({"provider":"gmail","search":"newer_than:1d","asOf":invalid})),
                Err("invalid_params")
            );
        }
        for invalid in [json!(17), json!("reader@example.org\n"), Value::Null] {
            assert_eq!(
                resolve(&json!({"provider":"gmail","search":"from:me","accountId":invalid})),
                Err("invalid_params")
            );
        }
    }

    #[test]
    fn gmail_labels_quote_query_delimiters_without_changing_safe_names() {
        for (label, expected) in [
            ("Work", "label:Work"),
            ("Projects/2026", "label:Projects/2026"),
            ("Old Mail", r#"label:"Old Mail""#),
            ("Work (2026)", r#"label:"Work (2026)""#),
            ("é\"\\folder", r#"label:"é\"\\folder""#),
            ("x OR in:anywhere", r#"label:"x OR in:anywhere""#),
        ] {
            assert_eq!(
                resolve(&json!({"provider":"gmail","operation":"labelQuery","value":label}))
                    .unwrap()["value"],
                expected
            );
        }
    }
    #[test]
    fn control_bytes_are_rejected_before_any_query_or_url_is_returned() {
        for id in ["gmail", "outlook", "hey", "jmap", "imap"] {
            for suffix in ["\r", "\n", "\r\n", "\0", "\t", "\u{7f}"] {
                for operation in ["labelQuery", "addressQuery", "webMessageUrl", "webBoxUrl"] {
                    assert_eq!(
                        resolve(
                            &json!({"provider":id,"operation":operation,"value":format!("valid{suffix}")})
                        ),
                        Err("invalid_params")
                    );
                }
                assert_eq!(
                    resolve(&json!({"provider":id,"search":format!("valid{suffix}")})),
                    Err("invalid_params")
                );
                assert_eq!(
                    resolve(&json!({"provider":id,"defaultQuery":format!("valid{suffix}")})),
                    Err("invalid_params")
                );
            }
        }
    }
    #[test]
    fn matches_provider_query_and_web_fixtures_with_account_wide_imap_search() {
        let cases: Value =
            serde_json::from_str(include_str!("../../tests/provider_domain_parity.json")).unwrap();
        for case in cases.as_array().unwrap() {
            // Invariant: Legacy fixtures predate account-wide IMAP search. Folder browsing
            // is unchanged; only resolved search/address queries change scope.
            let expected = case["expected"].as_str().unwrap();
            let expected = if expected.starts_with("folder:INBOX ")
                && (case["params"]["search"]
                    .as_str()
                    .is_some_and(|s| !s.trim().is_empty())
                    || case["params"]["operation"] == "addressQuery")
            {
                expected.replacen("folder:INBOX ", "search:", 1)
            } else {
                expected.to_owned()
            };
            assert_eq!(
                resolve(&case["params"]).unwrap()["value"],
                expected,
                "{}",
                case["params"]
            );
        }
    }
    #[test]
    fn generated_ui_descriptor_matches_native_authority() {
        let source = include_str!("../../ui/providers/NativeDomain.js");
        let value: Value =
            serde_json::from_str(source.split_once("var FACTS = ").unwrap().1.trim()).unwrap();
        assert_eq!(value, snapshot());
    }
}
