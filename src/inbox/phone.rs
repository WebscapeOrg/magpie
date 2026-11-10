use super::{Inbox, account, fields, now, snooze, store};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
type Result<T> = std::result::Result<T, &'static str>;
fn revision(entries: &Value) -> Result<String> {
    Ok(format!(
        "{:x}",
        Sha256::digest(serde_json::to_vec(entries).map_err(|_| "inbox_storage_invalid")?)
    ))
}
fn entry_revision(entry: Option<&Value>) -> Result<String> {
    entry
        .map(|value| {
            value["generation"]
                .as_str()
                .map(str::to_owned)
                .map(Ok)
                .unwrap_or_else(|| revision(value))
        })
        .unwrap_or(Ok("absent".into()))
}
impl Inbox {
    pub async fn phone_snapshot(&self, account: &str) -> Result<Value> {
        let _guard = self.snooze_lock.lock().await;
        let mut entries = snooze::snapshot(account)?;
        let versions = snooze::revisions(account)?;
        for entry in entries.as_array_mut().ok_or("inbox_storage_invalid")? {
            let thread = entry["threadId"].as_str().ok_or("inbox_storage_invalid")?;
            let version = versions[thread]["revision"]
                .as_str()
                .map(str::to_owned)
                .unwrap_or(entry_revision(Some(entry))?);
            entry["revision"] = json!(version);
        }
        Ok(json!({"entries":entries,"revisions":versions,"revision":revision(&entries)?}))
    }
    pub async fn phone_mutate(
        &self,
        path: &str,
        p: &Value,
        device: &str,
        gmail: &crate::providers::gmail::Session,
    ) -> Result<Value> {
        fields(
            p,
            &[
                "accountId",
                "id",
                "until",
                "requestId",
                "revision",
                "issuedAt",
                "threadId",
            ],
        )?;
        let account = account(p)?;
        let id = p["id"].as_str().ok_or("invalid_params")?;
        crate::mail::action::validate_message_id(crate::mail::Provider::Gmail, id)?;
        let request = p["requestId"]
            .as_str()
            .filter(|s| !s.is_empty() && s.len() <= 128 && !s.chars().any(char::is_control))
            .ok_or("invalid_params")?;
        let issued = p["issuedAt"]
            .as_i64()
            .filter(|n| *n <= now() + 60_000 && *n > now() - 30 * 86_400_000)
            .ok_or("phone_request_expired")?;
        let expected = p["revision"]
            .as_str()
            .filter(|s| !s.is_empty() && s.len() <= 64)
            .ok_or("invalid_params")?;
        let _guard = self.snooze_lock.lock().await;
        let operation = store::key(&[device, request]);
        let digest = revision(&json!({"path":path,"params":p}))?;
        let ledger_name = store::key(&["phone-snooze-requests", device]);
        let mut ledger = store::read(&ledger_name)?.unwrap_or(json!({}));
        let current = snooze::snapshot(&account)?;
        if let Some(record) = ledger.get(&operation) {
            if record["digest"] != digest {
                return Err("phone_request_conflict");
            }
            if record["result"].is_object() {
                return Ok(record["result"].clone());
            }
            let entry = current
                .as_array()
                .ok_or("inbox_storage_invalid")?
                .iter()
                .find(|v| v["id"] == id);
            let applied = if path == "/v1/wake" {
                entry.is_none()
            } else {
                entry.is_some_and(|v| v["operationId"] == operation)
            };
            if applied {
                let result = json!({"accepted":true,"revision":revision(&current)?});
                ledger[&operation]["result"] = result.clone();
                store::write(&ledger_name, &ledger)?;
                return Ok(result);
            }
        }
        let thread = p["threadId"]
            .as_str()
            .filter(|s| !s.is_empty() && s.len() <= 4096)
            .ok_or("invalid_params")?;
        let target = current
            .as_array()
            .ok_or("inbox_storage_invalid")?
            .iter()
            .find(|v| v["threadId"] == thread);
        let versions = snooze::revisions(&account)?;
        let authority = versions[thread]["revision"]
            .as_str()
            .map(str::to_owned)
            .unwrap_or(entry_revision(target)?);
        if authority != expected && versions[thread]["operationId"] != operation {
            return Err("snooze_conflict");
        }
        if path == "/v1/snooze" {
            let resource = gmail
                .call(
                    "gmail.read",
                    &json!({"accountId":account,"id":id,"full":false}),
                )
                .await?;
            if resource["threadId"] != thread {
                return Err("snooze_conflict");
            }
        } else if !target.is_some_and(|entry| entry["id"] == id) {
            return Err("snooze_conflict");
        }
        let records = ledger.as_object_mut().ok_or("inbox_storage_invalid")?;
        records.retain(|_, v| {
            v["issuedAt"]
                .as_i64()
                .is_some_and(|n| n > now() - 30 * 86_400_000)
        });
        if records.len() >= 4096 && !records.contains_key(&operation) {
            return Err("phone_request_limit");
        }
        records.insert(
            operation.clone(),
            json!({"issuedAt":issued,"digest":digest}),
        );
        store::write(&ledger_name, &ledger)?;
        let mut params = json!({"accountId":account,"id":id});
        let method = if path == "/v1/wake" {
            "inbox.wake"
        } else {
            params["until"] = p["until"].clone();
            "inbox.snooze"
        };
        let answer = snooze::call_with_operation(method, &params, gmail, Some(&operation)).await;
        match answer {
            Ok(_) | Err("snooze_pending_retry") => (),
            Err(error) => return Err(error),
        }
        let entries = snooze::snapshot(&account)?;
        let result = json!({"accepted":true,"revision":revision(&entries)?});
        ledger[&operation]["result"] = result.clone();
        store::write(&ledger_name, &ledger)?;
        Ok(result)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[tokio::test]
    async fn a_woken_thread_rejects_an_old_offline_snooze_before_credentials() {
        if crate::mail::tests::isolated() {
            return;
        }
        let _fixture = crate::mail::tests::account_fixture(
            json!({"version":1,"accounts":[{"email":"one@example.org","provider":"gmail","clientId":"synthetic.apps.googleusercontent.com"}]}),
        );
        struct RefuseCredentials;
        impl crate::credentials::CredentialStore for RefuseCredentials {
            fn get(
                &self,
                _: &crate::credentials::CredentialKey,
            ) -> std::result::Result<crate::credentials::Secret, crate::credentials::Error>
            {
                panic!("stale command must not read credentials");
            }
            fn put(
                &self,
                _: &crate::credentials::CredentialKey,
                _: &[u8],
            ) -> std::result::Result<(), crate::credentials::Error> {
                panic!("no write");
            }
            fn delete(
                &self,
                _: &crate::credentials::CredentialKey,
            ) -> std::result::Result<(), crate::credentials::Error> {
                panic!("no delete");
            }
        }
        let _credentials = crate::credentials::tests::isolated_store(RefuseCredentials);
        let inbox = Inbox::default();
        let first = inbox.phone_snapshot("one@example.org").await.unwrap();
        assert_eq!(first["entries"], json!([]));
        snooze::advance("one@example.org", "thread-one").unwrap();
        let woke = snooze::advance("one@example.org", "thread-one").unwrap();
        let second = inbox.phone_snapshot("one@example.org").await.unwrap();
        assert_eq!(second["entries"], json!([]));
        assert_eq!(second["revisions"]["thread-one"]["revision"], woke);
        let params = json!({"accountId":"one@example.org","id":"a1","threadId":"thread-one","until":now()+60_000,"requestId":"old-offline","issuedAt":now(),"revision":"absent"});
        assert_eq!(
            inbox
                .phone_mutate(
                    "/v1/snooze",
                    &params,
                    "test-device",
                    &crate::providers::gmail::Session::default()
                )
                .await,
            Err("snooze_conflict")
        );
        assert!(
            store::read(&store::key(&["phone-snooze-requests", "test-device"]))
                .unwrap()
                .is_none()
        );
    }
}
