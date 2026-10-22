use super::{include_spam_trash, is_structured, parse_with_context, pending_match};
use rusqlite::{Connection, params, params_from_iter};
use serde_json::{Value, json};
use std::collections::HashMap;

const ACCOUNT: &str = "owner@one.example";
const DAY_MS: i64 = 86_400_000;

struct Message<'a> {
    id: &'a str,
    sender: &'a str,
    recipients: &'a str,
    copied: &'a str,
    subject: &'a str,
    filenames: &'a str,
    body: &'a str,
    date: i64,
    attachment: bool,
    labels: &'a [&'a str],
}

fn message<'a>(id: &'a str, body: &'a str) -> Message<'a> {
    Message {
        id,
        sender: "Sender <sender@example.org>",
        recipients: "Owner <owner@one.example>",
        copied: "",
        subject: "",
        filenames: "",
        body,
        date: 1_700_000_000_000,
        attachment: false,
        labels: &["INBOX"],
    }
}

struct Mailbox {
    db: Connection,
}

fn address(value: &str) -> Value {
    let email = value
        .rsplit_once('<')
        .map_or(value, |(_, email)| email.trim_end_matches('>'))
        .trim();
    json!({"email": email})
}

fn addresses(value: &str) -> Vec<Value> {
    value
        .split(',')
        .filter(|value| !value.is_empty())
        .map(address)
        .collect()
}

impl Mailbox {
    fn new() -> Self {
        let db = Connection::open_in_memory().unwrap();
        db.execute_batch(include_str!("schema.sql")).unwrap();
        Self { db }
    }

    fn insert(&self, message: Message<'_>) {
        let summary = json!({
            "id": message.id,
            "from": address(message.sender),
            "to": addresses(message.recipients),
            "cc": addresses(message.copied),
        });
        self.db
            .execute(
                "INSERT INTO messages(id,thread_id,date,summary,blob,server_labels,sender,recipients,copied,subject,filenames,has_attachment,text_complete) VALUES (?1,?1,?2,?9,'{}','[]',?3,?4,?5,?6,?7,?8,1)",
                params![message.id, message.date, message.sender, message.recipients, message.copied, message.subject, message.filenames, message.attachment, summary.to_string()],
            )
            .unwrap();
        let rowid = self.db.last_insert_rowid();
        self.db
            .execute(
                "INSERT INTO search(rowid,id,subject,sender,recipients,copied,filenames,body) VALUES (?1,?2,?3,?4,?5,?6,?7,?8)",
                params![rowid, message.id, message.subject, message.sender, message.recipients, message.copied, message.filenames, message.body],
            )
            .unwrap();
        for label in message.labels {
            self.db
                .execute(
                    "INSERT INTO labels(message_id,label) VALUES (?1,?2)",
                    params![message.id, label],
                )
                .unwrap();
        }
    }

    fn label(&self, id: &str, name: &str) {
        self.db
            .execute(
                "INSERT INTO label_names(id,name) VALUES (?1,?2)",
                params![id, name],
            )
            .unwrap();
    }

    fn results(&self, input: &str) -> Vec<String> {
        self.results_at(input, ACCOUNT, 1_800_000_000_000)
    }

    fn results_at(&self, input: &str, account: &str, anchor_ms: i64) -> Vec<String> {
        let query = parse_with_context(input, account, anchor_ms)
            .unwrap_or_else(|error| panic!("{input:?}: {error}"));
        self.db
            .prepare(&format!(
                "SELECT id FROM messages m WHERE {} ORDER BY id",
                query.sql
            ))
            .unwrap()
            .query_map(params_from_iter(query.values), |row| row.get(0))
            .unwrap_or_else(|error| panic!("{input:?}: {error}"))
            .collect::<rusqlite::Result<Vec<String>>>()
            .unwrap()
    }
}

#[test]
fn boolean_groups_preserve_and_precedence_and_group_negation() {
    let mailbox = Mailbox::new();
    for (id, body) in [
        ("a", "alpha beta"),
        ("b", "alpha gamma"),
        ("c", "beta"),
        ("d", "gamma"),
        ("e", "delta beta"),
    ] {
        mailbox.insert(message(id, body));
    }
    for (query, expected) in [
        ("alpha OR beta gamma", vec!["a", "b"]),
        ("(alpha OR beta) gamma", vec!["b"]),
        ("alpha AND (beta OR gamma)", vec!["a", "b"]),
        ("{alpha gamma} -beta", vec!["b", "d"]),
        ("-(alpha OR beta)", vec!["d"]),
        ("{alpha {gamma delta}} -beta", vec!["b", "d"]),
    ] {
        assert_eq!(mailbox.results(query), expected, "{query}");
    }
}

