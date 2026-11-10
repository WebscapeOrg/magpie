use serde_json::Value;
#[cfg(unix)]
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::sync::atomic::{AtomicU64, Ordering};
use std::{
    fs,
    io::Write,
    path::{Path, PathBuf},
    process::{Command, Output, Stdio},
};

static EMPTY_HOME: AtomicU64 = AtomicU64::new(0);
static MAIL_LIST_FIXTURE: AtomicU64 = AtomicU64::new(0);

fn omamail(args: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_omamail"))
        .args(args)
        .output()
        .unwrap()
}

#[test]
fn version_commands_have_stable_machine_readable_output() {
    let plain = omamail(&["--version"]);
    assert!(plain.status.success());
    assert_eq!(
        plain.stdout,
        format!("omamail {}\n", env!("CARGO_PKG_VERSION")).as_bytes()
    );
    assert!(plain.stderr.is_empty());

    let json = omamail(&["version", "--json"]);
    assert!(json.status.success());
    assert_eq!(
        serde_json::from_slice::<Value>(&json.stdout).unwrap(),
        serde_json::json!({"version":env!("CARGO_PKG_VERSION")})
    );
    assert!(json.stderr.is_empty());
}

#[test]
fn no_arguments_print_help_without_starting_a_gui() {
    let output = omamail(&[]);
    assert!(output.status.success());
    assert!(
        String::from_utf8(output.stdout)
            .unwrap()
            .contains("Usage: omamail ")
    );
    assert!(output.stderr.is_empty());
}

#[test]
fn serve_runs_the_persistent_backend() {
    let fixture = mail_list_fixture(false);
    let mut child = Command::new(env!("CARGO_BIN_EXE_omamail"))
        .arg("serve")
        .env("OMAMAIL_INTEGRATION_HOME", &fixture.0)
        .env("HOME", &fixture.0)
        .env_remove("XDG_CONFIG_HOME")
        .env_remove("XDG_CACHE_HOME")
        .env_remove("XDG_STATE_HOME")
        .env("XDG_RUNTIME_DIR", &fixture.0)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    child
        .stdin
        .as_mut()
        .unwrap()
        .write_all(b"{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"system.info\"}\n{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"system.quit\"}\n")
        .unwrap();
    drop(child.stdin.take());
    let output = child.wait_with_output().unwrap();
    assert!(output.status.success(), "{output:?}");
    assert!(output.stderr.is_empty());
    let replies: Vec<Value> = output
        .stdout
        .split(|byte| *byte == b'\n')
        .filter(|line| !line.is_empty())
        .map(|line| serde_json::from_slice(line).unwrap())
        .collect();
    assert_eq!(replies.len(), 2);
    assert_eq!(replies[0]["id"], 1);
    assert_eq!(replies[0]["result"]["name"], "omamail");
    assert_eq!(replies[1]["id"], 2);
}

