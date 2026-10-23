use super::*;
use serde_json::{Value, json};

fn request() -> SendRequest {
    SendRequest {
        account: Account {
            id: "a@example.org".into(),
            provider: Provider::Gmail,
        },
        from: String::new(),
        to: vec!["one@example.org".into()],
        cc: vec![],
        bcc: vec![],
        subject: "Plan".into(),
        body: "Line one\nLine two\n".into(),
        attachments: vec![],
        execute: false,
        send_id: None,
    }
}

fn identities() -> Value {
    json!([
        {"email":"a@example.org","displayName":"Primary","isPrimary":true},
        {"email":"alias@example.org","displayName":"Alias","isDefault":true}
    ])
}

#[test]
fn preview_normalizes_repeated_recipients_and_default_identity_without_files() {
    let mut request = request();
    request.to = vec![
        " one@example.org, two@example.org ".into(),
        "ONE@example.org".into(),
    ];
    request.cc = vec!["two@example.org".into(), "three@example.org".into()];
    let prepared = send::prepare(&request, &identities()).unwrap();
    assert_eq!(
        prepared.preview(),
        json!({
            "dryRun":true,"executed":false,"accountId":"a@example.org",
            "from":"Alias <alias@example.org>","to":["one@example.org","two@example.org"],
            "cc":["three@example.org"],"bcc":[],"subject":"Plan","body":"Line one\nLine two\n",
            "attachments":[]
        })
    );
}

#[test]
fn invalid_headers_recipients_and_unapproved_sender_are_rejected() {
    for invalid in [
        "bad",
        "a@@example.org",
        "x@example.org\rBcc: victim@example.org",
        "x@example.org\n",
        "x@example.org\0",
        "x@example.org\r\n",
        "group: x@example.org;",
    ] {
        let mut request = request();
        request.to = vec![invalid.into()];
        assert!(
            send::prepare(&request, &identities()).is_err(),
            "{invalid:?}"
        );
    }
    for invalid in ["\r", "\n", "\r\n", "\0"] {
        let mut request = request();
        request.subject.push_str(invalid);
        assert!(send::prepare(&request, &identities()).is_err());
        request.subject = "Plan".into();
        request.from = format!("alias@example.org{invalid}");
        assert!(send::prepare(&request, &identities()).is_err());
    }
    let mut request = request();
    request.to.clear();
    assert!(send::prepare(&request, &identities()).is_err());
    request.bcc = vec!["private@example.org".into()];
    assert!(send::prepare(&request, &identities()).is_ok());
    request.from = "unapproved@example.org".into();
    assert!(send::prepare(&request, &identities()).is_err());
}

#[test]
fn encoded_header_words_cannot_change_the_previewed_envelope() {
    let mut request = request();
    request.to = vec!["=?UTF-8?B?eCIgPHZpY3RpbUBleGFtcGxlLm9yZz4sICJ5?= <one@example.org>".into()];
    assert!(send::prepare(&request, &identities()).is_err());
    request.to = vec!["one@example.org".into()];
    request.subject = "=?UTF-8?B?DQpCY2M6IHZpY3RpbUBleGFtcGxlLm9yZw==?=".into();
    assert!(send::prepare(&request, &identities()).is_err());
}

#[test]
fn actual_composed_sender_and_recipients_must_match_the_authorized_plan() {
    let fields = json!({"from":"alias@example.org","to":"to@example.org","cc":"cc@example.org","bcc":"bcc@example.org"});
    let good = b"From: alias@example.org\r\nTo: to@example.org\r\nCc: cc@example.org\r\nBcc: bcc@example.org\r\n\r\nbody";
    assert!(send::verify_envelope(good, &fields).is_ok());
    for bad in [
        "From: victim@example.org\r\nTo: to@example.org\r\nCc: cc@example.org\r\nBcc: bcc@example.org\r\n\r\nbody",
        "From: alias@example.org\r\nFrom: victim@example.org\r\nTo: to@example.org\r\nCc: cc@example.org\r\nBcc: bcc@example.org\r\n\r\nbody",
        "From: alias@example.org\r\nTo: to@example.org, victim@example.org\r\nCc: cc@example.org\r\nBcc: bcc@example.org\r\n\r\nbody",
        "From: alias@example.org\r\nTo: to@example.org\r\nCc: cc@example.org\r\nBcc: bcc@example.org, victim@example.org\r\n\r\nbody",
    ] {
        assert!(send::verify_envelope(bad.as_bytes(), &fields).is_err());
    }
}