#[test]
fn quoted_values_keep_group_characters_colons_and_escaped_quotes_literal() {
    let mailbox = Mailbox::new();
    mailbox.label("Label_board", "Board (2026)");
    mailbox.label("Label_quotes", "R&D \"North\"");
    mailbox.label("Label_unicode", "日本語 {重要}");
    mailbox.insert(Message {
        subject: "A report (approved)",
        labels: &["Label_board"],
        ..message("board", "The exact phrase from:alice is quoted here")
    });
    mailbox.insert(Message {
        subject: "A report rejected",
        labels: &["Label_quotes"],
        ..message("quotes", "The exact quoted \"approval\" arrived")
    });
    mailbox.insert(Message {
        labels: &["Label_unicode"],
        ..message("unicode", "その他の本文")
    });
    for (query, expected) in [
        (r#"label:"Board (2026)""#, vec!["board"]),
        (r#"label:"R&D \"North\"""#, vec!["quotes"]),
        (r#"label:"日本語 {重要}""#, vec!["unicode"]),
        (r#"subject:"report (approved)""#, vec!["board"]),
        ("subject:(report approved)", vec!["board"]),
        (
            r#"subject:("report (approved)" OR rejected)"#,
            vec!["board", "quotes"],
        ),
        (r#""from:alice""#, vec!["board"]),
        (r#""quoted \"approval\"""#, vec!["quotes"]),
    ] {
        assert_eq!(mailbox.results(query), expected, "{query}");
    }
}

#[test]
fn read_status_uses_effective_labels_even_when_server_labels_disagree() {
    let mailbox = Mailbox::new();
    mailbox.insert(Message {
        labels: &["INBOX", "UNREAD"],
        ..message("unread", "")
    });
    mailbox.insert(message("read", ""));
    assert_eq!(mailbox.results("is:read"), vec!["read"]);
    assert_eq!(mailbox.results("is:unread"), vec!["unread"]);
    assert_eq!(mailbox.results("-is:read"), vec!["unread"]);
    mailbox
        .db
        .execute(
            "UPDATE messages SET server_labels='[\"INBOX\",\"UNREAD\"]' WHERE id='unread'",
            [],
        )
        .unwrap();
    mailbox
        .db
        .execute(
            "DELETE FROM labels WHERE message_id='unread' AND label='UNREAD'",
            [],
        )
        .unwrap();
    assert_eq!(mailbox.results("is:read"), vec!["read", "unread"]);
    assert!(mailbox.results("is:unread").is_empty());
}

#[test]
fn full_addresses_use_boundaries_and_me_is_scoped_to_the_account() {
    let mailbox = Mailbox::new();
    mailbox.insert(Message {
        sender: "Amy <amy@example.org>",
        recipients: "Team <team@example.org>, Owner <OWNER@ONE.EXAMPLE>",
        ..message("amy", "")
    });
    mailbox.insert(Message {
        sender: "Someone <notamy@example.org>",
        recipients: "Other <notowner@one.example>",
        ..message("notamy", "")
    });
    mailbox.insert(Message {
        sender: "Amy <amy@example.org.evil>",
        recipients: "Owner <owner@one.example.evil>",
        ..message("suffix", "")
    });
    mailbox.insert(Message {
        sender: "Owner <OWNER@ONE.EXAMPLE>",
        recipients: "Second <owner@two.example>",
        ..message("owner", "")
    });
    mailbox.insert(Message {
        sender: "\"amy@example.org\" <stranger@elsewhere.net>",
        recipients: "\"owner@one.example\" <stranger@elsewhere.net>",
        ..message("decoy", "")
    });
    assert_eq!(mailbox.results("from:amy@example.org"), vec!["amy"]);
    assert_eq!(mailbox.results("to:owner@one.example"), vec!["amy"]);
    assert_eq!(mailbox.results("from:me"), vec!["owner"]);
    assert_eq!(mailbox.results("to:me"), vec!["amy"]);
    assert_eq!(
        mailbox.results("from:(amy@example.org OR owner@one.example)"),
        vec!["amy", "owner"]
    );
    assert_eq!(
        mailbox.results_at("to:me", "owner@two.example", 0),
        vec!["owner"]
    );
    assert!(
        mailbox
            .results_at("from:me", "owner@two.example", 0)
            .is_empty()
    );
    assert_eq!(
        mailbox.results("from:example.org"),
        vec!["amy", "decoy", "notamy", "suffix"]
    );
}

#[test]
fn exact_unicode_addresses_preserve_non_ascii_characters() {
    let mailbox = Mailbox::new();
    mailbox.insert(Message {
        sender: "Sender <Ä@example.org>",
        recipients: "Recipient <Ü@example.org>",
        copied: "Copied <Ö@example.org>",
        ..message("unicode", "")
    });
    for input in ["from:Ä@example.org", "to:Ü@example.org", "cc:Ö@example.org"] {
        assert_eq!(mailbox.results(input), vec!["unicode"], "{input}");
    }
}

#[test]
fn filename_wildcards_are_literal_and_attachment_presence_is_independent() {
    let mailbox = Mailbox::new();
    mailbox.insert(Message {
        filenames: "quarter_100%.PDF",
        attachment: true,
        ..message("literal", "")
    });
    mailbox.insert(Message {
        filenames: "quarterX100anything.pdf",
        attachment: true,
        ..message("other", "")
    });
    mailbox.insert(message("plain", "quarter_100%.PDF"));
    assert_eq!(mailbox.results("filename:quarter_100%"), vec!["literal"]);
    assert_eq!(
        mailbox.results("has:attachment filename:pdf"),
        vec!["literal", "other"]
    );
    assert_eq!(mailbox.results("-has:attachment"), vec!["plain"]);
}

#[test]
fn absolute_dates_use_pst_and_epoch_seconds_with_the_same_boundaries() {
    let mailbox = Mailbox::new();
    let cutoff = chrono::DateTime::parse_from_rfc3339("2026-10-22T08:00:00Z")
        .unwrap()
        .timestamp_millis();
    for (id, date) in [
        ("before", cutoff - 1),
        ("exact", cutoff),
        ("later", cutoff + 1),
    ] {
        mailbox.insert(Message {
            date,
            ..message(id, "")
        });
    }
    for query in [
        "before:2026/10/22",
        "before:2026-10-22",
        "before:10/22/2026",
    ] {
        assert_eq!(mailbox.results(query), vec!["before"], "{query}");
    }
    for query in ["after:2026/10/22", "after:2026-10-22", "after:10/22/2026"] {
        assert_eq!(mailbox.results(query), vec!["exact", "later"], "{query}");
    }
    assert_eq!(
        mailbox.results(&format!("before:{}", cutoff / 1000)),
        vec!["before"]
    );
    assert_eq!(
        mailbox.results(&format!("after:{}", cutoff / 1000)),
        vec!["exact", "later"]
    );
}

#[test]
fn relative_dates_use_one_anchor_and_defined_day_month_year_lengths() {
    let anchor = chrono::DateTime::parse_from_rfc3339("2024-03-31T12:00:00Z")
        .unwrap()
        .timestamp_millis();
    for (period, days) in [("2d", 2), ("2m", 60), ("2y", 730)] {
        let mailbox = Mailbox::new();
        let cutoff = anchor - days * DAY_MS;
        for (id, date) in [
            ("before", cutoff - 1),
            ("exact", cutoff),
            ("later", cutoff + 1),
        ] {
            mailbox.insert(Message {
                date,
                ..message(id, "")
            });
        }
        assert_eq!(
            mailbox.results_at(&format!("older_than:{period}"), ACCOUNT, anchor),
            vec!["before"],
            "{period}"
        );
        assert_eq!(
            mailbox.results_at(&format!("newer_than:{period}"), ACCOUNT, anchor),
            vec!["exact", "later"],
            "{period}"
        );
        assert_eq!(
            mailbox.results_at(&format!("older_than:{period}"), ACCOUNT, anchor + DAY_MS),
            vec!["before", "exact", "later"],
            "{period}"
        );
    }
}

#[test]
fn spam_and_trash_require_explicit_inclusion() {
    let mailbox = Mailbox::new();
    mailbox.insert(message("inbox", "needle"));
    mailbox.insert(Message {
        labels: &["SPAM"],
        ..message("spam", "needle")
    });
    mailbox.insert(Message {
        labels: &["TRASH"],
        ..message("trash", "needle")
    });
    assert_eq!(mailbox.results("needle"), vec!["inbox"]);
    assert_eq!(mailbox.results("-in:spam needle"), vec!["inbox"]);
    assert_eq!(mailbox.results("in:spam needle"), vec!["spam"]);
    assert_eq!(mailbox.results("in:trash needle"), vec!["trash"]);
    assert_eq!(
        mailbox.results("in:anywhere needle"),
        vec!["inbox", "spam", "trash"]
    );
    assert_eq!(
        mailbox.results("in:spam OR in:trash"),
        vec!["spam", "trash"]
    );
}

#[test]
fn existing_category_cc_and_label_aliases_keep_their_results() {
    let mailbox = Mailbox::new();
    mailbox.label("Label_team", "Team Mail");
    mailbox.insert(Message {
        copied: "Finance <finance@example.org>",
        labels: &[
            "INBOX",
            "CATEGORY_PERSONAL",
            "STARRED",
            "IMPORTANT",
            "Label_team",
        ],
        ..message("primary", "")
    });
    mailbox.insert(Message {
        copied: "Other <notfinance@example.org>",
        labels: &["DRAFT", "CATEGORY_SOCIAL"],
        ..message("social", "")
    });
    for query in [
        "cc:finance@example.org",
        "category:primary",
        "category:personal",
        "is:starred is:important",
        "label:Label_team",
        r#"label:"team mail""#,
    ] {
        assert_eq!(mailbox.results(query), vec!["primary"], "{query}");
    }
    assert_eq!(mailbox.results("category:social in:drafts"), vec!["social"]);
    assert!(mailbox.results("label:label_team").is_empty());
}

#[test]
fn hostile_values_are_parameters_and_cannot_mutate_the_database() {
    let mailbox = Mailbox::new();
    mailbox.insert(message("safe", "A harmless message"));
    let attacks = [
        r#"from:"x' OR 1=1 --""#,
        r#"label:"x'); DROP TABLE messages; --""#,
        r#"filename:"x'; DELETE FROM labels; --""#,
        r#"subject:"x\" OR 1=1 --""#,
    ];
    for attack in attacks {
        let query = parse_with_context(attack, ACCOUNT, 0).unwrap();
        assert!(!query.sql.contains("DROP TABLE"), "{attack}");
        assert!(!query.sql.contains("DELETE FROM"), "{attack}");
        assert!(!query.sql.contains("x'"), "{attack}");
        assert!(mailbox.results(attack).is_empty(), "{attack}");
        let counts: (i64, i64, i64) = mailbox
            .db
            .query_row(
                "SELECT (SELECT count(*) FROM messages),(SELECT count(*) FROM labels),(SELECT count(*) FROM search)",
                [],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
            )
            .unwrap();
        assert_eq!(counts, (1, 1, 1), "{attack}");
        assert_eq!(mailbox.results("harmless"), vec!["safe"]);
    }
}

#[test]
fn malformed_searches_return_invalid_instead_of_requesting_online_fallback() {
    for input in [
        "AND alpha",
        "alpha AND",
        "alpha OR",
        "(alpha",
        "alpha)",
        "{}",
        "{alpha",
        "()",
        "from:",
        "\"unclosed",
        "older_than:-2d",
        "newer_than:1.5d",
        "older_than:9999999999999999999999999999999y",
        "newer_than:2w",
        "before:2026-02-30",
        "after:9223372036854775807",
        "has:drive AND before:2026-02-30",
        "has:drive AND",
        "alpha\nbeta",
    ] {
        assert_eq!(
            parse_with_context(input, ACCOUNT, 0).err(),
            Some("local_search_invalid"),
            "{input}"
        );
    }
    for input in ["x".repeat(32_769), vec!["word"; 129].join(" ")] {
        assert_eq!(
            parse_with_context(&input, ACCOUNT, 0).err(),
            Some("local_search_invalid")
        );
    }
}

#[test]
fn valid_unsupported_operators_request_online_fallback() {
    for input in [
        "larger:1M",
        "has:drive",
        "a*b",
        "is:muted",
        "in:snoozed",
        "category:purchases",
        "rfc822msgid:200503292@example.com",
        "holiday AROUND 10 vacation",
        r#""secret AROUND 25 birthday""#,
        "+unicorn",
        "is:unread AND has:drive",
        "(larger:1M OR has:drive) -is:read",
    ] {
        assert_eq!(
            parse_with_context(input, ACCOUNT, 0).err(),
            Some("local_search_unsupported"),
            "{input}"
        );
    }
    assert_eq!(
        parse_with_context("from:me", "", 0).err(),
        Some("local_search_unsupported")
    );
    assert!(parse_with_context(r#""AROUND""#, ACCOUNT, 0).is_ok());
}

#[test]
fn group_and_negation_depth_is_bounded_before_evaluation() {
    for depth in [16, 17] {
        for input in [
            format!("{}is:read{}", "(".repeat(depth), ")".repeat(depth)),
            format!("{}is:read{}", "{".repeat(depth), "}".repeat(depth)),
            format!("{}is:read", "-".repeat(depth)),
        ] {
            if depth == 16 {
                assert!(parse_with_context(&input, ACCOUNT, 0).is_ok(), "{input}");
            } else {
                assert_eq!(
                    parse_with_context(&input, ACCOUNT, 0).err(),
                    Some("local_search_invalid"),
                    "{input}"
                );
            }
        }
    }
}

#[test]
fn pending_edits_use_conservative_boolean_results_for_unknown_terms() {
    let names = HashMap::new();
    let read = vec!["INBOX".to_owned()];
    let unread = vec!["INBOX".to_owned(), "UNREAD".to_owned()];
    for (input, read_result, unread_result) in [
        ("is:unread", Some(false), Some(true)),
        ("is:read", Some(true), Some(false)),
        ("-is:unread", Some(true), Some(false)),
        ("is:unread AND has:drive", Some(false), None),
        ("is:unread OR has:drive", None, Some(true)),
        ("-(is:unread OR has:drive)", None, Some(false)),
        ("is:read AND (is:unread OR has:drive)", None, Some(false)),
        ("label:missing OR has:drive", None, None),
        ("-has:drive", None, None),
        ("has:attachment", None, None),
        ("from:me", None, None),
        ("subject:approval", None, None),
        ("older_than:2d", None, None),
        ("is:unread subject:approval", Some(false), None),
        ("is:read OR subject:approval", Some(true), None),
    ] {
        assert_eq!(
            pending_match(input, ACCOUNT, 0, &read, &names),
            read_result,
            "read: {input}"
        );
        assert_eq!(
            pending_match(input, ACCOUNT, 0, &unread, &names),
            unread_result,
            "unread: {input}"
        );
    }
}

#[test]
fn pending_edits_match_quoted_label_names_ids_and_negation() {
    let names = HashMap::from([
        ("Label_board".to_owned(), "Board (2026)".to_owned()),
        ("Label_north".to_owned(), "R&D \"North\"".to_owned()),
    ]);
    let labels = vec!["Label_board".to_owned(), "Label_north".to_owned()];
    for (input, expected) in [
        (r#"label:"Board (2026)""#, Some(true)),
        (r#"label:"board (2026)""#, Some(true)),
        (r#"label:"Label_board""#, Some(true)),
        ("label:label_board", Some(false)),
        (r#"label:"R&D \"North\"""#, Some(true)),
        (r#"-label:"Board (2026)""#, Some(false)),
        ("label:missing", Some(false)),
        ("-label:missing", Some(true)),
        ("label:missing OR has:drive", None),
        ("label:Label_board OR has:drive", Some(true)),
        ("label:Label_board AND has:drive", None),
    ] {
        assert_eq!(
            pending_match(input, ACCOUNT, 0, &labels, &names),
            expected,
            "{input}"
        );
    }
}

#[test]
fn pending_edits_keep_default_scope_and_leave_malformed_queries_unknown() {
    let names = HashMap::new();
    let inbox = vec!["INBOX".to_owned()];
    let spam = vec!["SPAM".to_owned()];
    let trash = vec!["TRASH".to_owned()];
    for (input, inbox_result, spam_result, trash_result) in [
        ("", Some(true), Some(false), Some(false)),
        ("has:drive", None, Some(false), Some(false)),
        ("in:anywhere", Some(true), Some(true), Some(true)),
        ("in:anywhere has:drive", None, None, None),
        ("-in:anywhere", Some(false), Some(false), Some(false)),
        ("in:spam", Some(false), Some(true), Some(false)),
        ("in:trash", Some(false), Some(false), Some(true)),
        ("{in:spam in:trash}", Some(false), Some(true), Some(true)),
        ("-in:spam", Some(true), Some(false), Some(false)),
        ("--in:spam", Some(false), Some(true), Some(false)),
        ("in:spam OR has:drive", None, Some(true), None),
        ("is:read OR", None, None, None),
        ("before:2026-02-30", None, None, None),
    ] {
        for (labels, expected) in [
            (&inbox, inbox_result),
            (&spam, spam_result),
            (&trash, trash_result),
        ] {
            assert_eq!(
                pending_match(input, ACCOUNT, 0, labels, &names),
                expected,
                "{input}: {labels:?}"
            );
        }
    }
}

#[test]
fn spam_and_trash_request_scope_uses_positive_parsed_terms() {
    for input in [
        "in:anywhere",
        "in:all",
        "in:spam",
        "label:TRASH",
        "{in:spam in:trash}",
        "in:spam OR has:drive",
        "--in:trash",
        "-(is:read -in:spam)",
    ] {
        assert!(include_spam_trash(input), "{input}");
    }
    for input in [
        "",
        "needle",
        "-in:anywhere",
        "-in:spam",
        "-(in:spam OR in:trash)",
        r#""in:spam""#,
        r#"subject:"in:trash""#,
        r#"label:"spam archive""#,
        "has:drive",
        "in:spam OR",
    ] {
        assert!(!include_spam_trash(input), "{input}");
    }
}

#[test]
fn structured_detection_preserves_plain_urls_times_and_quoted_filter_text() {
    for input in [
        "",
        "ordinary words",
        "https://example.org/mail?subject=hello",
        "http://example.org/path",
        "mailto:alice@example.org",
        "ftp://example.org/archive",
        "12:30",
        "meeting at 12:30",
        "end-to-end",
        "C++",
        r#""from:""#,
        r#""from:alice""#,
        r#""alpha OR beta""#,
        r#""AROUND""#,
        r#""(a quoted group)""#,
    ] {
        assert!(!is_structured(input), "{input}");
    }
    for input in [
        "from:alice",
        "from:",
        "is:read",
        "larger:1M",
        "rfc822msgid:200503292@example.com",
        "holiday AROUND 10 vacation",
        r#""secret AROUND 25 birthday""#,
        "+unicorn",
        "alpha AND beta",
        "alpha OR beta",
        "(alpha beta)",
        "{alpha beta}",
        "-alpha",
        r#"-"quoted words""#,
        r#"label:"Board (2026)""#,
    ] {
        assert!(is_structured(input), "{input}");
    }
}

#[test]
fn invalid_search_diagnostics_explain_recovery_without_echoing_private_queries() {
    use super::diagnostic;
    for (input, expected) in [
        ("from:", "Add a value"),
        ("\"private_search", "matching double quote"),
        ("(private_search", "parenthesis or brace"),
        ("private_search OR", "both sides of AND or OR"),
        ("before:private_search", "valid date"),
        ("older_than:private_search", "positive whole number"),
        ("private_search\\", "final backslash"),
        ("private_search\n", "line breaks"),
    ] {
        let message = diagnostic(input, ACCOUNT, 0).unwrap();
        assert!(message.contains(expected), "{input}: {message}");
        assert!(!message.contains("private_search"));
    }
    assert!(diagnostic("has:drive", ACCOUNT, 0).is_none());
    assert!(diagnostic("from:alice", ACCOUNT, 0).is_none());
    assert!(
        diagnostic(&"x".repeat(32769), ACCOUNT, 0)
            .unwrap()
            .contains("too long")
    );
    assert!(
        diagnostic(&["word"; 129].join(" "), ACCOUNT, 0)
            .unwrap()
            .contains("fewer search terms")
    );
    assert_eq!(
        parse_with_context(r"word\*", ACCOUNT, 0).err(),
        Some("local_search_unsupported")
    );
}

#[test]
fn url_punctuation_remains_plain_text_while_surrounding_query_groups_work() {
    use super::{Token, is_structured, tokenize};
    let url = "https://en.wikipedia.org/wiki/Function_(mathematics)";
    assert!(!is_structured(url));
    assert!(!is_structured(&format!("{url} reference")));
    assert_eq!(tokenize(url).unwrap(), vec![Token::Word(url.into())]);
    assert_eq!(
        tokenize(&format!("({url})")).unwrap(),
        vec![Token::Open, Token::Word(url.into()), Token::Close]
    );
    assert!(is_structured(&format!("({url}) OR reference")));
    let mailbox = Mailbox::new();
    mailbox.insert(message("url", url));
    mailbox.insert(message("other", "unrelated"));
    assert_eq!(mailbox.results(url), vec!["url"]);
    assert_eq!(
        mailbox.results(&format!("({url}) OR unrelated")),
        vec!["other", "url"]
    );
}