fn call(method: &str, params: &[u8]) -> Output {
    let mut child = Command::new(env!("CARGO_BIN_EXE_omamail"))
        .args(["call", method, "--json"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let mut stdin = child.stdin.take().unwrap();
    // Invariant: Oversized inputs may be rejected before the writer finishes.
    let _ = stdin.write_all(params);
    drop(stdin);
    child.wait_with_output().unwrap()
}

fn call_in_empty_home(method: &str, params: &[u8]) -> Output {
    let home = std::env::temp_dir().canonicalize().unwrap().join(format!(
        "omamail-cli-empty-home-{}-{}",
        std::process::id(),
        EMPTY_HOME.fetch_add(1, Ordering::Relaxed)
    ));
    std::fs::create_dir_all(&home).unwrap();
    let mut child = Command::new(env!("CARGO_BIN_EXE_omamail"))
        .args(["call", method, "--json"])
        .env("OMAMAIL_INTEGRATION_HOME", &home)
        .env("XDG_CONFIG_HOME", &home)
        .env("HOME", &home)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    child.stdin.as_mut().unwrap().write_all(params).unwrap();
    drop(child.stdin.take());
    let output = child.wait_with_output().unwrap();
    assert!(std::fs::read_dir(&home).unwrap().next().is_none());
    std::fs::remove_dir_all(home).unwrap();
    output
}

struct MailListFixture(PathBuf);

impl Drop for MailListFixture {
    fn drop(&mut self) {
        fs::remove_dir_all(&self.0).unwrap();
    }
}

fn mail_list_fixture(keyring_succeeds: bool) -> MailListFixture {
    let root = std::env::temp_dir().canonicalize().unwrap().join(format!(
        "omamail-cli-mail-list-{}-{}",
        std::process::id(),
        MAIL_LIST_FIXTURE.fetch_add(1, Ordering::Relaxed)
    ));
    let config = config_root(&root).join("omamail");
    fs::create_dir_all(&config).unwrap();
    #[cfg(windows)]
    {
        // Invariant: These synthetic ancestors are created by std::fs, so unlike the native
        // private-directory creator they inherit the temp directory ACL.
        set_mode(&root, 0o700);
        set_mode(&config_root(&root), 0o700);
    }
    fs::write(
        config.join("accounts.json"),
        serde_json::json!({
            "version":1,
            "activeId":"gmail@example.org",
            "accounts":[
                {"provider":"gmail","email":"gmail@example.org"}
            ]
        })
        .to_string(),
    )
    .unwrap();
    set_mode(&config, 0o700);
    set_mode(&config.join("accounts.json"), 0o600);
    let bin = root.join("bin");
    fs::create_dir_all(&bin).unwrap();
    let secret_tool = bin.join("secret-tool");
    fs::write(
        &secret_tool,
        if keyring_succeeds {
            "#!/bin/sh\nprintf 'synthetic\\n'\n"
        } else {
            "#!/bin/sh\nexit 1\n"
        },
    )
    .unwrap();
    set_mode(&secret_tool, 0o700);
    fs::write(
        root.join("integration-credential"),
        if keyring_succeeds {
            "synthetic\n"
        } else {
            "missing\n"
        },
    )
    .unwrap();
    MailListFixture(root)
}

#[cfg(target_os = "macos")]
fn config_root(root: &Path) -> PathBuf {
    root.join("home/Library/Application Support")
}

#[cfg(not(target_os = "macos"))]
fn config_root(root: &Path) -> PathBuf {
    root.join("config")
}

#[cfg(target_os = "macos")]
fn assert_no_runtime_storage(root: &Path) {
    assert!(!root.join("home/Library/Caches/omamail").exists());
}

#[cfg(not(target_os = "macos"))]
fn assert_no_runtime_storage(root: &Path) {
    for name in ["cache", "state", "home"] {
        assert!(!root.join(name).exists());
    }
}

fn call_mail_list(root: &Path, account: &str) -> Output {
    root_mail(
        root,
        &["call", "mail.list", "--json"],
        serde_json::json!({"account": account})
            .to_string()
            .as_bytes(),
    )
}

fn call_mail_read(root: &Path, account: &str, id: &str) -> Output {
    root_mail(
        root,
        &["call", "mail.read", "--json"],
        serde_json::json!({"account": account, "id": id})
            .to_string()
            .as_bytes(),
    )
}

#[cfg(unix)]
fn set_mode(path: &Path, mode: u32) {
    fs::set_permissions(path, fs::Permissions::from_mode(mode)).unwrap();
}
#[cfg(windows)]
fn set_mode(path: &Path, _: u32) {
    // Invariant: Native private storage requires a protected DACL and this user's owner SID. A
    // no-op Unix-mode stub does not make an inherited Windows file private.
    let user = std::env::var("USERNAME").unwrap();
    let grant = if path.is_dir() {
        format!("{user}:(OI)(CI)F")
    } else {
        format!("{user}:F")
    };
    for arguments in [
        vec!["/setowner".to_owned(), user.clone()],
        vec!["/inheritance:r".to_owned(), "/grant:r".to_owned(), grant],
    ] {
        let output = Command::new("icacls")
            .arg(path)
            .args(arguments)
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "{}",
            String::from_utf8_lossy(&output.stderr)
        );
    }
}

#[cfg(unix)]
fn metadata(path: &Path) -> (u64, (i64, i64), (i64, i64)) {
    let metadata = fs::metadata(path).unwrap();
    (
        metadata.mode() as u64,
        (metadata.mtime(), metadata.mtime_nsec()),
        (metadata.ctime(), metadata.ctime_nsec()),
    )
}
#[cfg(windows)]
fn metadata(path: &Path) -> (u64, (i64, i64), (i64, i64)) {
    use std::hash::{Hash, Hasher};
    use std::os::windows::{ffi::OsStrExt, fs::MetadataExt};
    use windows_sys::Win32::Security::{
        DACL_SECURITY_INFORMATION, GetFileSecurityW, OWNER_SECURITY_INFORMATION,
    };
    let metadata = fs::metadata(path).unwrap();
    let name: Vec<u16> = path.as_os_str().encode_wide().chain(Some(0)).collect();
    let flags = DACL_SECURITY_INFORMATION | OWNER_SECURITY_INFORMATION;
    let mut needed = 0;
    unsafe { GetFileSecurityW(name.as_ptr(), flags, std::ptr::null_mut(), 0, &mut needed) };
    assert!(needed > 0);
    let mut descriptor = vec![0u8; needed as usize];
    assert_ne!(
        unsafe {
            GetFileSecurityW(
                name.as_ptr(),
                flags,
                descriptor.as_mut_ptr().cast(),
                needed,
                &mut needed,
            )
        },
        0
    );
    descriptor.truncate(needed as usize);
    let mut hash = std::collections::hash_map::DefaultHasher::new();
    descriptor.hash(&mut hash);
    // Invariant: Capture bytes separately in fixture_snapshot, and here preserve native timestamps,
    // attributes, owner and DACL: a same-size write or permission repair must not pass a read-only
    // regression merely because length stayed put.
    (
        metadata.len(),
        (
            metadata.last_write_time() as i64,
            metadata.creation_time() as i64,
        ),
        (metadata.file_attributes() as i64, hash.finish() as i64),
    )
}

type FixtureSnapshot = Vec<(
    std::path::PathBuf,
    (u64, (i64, i64), (i64, i64)),
    Option<Vec<u8>>,
)>;
fn fixture_snapshot(root: &Path) -> FixtureSnapshot {
    fn visit(path: &Path, snapshot: &mut FixtureSnapshot) {
        if path
            .file_name()
            .is_some_and(|name| name == "credential-touched")
        {
            return;
        }
        snapshot.push((
            path.to_owned(),
            metadata(path),
            path.is_file().then(|| fs::read(path).unwrap()),
        ));
        if path.is_dir() {
            for entry in fs::read_dir(path).unwrap() {
                visit(&entry.unwrap().path(), snapshot);
            }
        }
    }
    let mut snapshot = Vec::new();
    visit(root, &mut snapshot);
    snapshot.sort_by(|a, b| a.0.cmp(&b.0));
    snapshot
}

#[test]
fn malformed_gmail_action_previews_refuse_without_credentials_or_writes() {
    let fixture = mail_list_fixture(true);
    let touched = fixture.0.join("credential-touched");
    fs::write(
        fixture.0.join("bin/secret-tool"),
        format!("#!/bin/sh\n: > '{}'\nexit 1\n", touched.display()),
    )
    .unwrap();
    let before = fixture_snapshot(&fixture.0);
    for (account, bad) in [
        ("gmail@example.org", "."),
        ("gmail@example.org", ".."),
        ("gmail@example.org", " "),
        ("gmail@example.org", "bad\n"),
        ("gmail@example.org", "bad\0"),
    ] {
        for operation in ["read", "trash"] {
            let output = root_mail(
                &fixture.0,
                &["call", "mail.act", "--json"],
                serde_json::json!({"account":account,"operation":operation,"ids":[bad]})
                    .to_string()
                    .as_bytes(),
            );
            assert_eq!(output.status.code(), Some(1), "{account} {bad}: {output:?}");
            assert_eq!(
                serde_json::from_slice::<Value>(&output.stdout).unwrap(),
                serde_json::json!({"ok":false,"error":{"code":"invalid_params"}})
            );
            assert_eq!(fixture_snapshot(&fixture.0), before);
            assert!(!touched.exists(), "{account} {bad} reached credentials");
        }
    }
}

#[test]
fn configured_list_failures_do_not_repair_registry_metadata() {
    let fixture = mail_list_fixture(false);
    let directory = config_root(&fixture.0).join("omamail");
    let registry = directory.join("accounts.json");
    let before = (
        metadata(&directory),
        metadata(&registry),
        fs::read(&registry).unwrap(),
    );
    for (account, expected_error) in [
        ("gmail@example.org", None),
        ("imap:imap@example.org", Some("mail_account_unknown")),
        ("jmap:jmap@example.org", Some("mail_account_unknown")),
        ("outlook:outlook@example.org", Some("mail_account_unknown")),
    ] {
        let output = call_mail_list(&fixture.0, account);
        assert!(!output.status.success(), "{account}: {output:?}");
        if let Some(expected_error) = expected_error {
            assert_eq!(
                serde_json::from_slice::<Value>(&output.stdout).unwrap()["error"]["code"],
                expected_error,
                "{account} must stop at the synthetic keyring failure before a network request"
            );
        }
        assert_eq!(
            (
                metadata(&directory),
                metadata(&registry),
                fs::read(&registry).unwrap()
            ),
            before,
            "{account} changed the configured account registry"
        );
    }
}

#[test]
fn configured_read_failures_do_not_repair_registry_metadata() {
    let fixture = mail_list_fixture(false);
    let directory = config_root(&fixture.0).join("omamail");
    let registry = directory.join("accounts.json");
    let before = (
        metadata(&directory),
        metadata(&registry),
        fs::read(&registry).unwrap(),
    );
    for (account, id, expected_error) in [
        ("gmail@example.org", "safe-message", None),
        (
            "imap:imap@example.org",
            "7:INBOX",
            Some("mail_account_unknown"),
        ),
        (
            "jmap:jmap@example.org",
            "safe-message",
            Some("mail_account_unknown"),
        ),
        (
            "outlook:outlook@example.org",
            "7:INBOX",
            Some("mail_account_unknown"),
        ),
    ] {
        let output = call_mail_read(&fixture.0, account, id);
        assert!(!output.status.success(), "{account}: {output:?}");
        if let Some(expected_error) = expected_error {
            assert_eq!(
                serde_json::from_slice::<Value>(&output.stdout).unwrap()["error"]["code"],
                expected_error,
                "{account} must stop at the synthetic keyring failure before a network request"
            );
        }
        assert_eq!(
            (
                metadata(&directory),
                metadata(&registry),
                fs::read(&registry).unwrap()
            ),
            before,
            "{account} changed the configured account registry"
        );
    }
}

#[test]
fn generic_call_dispatches_and_defaults_empty_input() {
    let output = call("system.info", b"");
    assert!(output.status.success());
    assert!(output.stderr.is_empty());
    let value: Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(value["ok"], true);
    assert_eq!(value["result"]["name"], "omamail");
}

#[test]
fn retired_provider_methods_are_not_public_methods() {
    for method in [
        "jmap.actionAvailability",
        "jmap.actionRows",
        "jmap.read",
        "imap.request",
        "smtp.send",
        "outlook.graphSend",
        "hey.send",
        "auth.store",
    ] {
        let output = call(method, b"{}");
        assert_eq!(output.status.code(), Some(1));
        let value: Value = serde_json::from_slice(&output.stdout).unwrap();
        assert_eq!(value["error"]["code"], "unknown_method", "{method}");
    }
}

#[test]
fn generic_call_errors_are_json_without_echoing_input() {
    for (method, input, code) in [
        (
            "system.info",
            b"{synthetic-secret".as_slice(),
            "invalid_json",
        ),
        (
            "system.info",
            b"\"synthetic-secret\"".as_slice(),
            "invalid_params",
        ),
        ("synthetic-secret", b"{}".as_slice(), "unknown_method"),
    ] {
        let output = call(method, input);
        assert_eq!(output.status.code(), Some(1));
        assert!(output.stderr.is_empty());
        let value: Value = serde_json::from_slice(&output.stdout).unwrap();
        assert_eq!(
            value,
            serde_json::json!({"ok": false, "error": {"code": code}})
        );
    }
}

#[test]
fn generic_call_bounds_input_before_dispatch() {
    let mut input = b"{}".to_vec();
    input.resize(1024 * 1024, b' ');
    assert!(call("system.info", &input).status.success());
    input.push(b' ');
    let output = call("system.info", &input);
    assert_eq!(output.status.code(), Some(1));
    let value: Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(value["error"]["code"], "input_too_large");
}

#[test]
fn generic_call_uses_stateful_session_dispatcher() {
    let output = call("upload.begin", b"{\"size\":0}");
    assert!(output.status.success());
    let value: Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(value["ok"], true);
    assert!(value["result"]["upload"].is_string());
}

#[test]
fn list_without_a_configured_account_is_a_stable_json_error() {
    let output = call_in_empty_home("mail.list", b"{}");
    assert_eq!(output.status.code(), Some(1));
    assert_eq!(
        serde_json::from_slice::<Value>(&output.stdout).unwrap(),
        serde_json::json!({"ok":false,"error":{"code":"mail_account_unknown"}})
    );
    assert!(output.stderr.is_empty());
}

#[test]
fn read_rejects_unknown_accounts_and_unsafe_message_ids_without_writing_config() {
    let unknown = call_in_empty_home(
        "mail.read",
        b"{\"account\":\"missing@example.org\",\"id\":\"one\"}",
    );
    assert_eq!(unknown.status.code(), Some(1));
    assert_eq!(
        serde_json::from_slice::<Value>(&unknown.stdout).unwrap(),
        serde_json::json!({"ok":false,"error":{"code":"mail_account_unknown"}})
    );

    let fixture = mail_list_fixture(false);
    let unsafe_id = call_mail_read(&fixture.0, "gmail@example.org", "one\ntwo");
    assert_eq!(unsafe_id.status.code(), Some(1));
    assert_eq!(
        serde_json::from_slice::<Value>(&unsafe_id.stdout).unwrap(),
        serde_json::json!({"ok":false,"error":{"code":"invalid_params"}})
    );
}

#[test]
fn default_output_is_a_table_and_json_is_global() {
    let pretty = omamail(&["info"]);
    assert!(pretty.status.success());
    let text = String::from_utf8(pretty.stdout).unwrap();
    assert!(text.contains("| Field"), "{text}");
    assert!(text.contains("omamail"));
    assert!(serde_json::from_str::<Value>(&text).is_err());
    for args in [["--json", "info"], ["info", "--json"]] {
        let output = omamail(&args);
        assert!(output.status.success());
        let value: Value = serde_json::from_slice(&output.stdout).unwrap();
        assert_eq!(value["name"], "omamail");
        for method in value["methods"].as_array().unwrap() {
            assert!(
                text.lines()
                    .any(|line| { line.trim_matches('|').trim() == method.as_str().unwrap() }),
                "method needs its own row: {method}\n{text}"
            );
        }
    }
    let providers = omamail(&["providers", "list"]);
    assert!(providers.status.success());
    let text = String::from_utf8(providers.stdout).unwrap();
    assert!(text.contains("Gmail") && text.contains("|"));
}

#[test]
fn clap_help_and_invalid_commands_do_not_start_the_backend() {
    for args in [
        ["--backend"].as_slice(),
        ["serve", "--json"].as_slice(),
        ["nonsense"].as_slice(),
    ] {
        assert_eq!(omamail(args).status.code(), Some(2));
    }
    let help = omamail(&["accounts", "--help"]);
    assert!(help.status.success());
    assert!(String::from_utf8(help.stdout).unwrap().contains("list"));
}

#[test]
fn pretty_call_errors_go_to_stderr() {
    let output = omamail(&["call", "unknown"]);
    assert_eq!(output.status.code(), Some(1));
    assert!(output.stdout.is_empty());
    assert_eq!(output.stderr, b"omamail: unknown_method\n");
}

fn root_mail(root: &Path, args: &[&str], body: &[u8]) -> Output {
    let mut child = Command::new(env!("CARGO_BIN_EXE_omamail"))
        .args(args)
        .env("OMAMAIL_INTEGRATION_HOME", root)
        .env("XDG_CONFIG_HOME", root.join("config"))
        .env("XDG_CACHE_HOME", root.join("cache"))
        .env("XDG_STATE_HOME", root.join("state"))
        .env("HOME", root.join("home"))
        .env("PATH", root.join("bin"))
        .env(
            "OMAMAIL_INTEGRATION_CREDENTIAL_FILE",
            root.join("integration-credential"),
        )
        .env(
            "OMAMAIL_INTEGRATION_CREDENTIAL_TRACE",
            root.join("credential-touched"),
        )
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    if args.contains(&"send") {
        let argv = process_argv(child.id());
        assert!(
            !argv
                .windows(b"private body".len())
                .any(|text| text == b"private body")
        );
        assert!(
            !argv
                .windows(b"synthetic".len())
                .any(|text| text == b"synthetic")
        );
    }
    let _ = child.stdin.take().unwrap().write_all(body);
    child.wait_with_output().unwrap()
}

#[cfg(target_os = "linux")]
fn process_argv(pid: u32) -> Vec<u8> {
    fs::read(format!("/proc/{pid}/cmdline")).unwrap()
}

#[cfg(target_os = "macos")]
fn process_argv(pid: u32) -> Vec<u8> {
    let output = Command::new("ps")
        .args(["-p", &pid.to_string(), "-o", "command="])
        .output()
        .unwrap();
    assert!(output.status.success());
    output.stdout
}

#[cfg(target_os = "windows")]
fn process_argv(pid: u32) -> Vec<u8> {
    windows_process::process_argv(pid)
}

#[cfg(target_os = "windows")]
#[path = "support/windows_process.rs"]
mod windows_process;

#[test]
fn task_commands_have_only_the_approved_vocabulary_and_execute_switch() {
    let help = String::from_utf8(omamail(&["--help"]).stdout).unwrap();
    for name in ["list", "read", "mark", "archive", "trash", "spam", "send"] {
        assert!(
            help.lines()
                .any(|line| line.split_whitespace().next() == Some(name)),
            "missing {name}"
        );
        let output = omamail(&[name, "--help"]);
        assert!(output.status.success());
        let text = String::from_utf8(output.stdout).unwrap();
        assert!(text.contains("--account"));
        assert_eq!(text.contains("--execute"), !matches!(name, "list" | "read"));
    }
    for args in [
        vec!["mail", "list"],
        vec!["unstar", "m1"],
        vec!["star", "m1"],
        vec!["unread", "m1"],
        vec!["show", "m1"],
        vec!["mark", "starred", "m1"],
        vec!["mark", "read"],
        vec!["archive"],
        vec!["list", "--execute"],
        vec!["read", "m1", "--execute"],
        vec!["send", "--body", "secret"],
    ] {
        assert_eq!(omamail(&args).status.code(), Some(2), "{args:?}");
    }
}

#[test]
fn root_mutations_preview_exact_intent_and_never_touch_storage_or_credentials() {
    let fixture = mail_list_fixture(false);
    let config = config_root(&fixture.0).join("omamail/accounts.json");
    let before = (metadata(&config), fs::read(&config).unwrap());
    let sentinel = fixture.0.join("credential-touched");
    fs::write(
        fixture.0.join("bin/secret-tool"),
        format!("#!/bin/sh\n: > '{}'\nexit 1\n", sentinel.display()),
    )
    .unwrap();
    for operation in [
        "read", "unread", "star", "unstar", "archive", "trash", "spam",
    ] {
        let mut args = if matches!(operation, "read" | "unread" | "star" | "unstar") {
            vec!["mark", operation]
        } else {
            vec![operation]
        };
        args.extend(["one", "two", "one"]);
        for before_command in [true, false] {
            let mut args = args.clone();
            if before_command {
                args.insert(0, "--json");
            } else {
                args.push("--json");
            }
            let output = root_mail(&fixture.0, &args, b"ignored stdin");
            assert!(output.status.success(), "{args:?}: {output:?}");
            assert_eq!(
                serde_json::from_slice::<Value>(&output.stdout).unwrap(),
                serde_json::json!({"ok":true,"result":{
                    "dryRun":true,"executed":false,"operation":operation,"accountId":"gmail@example.org",
                    "requestedIds":["one","two","one"],"targetIds":["one","two"]
                }})
            );
            assert!(output.stderr.is_empty());
        }
    }
    assert_eq!((metadata(&config), fs::read(&config).unwrap()), before);
    assert!(!sentinel.exists());
    assert_no_runtime_storage(&fixture.0);
}

#[test]
fn root_mail_errors_use_stable_envelopes_and_never_fall_back_accounts() {
    let fixture = mail_list_fixture(false);
    for args in [
        vec!["list"],
        vec!["read", "one"],
        vec!["mark", "read", "one"],
        vec!["archive", "one"],
        vec!["trash", "one"],
        vec!["spam", "one"],
        vec!["send"],
    ] {
        for before in [true, false] {
            let mut args = args.clone();
            args.extend(["--account", "missing@example.org"]);
            if before {
                args.insert(0, "--json");
            } else {
                args.push("--json");
            }
            let output = root_mail(&fixture.0, &args, b"");
            assert_eq!(output.status.code(), Some(1), "{args:?}: {output:?}");
            assert_eq!(
                serde_json::from_slice::<Value>(&output.stdout).unwrap(),
                serde_json::json!({"ok":false,"error":{"code":"mail_account_unknown"}})
            );
            assert!(output.stderr.is_empty());
        }
    }
    let output = root_mail(&fixture.0, &["read", "secret\nvalue"], b"");
    assert_eq!(output.status.code(), Some(1));
    assert!(output.stdout.is_empty());
    assert_eq!(output.stderr, b"omamail: invalid_params\n");
}

#[cfg(unix)]
#[test]
fn invalid_send_inputs_never_reach_credentials_or_outbox_even_with_execute() {
    use std::os::unix::fs::symlink;
    let fixture = mail_list_fixture(false);
    let file = fixture.0.join("file.txt");
    fs::write(&file, b"bytes").unwrap();
    let link = fixture.0.join("link.txt");
    symlink(&file, &link).unwrap();
    let fifo = fixture.0.join("pipe.txt");
    let name = std::ffi::CString::new(fifo.to_str().unwrap()).unwrap();
    assert_eq!(unsafe { libc::mkfifo(name.as_ptr(), 0o600) }, 0);
    let sentinel = fixture.0.join("credential-touched");
    fs::write(
        fixture.0.join("bin/secret-tool"),
        format!("#!/bin/sh\n: > '{}'\nexit 1\n", sentinel.display()),
    )
    .unwrap();
    for extra in [
        vec!["--subject", "secret\r"],
        vec!["--subject", "secret\n"],
        vec!["--subject", "secret\r\n"],
        vec!["--to", "secret\t@example.org"],
        vec!["--from", "secret\n@example.org"],
        vec!["--attach", "relative.txt"],
        vec!["--attach", link.to_str().unwrap()],
        vec!["--attach", fifo.to_str().unwrap()],
        vec!["--attach", fixture.0.to_str().unwrap()],
    ] {
        for execute in [false, true] {
            let mut args = vec![
                "send",
                "--account",
                "gmail@example.org",
                "--to",
                "one@example.org",
                "--json",
            ];
            args.extend(extra.iter().copied());
            if execute {
                args.push("--execute");
            }
            let output = root_mail(&fixture.0, &args, b"private body");
            assert_eq!(output.status.code(), Some(1), "{args:?}: {output:?}");
            let value: Value = serde_json::from_slice(&output.stdout).unwrap();
            assert_eq!(value["ok"], false);
            assert!(value["error"]["code"].is_string());
            assert!(!String::from_utf8_lossy(&output.stdout).contains("secret"));
            assert!(!String::from_utf8_lossy(&output.stdout).contains("private body"));
            assert!(output.stderr.is_empty());
        }
    }
    assert!(!sentinel.exists());
    assert_no_runtime_storage(&fixture.0);
}

#[test]
fn only_send_consumes_stdin() {
    let fixture = mail_list_fixture(false);
    for args in [
        vec!["list"],
        vec!["read", "one"],
        vec!["mark", "read", "one"],
        vec!["archive", "one"],
        vec!["trash", "one"],
        vec!["spam", "one"],
    ] {
        let mut child = Command::new(env!("CARGO_BIN_EXE_omamail"))
            .args(args)
            .env("OMAMAIL_INTEGRATION_HOME", &fixture.0)
            .env("XDG_CONFIG_HOME", fixture.0.join("config"))
            .env("HOME", fixture.0.join("home"))
            .env("PATH", fixture.0.join("bin"))
            .env(
                "OMAMAIL_INTEGRATION_CREDENTIAL_FILE",
                fixture.0.join("integration-credential"),
            )
            .env(
                "OMAMAIL_INTEGRATION_CREDENTIAL_TRACE",
                fixture.0.join("credential-touched"),
            )
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        let input = child.stdin.take().unwrap();
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(3);
        loop {
            if child.try_wait().unwrap().is_some() {
                break;
            }
            if std::time::Instant::now() >= deadline {
                child.kill().unwrap();
                child.wait().unwrap();
                panic!("read-only/action command consumed stdin");
            }
            std::thread::sleep(std::time::Duration::from_millis(5));
        }
        drop(input);
    }
}

#[test]
fn failed_execution_retains_target_results_and_exits_one() {
    let fixture = mail_list_fixture(false);
    let output = root_mail(
        &fixture.0,
        &[
            "mark",
            "read",
            "message-7",
            "message-8",
            "--account",
            "gmail@example.org",
            "--execute",
            "--json",
        ],
        b"",
    );
    assert_eq!(output.status.code(), Some(1));
    let value: Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(
        value,
        serde_json::json!({"ok":false,"error":{"code":"mail_action_failed"},"result":{
            "dryRun":false,"executed":true,"accountId":"gmail@example.org","operation":"read",
            "requestedIds":["message-7","message-8"],"targetIds":["message-7","message-8"],"succeededIds":[],"failedIds":["message-7","message-8"]
        }})
    );
    assert!(output.stderr.is_empty());
}

#[cfg(not(all(feature = "agent", unix)))]
#[test]
fn agent_disabled_build_has_no_worker_or_agent_rpc() {
    let worker = omamail(&["agent-worker", "synthetic-job"]);
    assert!(!worker.status.success());
    assert!(String::from_utf8_lossy(&worker.stderr).contains("unrecognized subcommand"));
    let info = omamail(&["info", "--json"]);
    assert!(info.status.success());
    let info: Value = serde_json::from_slice(&info.stdout).unwrap();
    assert_eq!(info["capabilities"]["agent"], false);
    assert!(
        info["methods"]
            .as_array()
            .unwrap()
            .iter()
            .all(|method| !method.as_str().unwrap().starts_with("agent."))
    );
    for method in [
        "agent.context",
        "agent.contextCancel",
        "agent.jobsList",
        "agent.jobsProjection",
        "agent.jobStart",
        "agent.jobShow",
        "agent.jobCancel",
        "agent.jobForget",
    ] {
        let output = omamail(&["call", method, "--json"]);
        assert!(!output.status.success());
        assert_eq!(
            serde_json::from_slice::<Value>(&output.stdout).unwrap()["error"]["code"],
            "unknown_method"
        );
    }
}
