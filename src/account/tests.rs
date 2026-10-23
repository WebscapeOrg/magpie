use super::summarize;
use serde_json::json;

#[test]
fn registry_preserves_google_workspace_identity_and_secret_projection() {
    let source = json!({"version":1,"activeId":"SECOND@WORK.EXAMPLE","accounts":[
        {"email":"A@example.org","id":"forged","clientSecret":"synthetic-secret"},
        {"email":"a@example.org","provider":"gmail"},
        {"email":"Second@work.example","provider":"gmail","signature":"private"},
        {"email":"","provider":"gmail","pending":true}
    ]});
    let result = summarize(source.to_string().as_bytes()).unwrap();
    assert_eq!(result["accounts"].as_array().unwrap().len(), 3);
    assert_eq!(result["accounts"][0]["id"], "a@example.org");
    assert_eq!(result["accounts"][1]["id"], "second@work.example");
    assert_eq!(result["activeId"], "second@work.example");
    assert_eq!(result["accounts"][2]["pending"], true);
    let output = result.to_string();
    for forbidden in ["synthetic", "clientSecret", "signature", "forged"] {
        assert!(!output.contains(forbidden));
    }
}

#[test]
fn corrupt_registry_is_an_error_not_empty_success() {
    assert_eq!(summarize(b"secret"), Err("accounts_invalid"));
    assert_eq!(
        summarize(br#"{"version":2,"accounts":[]}"#),
        Err("accounts_version_unsupported")
    );
    assert_eq!(summarize(br#"{"version":1}"#), Err("accounts_invalid"));
}

#[test]
fn explicit_non_google_account_refuses_entire_registry() {
    for provider in [
        json!("outlook"),
        json!("hey"),
        json!("jmap"),
        json!("imap"),
        json!("unknown"),
        json!(42),
        json!({}),
    ] {
        let source = json!({"version":1,"activeId":"person@example.org","accounts":[
            {"email":"safe@example.org"},
            {"provider":provider,"email":"person@example.org"}
        ]});
        assert_eq!(
            summarize(source.to_string().as_bytes()),
            Err("accounts_provider_unsupported")
        );
    }
}

#[test]
fn account_controls_do_not_become_registered_ids() {
    for control in ['\0', '\u{7f}', '\u{1f}'] {
        let email = format!("per{control}son@example.org");
        let source = json!({"version":1,"accounts":[{"provider":"gmail","email":email}]});
        let result = summarize(source.to_string().as_bytes()).unwrap();
        assert_eq!(result["accounts"][0]["id"], "", "{control:?}");
        assert_eq!(result["activeId"], "");
    }
}