#[test]
fn gmail_keeps_unicode_display_text_out_of_the_planned_envelope() {
    for provider in [Provider::Gmail] {
        for name in ["工 <victim@example.org>, Alias", "工, Lee"] {
            let mut request = request();
            request.account.provider = provider;
            request.to = vec![format!("\"{name}\" <to@example.org>")];
            request.cc = vec![format!("\"{name}\" <cc@example.org>")];
            request.bcc = vec![format!("\"{name}\" <bcc@example.org>")];
            let prepared = send::prepare(
                &request,
                &json!([{"email":"alias@example.org","displayName":name,"isDefault":true}]),
            )
            .unwrap();
            let payload = prepared.payload(0, "unicode").unwrap();
            use base64::Engine;
            let bytes = base64::engine::general_purpose::URL_SAFE_NO_PAD
                .decode(payload["raw"].as_str().unwrap())
                .unwrap();
            let (headers, _) = mailparse::parse_headers(&bytes).unwrap();
            assert_eq!(
                crate::message::envelope::sender(&headers)
                    .unwrap()
                    .as_deref(),
                Some("alias@example.org")
            );
            for (header, expected) in [
                ("To", "to@example.org"),
                ("Cc", "cc@example.org"),
                ("Bcc", "bcc@example.org"),
            ] {
                assert_eq!(
                    crate::message::envelope::addresses(&headers, header).unwrap(),
                    vec![expected]
                );
            }
        }
    }
}

#[test]
fn attachment_bytes_are_pinned_and_preview_never_changes_the_fixture() {
    if tests::isolated() {
        return;
    }
    let fixture = tests::account_fixture(
        json!({"version":1,"activeId":"a@example.org","accounts":[{"email":"a@example.org"}]}),
    );
    let path = fixture.root.join("brief.txt");
    std::fs::write(&path, "hello").unwrap();
    let mut request = request();
    request.attachments.push(AttachmentInput {
        path: path.clone(),
        name: "brief.txt".into(),
        size: 5,
    });
    let before = tests::fixture_tree(&fixture.root);
    let prepared = send::prepare(&request, &identities()).unwrap();
    assert_eq!(
        prepared.preview()["attachments"],
        json!([{"name":"brief.txt","size":5}])
    );
    let payload = prepared.payload(1_000, "test").unwrap();
    assert_eq!(tests::fixture_tree(&fixture.root), before);
    std::fs::rename(&path, fixture.root.join("original")).unwrap();
    std::fs::write(&path, "replacement secret").unwrap();
    assert_eq!(prepared.payload(1_000, "test").unwrap(), payload);
    use base64::Engine;
    let bytes = base64::engine::general_purpose::URL_SAFE_NO_PAD
        .decode(payload["raw"].as_str().unwrap())
        .unwrap();
    let parsed = mailparse::parse_mail(&bytes).unwrap();
    assert_eq!(parsed.subparts[1].get_body_raw().unwrap(), b"hello");
    assert!(payload.get("attachments").is_none());
}

