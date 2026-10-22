use super::*;
use std::io::Write;
struct Temp(PathBuf);
impl Temp {
    fn new() -> Self {
        let p = std::env::temp_dir().canonicalize().unwrap().join(format!(
            "omamail-compose-test-{}-{}",
            std::process::id(),
            SERIAL.fetch_add(1, Ordering::Relaxed)
        ));
        std::fs::create_dir(&p).unwrap();
        Self(p)
    }
}
impl Drop for Temp {
    fn drop(&mut self) {
        std::fs::remove_dir_all(&self.0).unwrap();
    }
}
fn saved(body: &str) -> Value {
    json!({"version":1,"active":true,"returnView":"reader","draft":{"body":body,"accountId":"one@example.org"}})
}
#[test]
fn reply_quote_survives_active_and_parked_durable_recovery() {
    let temp = Temp::new();
    let quote = "On Monday, 合成 wrote:\r\n> \"quoted\" \\ text\n";
    let mut value = saved(&format!("Reply\n\n{quote}"));
    value["draft"]["bodyQuote"] = json!(quote);
    value["parked"] = json!([
        {"body":"Edited quote is still editable", "bodyQuote":quote},
        {"body":"Legacy snapshot"},
        {"body":"Explicit empty quote", "bodyQuote":""}
    ]);
    let answer = call_at(
        &temp.0,
        "compose.recoverySave",
        &json!({
            "record":value, "expectedRevision":revision(&[])
        }),
    )
    .unwrap();
    assert_eq!(answer["record"]["draft"]["bodyQuote"], quote);
    assert_eq!(answer["record"]["parked"][0]["bodyQuote"], quote);
    assert!(answer["record"]["parked"][1].get("bodyQuote").is_none());
    assert_eq!(answer["record"]["parked"][2]["bodyQuote"], "");
    assert_eq!(
        call_at(&temp.0, "compose.recoveryRead", &json!({})).unwrap(),
        answer
    );
}

#[test]
fn invalid_or_oversized_reply_quote_never_writes_recovery() {
    for (quote, error) in [
        (json!(null), "recovery_invalid"),
        (json!(true), "recovery_invalid"),
        (json!(1), "recovery_invalid"),
        (json!([]), "recovery_invalid"),
        (json!({}), "recovery_invalid"),
        (json!("x".repeat(MAX_BYTES + 1)), "recovery_too_large"),
        // Invariant: Even a field under its own bound must obey the total record bound.
        (json!("x".repeat(MAX_BYTES - 1)), "recovery_too_large"),
    ] {
        for parked in [false, true] {
            let temp = Temp::new();
            let mut value = saved("Keep me");
            if parked {
                value["parked"] = json!([{"body":"Parked", "bodyQuote":quote}]);
            } else {
                value["draft"]["bodyQuote"] = quote.clone();
            }
            assert_eq!(
                call_at(
                    &temp.0,
                    "compose.recoverySave",
                    &json!({
                        "record":value, "expectedRevision":revision(&[])
                    })
                ),
                Err(error)
            );
            assert!(!temp.0.join("omamail").exists());
        }
    }
}

#[test]
fn user_edit_history_survives_durable_recovery_including_an_emptied_draft() {
    let temp = Temp::new();
    let mut value = saved("");
    value["draft"]["userModified"] = json!(true);
    value["draft"]["sourceDraftId"] = json!("draft-emptied");
    value["parked"] = json!([
        {"body":"Untouched prefill", "userModified":false},
        {"userModified":true, "replyToVisible":true},
        {"subject":"Legacy recovery"}
    ]);
    let answer = call_at(
        &temp.0,
        "compose.recoverySave",
        &json!({"record":value,"expectedRevision":revision(&[])}),
    )
    .unwrap();
    assert_eq!(answer["record"]["active"], true);
    assert_eq!(answer["record"]["draft"]["userModified"], true);
    assert_eq!(answer["record"]["draft"]["sourceDraftId"], "draft-emptied");
    assert_eq!(answer["record"]["parked"][0]["userModified"], false);
    assert_eq!(answer["record"]["parked"][1]["userModified"], true);
    assert!(answer["record"]["parked"][2].get("userModified").is_none());
    assert_eq!(
        call_at(&temp.0, "compose.recoveryRead", &json!({})).unwrap(),
        answer
    );
}

#[test]
fn malformed_edit_history_never_writes_recovery() {
    for invalid in [json!(null), json!("true"), json!(1), json!([]), json!({})] {
        let temp = Temp::new();
        let mut value = saved("Keep me");
        value["draft"]["userModified"] = invalid;
        assert_eq!(
            call_at(
                &temp.0,
                "compose.recoverySave",
                &json!({
                    "record":value,"expectedRevision":revision(&[])
                })
            ),
            Err("recovery_invalid_user_modified")
        );
        assert!(!temp.0.join("omamail").exists());
    }
}

