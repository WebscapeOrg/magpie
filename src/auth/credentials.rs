//! Account-bound Google credential resolution.
use super::*;
use crate::credentials::{
    self as store, CredentialKey, CredentialKind, Error as StoreError, Secret,
};

fn validate_account(provider: &str, account: &str) -> Result<(), &'static str> {
    if provider != "gmail" {
        return Err("auth_provider_invalid");
    }
    if account.len() > 1024 || !crate::account::valid_email(account) || account.contains(':') {
        return Err("auth_account_invalid");
    }
    Ok(())
}

pub fn settings(provider: &str, account: &str) -> Result<Value, &'static str> {
    validate_account(provider, account)?;
    settings_with(account, crate::account::raw_registry()?)
}

pub fn settings_readonly(provider: &str, account: &str) -> Result<Value, &'static str> {
    validate_account(provider, account)?;
    settings_with(account, crate::account::raw_registry_readonly()?)
}

fn settings_with(account: &str, raw: Value) -> Result<Value, &'static str> {
    crate::account::summarize(&serde_json::to_vec(&raw).map_err(|_| "accounts_invalid")?)?;
    let entries = raw["accounts"].as_array().ok_or("accounts_invalid")?;
    for entry in entries {
        let email = entry["email"].as_str().unwrap_or("").trim();
        if email.eq_ignore_ascii_case(account) {
            return Ok(entry.clone());
        }
    }
    Err("auth_account_missing")
}

fn store_error(error: StoreError) -> &'static str {
    match error {
        StoreError::Missing => "auth_signed_out",
        StoreError::InvalidKey => "auth_account_invalid",
        StoreError::InvalidSecret | StoreError::TooLarge => "auth_secret_invalid",
        StoreError::Unavailable | StoreError::Ambiguous => "auth_keyring_failed",
    }
}

pub(super) async fn store_google(
    client_id: &str,
    account: &str,
    token: &str,
) -> Result<(), &'static str> {
    store_google_with(client_id, account, token, |key, secret| async {
        store::put(key, secret).await.map_err(store_error)
    })
    .await
}

async fn store_google_with<Persist, PersistFuture>(
    client_id: &str,
    account: &str,
    token: &str,
    mut persist: Persist,
) -> Result<(), &'static str>
where
    Persist: FnMut(CredentialKey, Secret) -> PersistFuture,
    PersistFuture: std::future::Future<Output = Result<(), &'static str>>,
{
    if client_id.is_empty()
        || client_id.len() > 1024
        || account.is_empty()
        || !crate::account::valid_email(account)
        || account.contains(':')
        || account.len() > 1024
        || account
            .chars()
            .any(|character| character.is_control() || character.is_whitespace())
        || token.is_empty()
        || client_id.chars().any(char::is_control)
        || token.len() > 16384
        || token
            .chars()
            .any(|character| character.is_whitespace() || character.is_control())
    {
        return Err("auth_secret_invalid");
    }
    let key = CredentialKey {
        provider: "gmail".into(),
        account_id: account.to_lowercase(),
        kind: CredentialKind::GoogleRefreshToken {
            client_id: client_id.into(),
        },
    };
    persist(
        key,
        Secret::new(token.as_bytes().to_vec()).map_err(store_error)?,
    )
    .await?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn settings_preserve_google_workspace_identity_and_ownership() {
        let raw = json!({"version":1,"accounts":[
            {"email":"OWNER@workspace.example","clientId":"first","clientSecret":"one"},
            {"email":"other@workspace.example","provider":"gmail","clientId":"second","clientSecret":"two"}
        ]});
        assert_eq!(
            settings_with("owner@workspace.example", raw.clone()).unwrap()["clientId"],
            "first"
        );
        assert_eq!(
            settings_with("OTHER@workspace.example", raw.clone()).unwrap()["clientId"],
            "second"
        );
        assert_eq!(
            settings_with("missing@workspace.example", raw),
            Err("auth_account_missing")
        );
    }

    #[test]
    fn unsupported_provider_never_resolves_google_credentials() {
        for provider in ["imap", "outlook", "jmap", "hey", "caldav", "unknown"] {
            assert_eq!(
                settings(provider, "owner@workspace.example"),
                Err("auth_provider_invalid")
            );
            assert_eq!(
                settings_readonly(provider, "owner@workspace.example"),
                Err("auth_provider_invalid")
            );
            let raw = json!({"version":1,"accounts":[{"email":"owner@workspace.example","provider":provider}]});
            assert_eq!(
                settings_with("owner@workspace.example", raw),
                Err("accounts_provider_unsupported")
            );
        }
    }
    #[tokio::test]
    async fn google_grant_is_bound_and_secret_is_only_in_memory() {
        let calls = std::sync::Mutex::new(Vec::new());
        let synthetic = "token'\\\"测试";
        store_google_with(
            "synthetic-client",
            "USER@example.org",
            synthetic,
            |args, bytes| {
                calls.lock().unwrap().push((args, bytes));
                async { Ok(()) }
            },
        )
        .await
        .unwrap();
        let calls = calls.into_inner().unwrap();
        assert_eq!(calls.len(), 1);
        assert_eq!(
            calls[0].0,
            CredentialKey {
                provider: "gmail".into(),
                account_id: "user@example.org".into(),
                kind: CredentialKind::GoogleRefreshToken {
                    client_id: "synthetic-client".into()
                },
            }
        );
        assert!(calls[0].1.as_slice() == synthetic.as_bytes());
    }
    #[tokio::test]
    async fn invalid_google_grant_never_invokes_keyring() {
        for bad in ["", "a\n", "a\r", "a\r\n", "a\0", "a "] {
            assert!(
                store_google_with("client", "user@example.org", bad, |_, _| async {
                    panic!("must not invoke keyring")
                })
                .await
                .is_err()
            );
        }
        for bad in [
            "",
            "user@example.org\n",
            "user@example.org\0",
            "user@example.org\r\n",
        ] {
            assert!(
                store_google_with("client", bad, "synthetic", |_, _| async {
                    panic!("must not invoke keyring")
                })
                .await
                .is_err()
            );
        }
    }
}
