//! Provider capability ceilings shared by backend operations and CLI discovery.
//!
//! Account refusals may remove a capability but cannot grant one. The serialized
//! names match the existing UI registry so clients need no provider-specific map.

use serde_json::{Map, Value, json};
pub mod domain;
pub mod gmail;
pub mod gmail_credentials;
pub mod gmail_http;

const CAPABILITIES: &[&str] = &[
    "labels",
    "move",
    "threads",
    "conversations",
    "archive",
    "spam",
    "star",
    "batch",
    "web",
    "webBox",
    "search",
    "manageLabels",
    "send",
];

const GMAIL_CAPABILITIES: &[&str] = &[
    "labels",
    "manageLabels",
    "move",
    "threads",
    "archive",
    "spam",
    "star",
    "batch",
    "web",
    "webBox",
    "search",
    "send",
];

pub fn list() -> Value {
    let capabilities: Map<String, Value> = CAPABILITIES
        .iter()
        .map(|name| {
            (
                (*name).to_owned(),
                Value::Bool(GMAIL_CAPABILITIES.contains(name)),
            )
        })
        .collect();
    json!([{
        "id": "gmail",
        "name": "Gmail",
        "summary": "Google's own API. Needs an OAuth client you create once.",
        "auth": "oauth",
        "capabilities": capabilities,
    }])
}

pub fn can(provider: &str, capability: &str, refusals: &Value) -> bool {
    provider.trim().eq_ignore_ascii_case("gmail")
        && GMAIL_CAPABILITIES.contains(&capability)
        && refusals.get(capability).is_none_or(Value::is_null)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unsupported_providers_and_operations_are_never_granted() {
        for provider in ["imap", "outlook", "hey", "jmap", "unknown", ""] {
            for &operation in CAPABILITIES {
                assert!(!can(provider, operation, &Value::Null));
                assert!(!can(provider, operation, &json!({operation: null})));
            }
        }
        assert!(!can("gmail", "unknown", &Value::Null));
        assert!(!can("gmail", "conversations", &Value::Null));
        assert!(can(" GMAIL ", "send", &Value::Null));
    }

    #[test]
    fn presence_of_non_null_refusal_removes_capability() {
        for reason in [
            json!("No Archive mailbox"),
            json!(""),
            json!(false),
            json!(0),
        ] {
            assert!(!can("gmail", "archive", &json!({"archive": reason})));
        }
        assert!(can("gmail", "archive", &json!({"archive": null})));
        assert!(can("gmail", "archive", &json!({"send": "Read only"})));
    }

    #[test]
    fn discovery_contains_only_gmail_and_its_capability_ceiling() {
        let value = list();
        let providers = value.as_array().unwrap();
        assert_eq!(
            providers
                .iter()
                .map(|p| p["id"].as_str().unwrap())
                .collect::<Vec<_>>(),
            ["gmail"]
        );
        for provider in providers {
            assert_eq!(
                provider["capabilities"].as_object().unwrap().len(),
                CAPABILITIES.len()
            );
            for capability in CAPABILITIES {
                assert_eq!(
                    provider["capabilities"][capability],
                    can(provider["id"].as_str().unwrap(), capability, &Value::Null)
                );
            }
        }
        assert_eq!(providers[0]["capabilities"]["conversations"], false);
    }
}