#[test]
fn meaningful_body_history_and_parked_identity_survive() {
    assert!(!normalize(&saved("  ")).unwrap()["active"]
        .as_bool()
        .unwrap());
    let mut value = saved("\n\nSignature");
    value["draft"]["placedBody"] = json!("\n\nSignature");
    assert_eq!(normalize(&value).unwrap(), empty());
    value["draft"]["bodyWasEdited"] = json!(true);
    value["parked"] =
        json!([{"body":"other draft","accountId":"imap:two@example.org"},{"body":"  "}]);
    let record = normalize(&value).unwrap();
    assert_eq!(record["draft"]["body"], "\n\nSignature");
    assert_eq!(record["parked"].as_array().unwrap().len(), 1);
    assert_eq!(record["parked"][0]["accountId"], "imap:two@example.org");
}
#[cfg(unix)]
#[test]
fn snapshots_are_private_atomic_and_stale_clear_cannot_erase_newer_draft() {
    use std::os::unix::fs::PermissionsExt;
    let temp = Temp::new();
    let initial = call_at(&temp.0, "compose.recoveryRead", &json!({})).unwrap();
    let first = call_at(
        &temp.0,
        "compose.recoverySave",
        &json!({"record":saved("first"),"expectedRevision":initial["revision"]}),
    )
    .unwrap();
    let second = call_at(
        &temp.0,
        "compose.recoverySave",
        &json!({"record":saved("second"),"expectedRevision":first["revision"]}),
    )
    .unwrap();
    assert_eq!(
        call_at(
            &temp.0,
            "compose.recoverySave",
            &json!({"record":{"version":1,"active":false},"expectedRevision":first["revision"]})
        ),
        Err("recovery_conflict")
    );
    assert_eq!(
        call_at(&temp.0, "compose.recoveryRead", &json!({})).unwrap(),
        second
    );
    assert_eq!(
        std::fs::metadata(temp.0.join("omamail/compose.json"))
            .unwrap()
            .permissions()
            .mode()
            & 0o777,
        0o600
    );
    let cleared = call_at(
        &temp.0,
        "compose.recoverySave",
        &json!({"record":{"version":1,"active":false},"expectedRevision":second["revision"]}),
    )
    .unwrap();
    assert_eq!(cleared["record"], empty());
}
#[cfg(unix)]
#[test]
fn links_never_read_write_or_modify_outside_target() {
    use std::os::unix::fs::{symlink, PermissionsExt};
    for name in ["compose.json", ".compose.lock"] {
        for hard in [false, true] {
            let temp = Temp::new();
            std::fs::create_dir(temp.0.join("omamail")).unwrap();
            let outside = temp.0.join("outside");
            std::fs::write(&outside, b"secret").unwrap();
            std::fs::set_permissions(&outside, std::fs::Permissions::from_mode(0o644)).unwrap();
            let path = temp.0.join("omamail").join(name);
            if hard {
                std::fs::hard_link(&outside, path).unwrap();
            } else {
                symlink(&outside, path).unwrap();
            }
            assert!(call_at(
                &temp.0,
                "compose.recoverySave",
                &json!({"record":saved("draft"),"expectedRevision":revision(&[])})
            )
            .is_err());
            assert_eq!(std::fs::read(&outside).unwrap(), b"secret");
            assert_eq!(
                std::fs::metadata(&outside).unwrap().permissions().mode() & 0o777,
                0o644
            );
        }
    }
}
#[test]
fn attachment_metadata_never_opens_paths_and_invalid_paths_write_nothing() {
    let temp = Temp::new();
    let outside = temp.0.join("sentinel");
    std::fs::write(&outside, b"untouched").unwrap();
    let mut value = saved("draft");
    value["draft"]["draftAttachments"] =
        json!([{"path":outside,"owned":true,"data":"ignored","filename":"file"}]);
    let answer = normalize(&value).unwrap();
    assert_eq!(answer["draft"]["draftAttachments"][0]["data"], "");
    assert_eq!(std::fs::read(&outside).unwrap(), b"untouched");
    for path in [
        "../secret",
        "relative",
        "/tmp/a\0",
        "/tmp/a\n",
        "/tmp/x/../../outside",
        "/tmp/./a",
    ] {
        value["draft"]["draftAttachments"][0]["path"] = json!(path);
        assert_eq!(
            call_at(
                &temp.0,
                "compose.recoverySave",
                &json!({"record":value,"expectedRevision":revision(&[])})
            ),
            Err("recovery_attachment_path_invalid")
        );
    }
    assert!(!temp.0.join("omamail").exists());
}
#[test]
fn js_oracle_parity_for_normalized_drafts() {
    let path = std::env::temp_dir().join("synthetic");
    let fixtures = json!([saved("hello"),saved(" "),{"version":1,"active":true,"returnView":"calendar","draft":{"to":"a@example.org","draftAttachments":[{"path":path,"data":"discard","filename":"a","size":12}],"replyRecipients":[{"email":"a@example.org"}]},"parked":[{"subject":"parked","accountId":"other"},{}]}, {"version":1,"active":false}, {"version":2,"active":true}]);
    let script = r#"const fs=require('fs'),vm=require('vm');const ctx={};vm.createContext(ctx);vm.runInContext(fs.readFileSync('ui/tests/oracles/Recovery.js','utf8').replace(/^\.pragma library\s*/,''),ctx);const fixtures=JSON.parse(fs.readFileSync(0,'utf8'));process.stdout.write(JSON.stringify(fixtures.map(v=>ctx.parse(JSON.stringify(v)))));"#;
    use std::process::{Command, Stdio};
    let mut child = Command::new("node")
        .args(["-e", script])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();
    child
        .stdin
        .take()
        .unwrap()
        .write_all(fixtures.to_string().as_bytes())
        .unwrap();
    let output = child.wait_with_output().unwrap();
    assert!(output.status.success());
    let expected: Value = serde_json::from_slice(&output.stdout).unwrap();
    for (input, expected) in fixtures
        .as_array()
        .unwrap()
        .iter()
        .zip(expected.as_array().unwrap())
    {
        assert_eq!(normalize(input).unwrap(), *expected);
    }
}

