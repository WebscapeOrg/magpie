use super::{LocalMail, store, sync};
use crate::providers::gmail;
use serde_json::{Value, json};
use std::time::Duration;

impl LocalMail {
    pub(crate) async fn background_refresh(
        &self,
        account: &str,
        gmail: &gmail::Session,
    ) -> Result<Value, &'static str> {
        let store = self.store(account).await?;
        let before = sync::disk(&store, |s| s.status()).await?;
        if before["paused"] == true {
            return Ok(
                json!({"accountId":account,"paused":true,"changed":false,"checked":false,"ids":[]}),
            );
        }
        let started = crate::inbox::now();
        sync::disk(&store, |s| {
            s.write(|db| store::set_state(db, "lastHistory", "0"))
        })
        .await?;
        let mut changed = false;
        let work = async {
            loop {
                let result = sync::receive(&store, gmail, account).await;
                // Invariant: background Gmail requests give way to foreground ones, such as the
                // snooze tick that runs beside this check, so a deferred request waits briefly and
                // is asked again within the bound instead of ending the check.
                if result == Err("gmail_request_deferred") {
                    tokio::time::sleep(Duration::from_millis(250)).await;
                    continue;
                }
                changed |= result == Ok(true);
                let error = result.as_ref().err().copied().unwrap_or("");
                sync::disk(&store, move |s| {
                    s.write(|db| {
                        store::set_state(db, "error", error)?;
                        if changed {
                            store::set_state(db, "updated", &crate::inbox::now().to_string())?;
                        }
                        Ok(())
                    })
                })
                .await?;
                if !result? {
                    break;
                }
                let status = sync::disk(&store, |s| s.status()).await?;
                if status["health"]["inboxComplete"] == true
                    && status["health"]["lastChecked"].as_i64().unwrap_or(0) >= started
                {
                    break;
                }
            }
            Ok::<_, &'static str>(())
        };
        let outcome = tokio::time::timeout(Duration::from_secs(18), work).await;
        let status = sync::disk(&store, |s| s.status()).await?;
        let ids = sync::disk(&store, |s| s.background_ids()).await?;
        let alerts = sync::disk(&store, |s| s.alert_snapshot())
            .await
            .unwrap_or(Value::Null);
        let checked = status["health"]["lastChecked"].as_i64().unwrap_or(0) >= started;
        let failure = match outcome {
            Ok(Err(error)) => Some(error),
            Err(_) => Some("mobile_refresh_expired"),
            _ => None,
        };
        Ok(
            json!({"accountId":account,"changed":changed,"checked":checked,"status":status,"ids":ids,"alerts":alerts,"error":failure}),
        )
    }
}
