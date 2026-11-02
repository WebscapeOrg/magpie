use super::*;

const INTERVAL: i64 = 30 * 60_000;

fn due(record: &Value, revision: &str, now: i64) -> bool {
    if record["revision"] == revision {
        return false;
    }
    let Some(at) = record["attemptedAt"].as_i64() else {
        return true;
    };
    now >= at && now.saturating_sub(at) >= INTERVAL
}

fn eligible(device: &Value, id: &Value) -> bool {
    device["backgroundRefresh"] == true
        && device["pushToken"]
            .as_str()
            .is_some_and(|token| !token.is_empty())
        && selected(device, id)
}

impl Service {
    pub(super) async fn background_notifications(
        &self,
        engine: &Engine,
        devices: &mut Value,
        current: &Value,
    ) -> Result<()> {
        let mut revisions = serde_json::Map::new();
        for account in current["accounts"].as_array().into_iter().flatten() {
            let Some(id) = account["id"].as_str() else {
                continue;
            };
            if !devices
                .as_object()
                .ok_or("phone_storage_invalid")?
                .values()
                .any(|device| eligible(device, &account["id"]))
            {
                continue;
            }
            let Ok(snapshot) = engine.local_mail.background_snapshot(id).await else {
                continue;
            };
            if snapshot["paused"] == true || snapshot["history"].as_str().is_none_or(str::is_empty)
            {
                continue;
            }
            let Some(ids) = snapshot["ids"].as_array() else {
                continue;
            };
            let Ok(descriptions) = crate::inbox::background_revision(id, ids) else {
                continue;
            };
            revisions.insert(id.to_owned(), json!([snapshot["history"], descriptions]));
        }
        let mut sender = self.push.lock().await;
        for (id, device) in devices.as_object_mut().ok_or("phone_storage_invalid")? {
            let owned: serde_json::Map<_, _> = revisions
                .iter()
                .filter(|(id, _)| eligible(device, &json!(id)))
                .map(|(id, revision)| (id.clone(), revision.clone()))
                .collect();
            if owned.is_empty() {
                continue;
            }
            let revision = storage::hash(
                json!([device["pushToken"], device["pushEnvironment"], owned])
                    .to_string()
                    .as_bytes(),
            );
            let name = format!("refresh-{}.json", storage::hash(id.as_bytes()));
            let mut record = storage::read(&name)?;
            let now = crate::inbox::now();
            if !due(&record, &revision, now) {
                continue;
            }
            record["attemptedAt"] = json!(now);
            storage::write(&name, &record)?;
            let result = sender
                .deliver(
                    device,
                    json!({"aps":{"content-available":1},"magpieRefresh":1}),
                    "magpie-mail-refresh",
                )
                .await;
            match result {
                Ok(Delivery::Accepted) => {
                    record["revision"] = json!(revision);
                }
                Ok(Delivery::Gone) => {
                    device["pushToken"] = Value::Null;
                    device["pushError"] = json!("push_registration_expired");
                }
                _ => {}
            }
            storage::write(&name, &record)?;
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn wakes_coalesce_changes_and_persist_a_half_hour_attempt_limit() {
        assert!(due(&json!({}), "a", 10));
        let record = json!({"attemptedAt":100,"revision":"a"});
        assert!(!due(&record, "a", 100 + INTERVAL));
        assert!(!due(&record, "b", 99));
        assert!(!due(&record, "b", 100 + INTERVAL - 1));
        assert!(due(&record, "b", 100 + INTERVAL));
        assert!(!due(&json!({"attemptedAt":100}), "failed-attempt", 101));
    }
    #[test]
    fn silent_push_needs_opt_in_token_and_both_account_scopes_but_no_alert_permission() {
        let mut device = json!({"backgroundRefresh":true,"notifications":false,"pushToken":"synthetic","accounts":[{"id":"a"}],"notificationAccounts":["a"]});
        assert!(eligible(&device, &json!("a")));
        assert!(!eligible(&device, &json!("b")));
        device["notificationAccounts"] = json!([]);
        assert!(!eligible(&device, &json!("a")));
        device["notificationAccounts"] = json!(["a"]);
        device["backgroundRefresh"] = json!(false);
        assert!(!eligible(&device, &json!("a")));
        assert!(!eligible(
            &json!({"accounts":[{"id":"a"}],"pushToken":"synthetic"}),
            &json!("a")
        ));
        assert_eq!(
            push_type(&json!({"aps":{"content-available":1},"magpieRefresh":1})),
            "background"
        );
        assert_eq!(push_type(&json!({"aps":{"badge":1}})), "alert");
    }
}