#[test]
fn malformed_or_oversize_save_does_not_replace_existing_snapshot() {
    let temp = Temp::new();
    let first = call_at(
        &temp.0,
        "compose.recoverySave",
        &json!({"record":saved("retain me"),"expectedRevision":revision(&[])}),
    )
    .unwrap();
    for value in [
        json!(null),
        json!({}),
        json!({"version":2,"active":false}),
        saved(&"x".repeat(MAX_BYTES)),
    ] {
        assert!(call_at(
            &temp.0,
            "compose.recoverySave",
            &json!({"record":value,"expectedRevision":first["revision"]})
        )
        .is_err());
        assert_eq!(
            call_at(&temp.0, "compose.recoveryRead", &json!({})).unwrap(),
            first
        );
    }
}

#[test]
fn delivery_receipts_survive_recovery_without_changing_legacy_empty_fields() {
    let mut value = saved("pending");
    assert!(normalize(&value).unwrap()["draft"]
        .get("pendingSendId")
        .is_none());
    value["draft"]["pendingSendId"] = json!("send-one");
    value["draft"]["deliveryUnknown"] = json!(true);
    let record = normalize(&value).unwrap();
    assert_eq!(record["draft"]["pendingSendId"], "send-one");
    assert_eq!(record["draft"]["deliveryUnknown"], true);
    value["draft"]["pendingSendId"] = json!("send-one\n");
    assert!(normalize(&value).is_err());
}

#[cfg(unix)]
#[test]
fn recovery_lock_releases_even_with_an_inherited_file_description() {
    let temp = Temp::new();
    let path = temp.0.join("lock");
    let file = std::fs::OpenOptions::new()
        .create(true)
        .truncate(false)
        .read(true)
        .write(true)
        .open(&path)
        .unwrap();
    assert_eq!(
        unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) },
        0
    );
    let inherited = file.try_clone().unwrap();
    drop(crate::platform::private_fs::ExclusiveLock::from_locked(
        file,
    ));
    let contender = File::open(&path).unwrap();
    assert_eq!(
        unsafe { libc::flock(contender.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) },
        0
    );
    drop(inherited);
}

fn attachment_recovery() -> Value {
    json!({"version":1,"active":true,"returnView":"reader","draft":{
        "draftKey":"draft-one","accountId":"one@example.org","body":"Keep me",
        "attachmentSourceMessageId":"source-message", "forwardAttachmentsLoading":true,
        "forwardAttachmentError":"", "forwardLoadSerial":17,
        "attachmentRecoveryError":"",
        "attachJobs":[{"mode":"recover-owned","path":"/synthetic/one.png","owner":"draft-one","accountId":"one@example.org"}],
        "pendingAttachment":{"mode":"read","path":"/synthetic/two.pdf","owner":"draft-one","accountId":"one@example.org"}
    }})
}