#[cfg(unix)]
#[test]
fn attachment_paths_types_metadata_counts_and_sizes_are_validated_before_read() {
    if tests::isolated() {
        return;
    }
    let fixture = tests::account_fixture(
        json!({"version":1,"activeId":"a@example.org","accounts":[{"email":"a@example.org"}]}),
    );
    let path = fixture.root.join("file");
    std::fs::write(&path, "hello").unwrap();
    let link = fixture.root.join("link");
    std::os::unix::fs::symlink(&path, &link).unwrap();
    let ancestor = fixture.root.join("ancestor");
    std::os::unix::fs::symlink(&fixture.root, &ancestor).unwrap();
    let fifo = fixture.root.join("fifo");
    let name = std::ffi::CString::new(fifo.to_str().unwrap()).unwrap();
    assert_eq!(unsafe { libc::mkfifo(name.as_ptr(), 0o600) }, 0);
    let mut request = request();
    for invalid in [
        std::path::PathBuf::from("relative"),
        link,
        ancestor.join("file"),
        fifo,
        fixture.root.clone(),
        fixture.root.join("../outside"),
        fixture.root.join("file\n"),
    ] {
        request.attachments = vec![AttachmentInput {
            path: invalid,
            name: "file".into(),
            size: 5,
        }];
        assert!(send::prepare(&request, &identities()).is_err());
    }
    for (name, size) in [("../file", 5), ("file\0", 5), ("file\n", 5), ("file", 6)] {
        request.attachments = vec![AttachmentInput {
            path: path.clone(),
            name: name.into(),
            size,
        }];
        assert!(send::prepare(&request, &identities()).is_err());
    }
    request.attachments = (0..33)
        .map(|_| AttachmentInput {
            path: path.clone(),
            name: "file".into(),
            size: 5,
        })
        .collect();
    assert!(send::prepare(&request, &identities()).is_err());
    std::fs::File::options()
        .write(true)
        .open(&path)
        .unwrap()
        .set_len(20 * 1024 * 1024 + 1)
        .unwrap();
    request.attachments = vec![AttachmentInput {
        path: path.clone(),
        name: "file".into(),
        size: 20 * 1024 * 1024 + 1,
    }];
    assert!(send::prepare(&request, &identities()).is_err());
    std::fs::File::options()
        .write(true)
        .open(&path)
        .unwrap()
        .set_len(11 * 1024 * 1024)
        .unwrap();
    request.attachments = (0..2)
        .map(|_| AttachmentInput {
            path: path.clone(),
            name: "file".into(),
            size: 11 * 1024 * 1024,
        })
        .collect();
    assert!(send::prepare(&request, &identities()).is_err());
}

#[test]
fn unicode_names_quotes_backslashes_and_rtl_body_survive_composition() {
    let mut request = request();
    request.from = "alias@example.org".into();
    request.to = vec!["\"Lee, \\\"J\\\" \\\\ 工\" <one@example.org>".into()];
    request.subject = "خطة \\\"".into();
    request.body = "مرحبا\nSecond line\n".into();
    let prepared = send::prepare(&request, &identities()).unwrap();
    use base64::Engine;
    let payload = prepared.payload(1_000, "test").unwrap();
    let bytes = base64::engine::general_purpose::URL_SAFE_NO_PAD
        .decode(payload["raw"].as_str().unwrap())
        .unwrap();
    let parsed = mailparse::parse_mail(&bytes).unwrap();
    assert_eq!(parsed.ctype.mimetype, "multipart/alternative");
    assert_eq!(parsed.subparts[0].get_body().unwrap(), request.body);
    assert!(
        parsed.subparts[1]
            .get_body()
            .unwrap()
            .contains("dir=\"rtl\"")
    );
}

#[test]
fn body_and_combined_wire_limits_are_enforced() {
    let mut request = request();
    request.body = "\0".into();
    assert!(send::prepare(&request, &identities()).is_err());
    request.body = "x".repeat(16 * 1024 * 1024 + 1);
    assert!(send::prepare(&request, &identities()).is_err());
}

#[test]
fn combined_mime_limit_is_checked_even_when_body_and_attachments_each_fit() {
    if tests::isolated() {
        return;
    }
    let fixture = tests::account_fixture(
        json!({"version":1,"activeId":"a@example.org","accounts":[{"email":"a@example.org"}]}),
    );
    let path = fixture.root.join("large.bin");
    std::fs::File::create(&path)
        .unwrap()
        .set_len(10 * 1024 * 1024)
        .unwrap();
    let mut request = request();
    request.body = "x".repeat(16 * 1024 * 1024);
    request.attachments = vec![AttachmentInput {
        path,
        name: "large.bin".into(),
        size: 10 * 1024 * 1024,
    }];
    let prepared = send::prepare(&request, &identities()).unwrap();
    assert_eq!(prepared.payload(0, "preview"), Err("message_too_large"));
}