#[test]
fn attachment_recovery_preserves_source_and_owned_jobs_across_disk_roundtrip() {
    let temp = Temp::new();
    let mut input = attachment_recovery();
    input["parked"] = json!([input["draft"].clone()]);
    let answer = call_at(
        &temp.0,
        "compose.recoverySave",
        &json!({"record":input,"expectedRevision":revision(&[])}),
    )
    .unwrap();
    for field in [
        "attachmentSourceMessageId",
        "forwardAttachmentsLoading",
        "forwardAttachmentError",
        "forwardLoadSerial",
        "attachmentRecoveryError",
        "attachJobs",
        "pendingAttachment",
    ] {
        assert_eq!(
            answer["record"]["draft"][field], input["draft"][field],
            "{field}"
        );
        assert_eq!(
            answer["record"]["parked"][0][field], input["draft"][field],
            "parked {field}"
        );
    }
    assert_eq!(
        call_at(&temp.0, "compose.recoveryRead", &json!({})).unwrap(),
        answer
    );
}

#[test]
fn attachment_recovery_keeps_pending_and_interrupted_drafts_without_text() {
    for field in [
        "attachmentSourceMessageId",
        "attachJobs",
        "pendingAttachment",
        "forwardAttachmentError",
        "attachmentRecoveryError",
    ] {
        let source = attachment_recovery();
        let mut input = saved("");
        input["draft"]["draftKey"] = json!("draft-one");
        input["draft"][field] = if field.ends_with("Error") {
            json!("Choose the file again")
        } else {
            source["draft"][field].clone()
        };
        assert_eq!(normalize(&input).unwrap()["active"], true, "{field}");
    }
}

#[test]
fn attachment_recovery_interrupts_host_actions_instead_of_replaying_them() {
    for mode in ["pick", "clipboard"] {
        let mut input = attachment_recovery();
        let host = json!({"mode":mode,"path":"","owner":"draft-one","accountId":"one@example.org"});
        input["draft"]["attachJobs"]
            .as_array_mut()
            .unwrap()
            .push(host.clone());
        input["draft"]["pendingAttachment"] = host;
        let output = normalize(&input).unwrap();
        assert_eq!(output["draft"]["attachJobs"].as_array().unwrap().len(), 1);
        assert_eq!(output["draft"]["pendingAttachment"], Value::Null);
        assert_eq!(
            output["draft"]["attachmentRecoveryError"],
            "Attachment selection was interrupted. Choose the files or paste the image again."
        );
    }
}

#[test]
fn attachment_recovery_invalid_ownership_and_paths_never_replace_saved_bytes() {
    let temp = Temp::new();
    let baseline = call_at(
        &temp.0,
        "compose.recoverySave",
        &json!({"record":saved("Original"),"expectedRevision":revision(&[])}),
    )
    .unwrap();
    let path = temp.0.join("omamail/compose.json");
    let before = std::fs::read(&path).unwrap();
    let outside = temp.0.join("outside");
    std::fs::write(&outside, b"untouched").unwrap();
    for (field, invalid) in [
        ("owner", json!("foreign")),
        ("accountId", json!("foreign")),
        ("mode", json!("forget")),
        ("mode", json!("shell")),
        ("path", json!("../outside")),
        ("path", json!("/tmp/../outside")),
        ("path", json!("/tmp/x\n")),
    ] {
        for pending in [false, true] {
            let mut input = attachment_recovery();
            let job = if pending {
                &mut input["draft"]["pendingAttachment"]
            } else {
                &mut input["draft"]["attachJobs"][0]
            };
            job["path"] = json!(outside);
            job[field] = invalid.clone();
            assert!(
                call_at(
                    &temp.0,
                    "compose.recoverySave",
                    &json!({"record":input,"expectedRevision":baseline["revision"]})
                )
                .is_err(),
                "{field} pending={pending}"
            );
            assert_eq!(std::fs::read(&path).unwrap(), before);
            assert_eq!(std::fs::read(&outside).unwrap(), b"untouched");
        }
    }
}

#[test]
fn attachment_recovery_rejects_malformed_or_oversized_state_before_storage() {
    let cases = [
        ("forwardAttachmentsLoading", json!("true")),
        ("forwardLoadSerial", json!(-1)),
        ("forwardLoadSerial", json!(2147483648u64)),
        ("attachmentSourceMessageId", json!("x".repeat(4097))),
        ("forwardAttachmentError", json!("x".repeat(4097))),
        ("attachmentRecoveryError", json!(true)),
        ("attachJobs", json!({})),
        ("attachJobs", json!(vec![json!({}); 1001])),
        ("pendingAttachment", json!([])),
        ("draftKey", json!(true)),
        ("accountId", json!(true)),
    ];
    for (field, value) in cases {
        let temp = Temp::new();
        let mut input = attachment_recovery();
        input["draft"][field] = value;
        assert!(
            call_at(
                &temp.0,
                "compose.recoverySave",
                &json!({"record":input,"expectedRevision":revision(&[])})
            )
            .is_err(),
            "{field}"
        );
        assert!(!temp.0.join("omamail").exists(), "{field}");
    }
}
