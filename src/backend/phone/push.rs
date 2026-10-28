use super::{Engine, Service, storage};
use crate::platform::{dirs::AppDirs, private_fs};
use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
use ring::{
    rand::SystemRandom,
    signature::{ECDSA_P256_SHA256_FIXED_SIGNING, EcdsaKeyPair},
};
use serde_json::{Value, json};
use std::{collections::HashMap, io::Read, time::Duration};
use storage::Result;

const TOPIC: &str = "XTL-DK896KQSMB.net.anotherdave.magpie";
#[derive(Debug, PartialEq)]
enum Delivery {
    Accepted,
    Gone,
    OtherKey,
    Later(i64),
    Refused,
}
fn response(status: u16, reason: &str) -> Delivery {
    match (status, reason) {
        (200, _) => Delivery::Accepted,
        (403, "BadEnvironmentKeyIdInToken") => Delivery::OtherKey,
        (410, _)
        | (_, "BadDeviceToken" | "DeviceTokenNotForTopic" | "ExpiredToken" | "Unregistered") => {
            Delivery::Gone
        }
        (429, "TooManyRequests") => Delivery::Later(60_000),
        (429, "TooManyProviderTokenUpdates") => Delivery::Later(20 * 60_000),
        (500..=599, _) => Delivery::Later(15 * 60_000),
        _ => Delivery::Refused,
    }
}
struct Credential {
    key: EcdsaKeyPair,
    id: String,
}
struct Minted {
    at: i64,
    fingerprint: String,
    token: String,
    client: reqwest::Client,
}
#[derive(Default)]
pub(super) struct Sender {
    tokens: HashMap<String, Minted>,
}
fn credential() -> Result<Vec<Credential>> {
    let root = AppDirs::discover()?.config.join("caboodle");
    let dir = private_fs::directories_readonly(&root, &["apns"])?.ok_or("push_key_missing")?;
    let mut credentials = Vec::new();
    for name in private_fs::names(&dir)? {
        let Some(id) = name
            .strip_prefix("AuthKey_")
            .and_then(|s| s.strip_suffix(".p8"))
        else {
            continue;
        };
        if id.len() != 10
            || !id
                .bytes()
                .all(|b| b.is_ascii_uppercase() || b.is_ascii_digit())
        {
            continue;
        }
        let Some(file) = private_fs::regular_readonly(&dir, &name)? else {
            continue;
        };
        let mut bytes = Vec::new();
        file.take(8193)
            .read_to_end(&mut bytes)
            .map_err(|_| "push_key_invalid")?;
        if bytes.len() > 8192 {
            return Err("push_key_invalid");
        }
        let pem = std::str::from_utf8(&bytes).map_err(|_| "push_key_invalid")?;
        let encoded = pem
            .lines()
            .filter(|line| !line.starts_with("-----"))
            .collect::<String>();
        let der = base64::engine::general_purpose::STANDARD
            .decode(encoded)
            .map_err(|_| "push_key_invalid")?;
        let key =
            EcdsaKeyPair::from_pkcs8(&ECDSA_P256_SHA256_FIXED_SIGNING, &der, &SystemRandom::new())
                .map_err(|_| "push_key_invalid")?;
        credentials.push(Credential {
            key,
            id: id.to_owned(),
        });
    }
    if credentials.is_empty() {
        return Err("push_key_missing");
    }
    Ok(credentials)
}
fn mint(key: &Credential, now: i64) -> Result<String> {
    let header = URL_SAFE_NO_PAD.encode(json!({"alg":"ES256","kid":key.id}).to_string());
    let claims = URL_SAFE_NO_PAD.encode(json!({"iss":"DK896KQSMB","iat":now}).to_string());
    let input = format!("{header}.{claims}");
    let signature = key
        .key
        .sign(&SystemRandom::new(), input.as_bytes())
        .map_err(|_| "push_sign_failed")?;
    Ok(format!(
        "{input}.{}",
        URL_SAFE_NO_PAD.encode(signature.as_ref())
    ))
}
impl Sender {
    async fn deliver(
        &mut self,
        device: &Value,
        payload: Value,
        collapse: &str,
    ) -> Result<Delivery> {
        let token = device["pushToken"]
            .as_str()
            .filter(|s| {
                s.len() >= 32
                    && s.len() <= 512
                    && s.len().is_multiple_of(2)
                    && s.bytes().all(|b| b.is_ascii_hexdigit())
            })
            .ok_or("push_token_invalid")?;
        let host = match device["pushEnvironment"].as_str() {
            Some("production") => "api.push.apple.com",
            Some("development") => "api.sandbox.push.apple.com",
            _ => return Err("push_environment_invalid"),
        };
        let body = serde_json::to_vec(&payload).map_err(|_| "push_payload_invalid")?;
        if body.len() > 4096 {
            return Err("push_payload_invalid");
        }
        for key in credential()? {
            use ring::signature::KeyPair;
            let fingerprint = storage::hash(key.key.public_key().as_ref());
            let index = format!("{host}:{}", key.id);
            let now = crate::inbox::now() / 1000;
            if self
                .tokens
                .get(&index)
                .is_none_or(|v| v.at < now - 3000 || v.fingerprint != fingerprint)
            {
                let client = reqwest::Client::builder()
                    .https_only(true)
                    .no_proxy()
                    .redirect(reqwest::redirect::Policy::none())
                    .connect_timeout(Duration::from_secs(5))
                    .timeout(Duration::from_secs(10))
                    .build()
                    .map_err(|_| "push_unavailable")?;
                self.tokens.insert(
                    index.clone(),
                    Minted {
                        at: now,
                        fingerprint,
                        token: mint(&key, now)?,
                        client,
                    },
                );
            }
            let minted = &self.tokens[&index];
            let mut auth =
                reqwest::header::HeaderValue::from_str(&format!("bearer {}", minted.token))
                    .map_err(|_| "push_key_invalid")?;
            auth.set_sensitive(true);
            let mut response = minted
                .client
                .post(format!("https://{host}/3/device/{token}"))
                .version(reqwest::Version::HTTP_2)
                .header("authorization", auth)
                .header("apns-topic", TOPIC)
                .header("apns-push-type", "alert")
                .header(
                    "apns-priority",
                    if payload["aps"]["alert"].is_null() {
                        "5"
                    } else {
                        "10"
                    },
                )
                .header("apns-expiration", (now + 3600).to_string())
                .header("apns-collapse-id", collapse)
                .header("content-type", "application/json")
                .body(body.clone())
                .send()
                .await
                .map_err(|_| "push_delivery_unconfirmed")?;
            let status = response.status();
            if status.as_u16() == 200 {
                return Ok(Delivery::Accepted);
            }
            let mut bytes = Vec::new();
            while let Some(chunk) = response
                .chunk()
                .await
                .map_err(|_| "push_delivery_unconfirmed")?
            {
                if bytes.len() + chunk.len() > 8192 {
                    return Err("push_response_invalid");
                }
                bytes.extend(chunk);
            }
            let reason =
                serde_json::from_slice::<Value>(&bytes).map_err(|_| "push_response_invalid")?;
            match self::response(status.as_u16(), reason["reason"].as_str().unwrap_or("")) {
                Delivery::OtherKey => continue,
                result => return Ok(result),
            }
        }
        Ok(Delivery::Refused)
    }
    async fn pending(&mut self, device: &mut Value, record: &mut Value) -> Result<()> {
        if record["pending"]["blocked"] == true
            || record["pending"]["retryAt"].as_i64().unwrap_or(0) > crate::inbox::now()
        {
            return Ok(());
        }
        super::history::retain(&record["pending"])?;
        let delivery = self
            .deliver(
                device,
                record["pending"]["payload"].clone(),
                record["pending"]["collapse"]
                    .as_str()
                    .ok_or("phone_storage_invalid")?,
            )
            .await;
        match delivery {
            Ok(Delivery::Accepted) => {
                record["seen"] = record["pending"]["seen"].clone();
                record["counts"] = record["pending"]["counts"].clone();
                record["badge"] = record["pending"]["payload"]["aps"]["badge"].clone();
                record["pending"] = Value::Null;
                device["pushError"] = Value::Null;
            }
            Ok(Delivery::Gone) => {
                device["notifications"] = json!(false);
                device["pushToken"] = Value::Null;
                device["pushError"] = json!("push_registration_expired");
                record["pending"] = Value::Null;
            }
            Ok(Delivery::Refused | Delivery::OtherKey) => {
                device["pushError"] = json!("push_delivery_refused");
                record["pending"]["blocked"] = json!(true);
            }
            outcome => {
                let attempts = record["pending"]["attempts"]
                    .as_u64()
                    .unwrap_or(0)
                    .saturating_add(1)
                    .min(10);
                let minimum = match outcome {
                    Ok(Delivery::Later(delay)) => delay,
                    _ => 30_000,
                };
                let delay = minimum.max((30_000i64 * (1i64 << attempts.min(5))).min(15 * 60_000));
                record["pending"]["attempts"] = json!(attempts);
                record["pending"]["retryAt"] = json!(crate::inbox::now() + delay);
                device["pushError"] = json!("push_delivery_delayed");
            }
        }
        Ok(())
    }
}
fn fresh(previous: &Value, ids: &[Value]) -> Vec<Value> {
    let Some(previous) = previous.as_array() else {
        return Vec::new();
    };
    let seen: std::collections::HashSet<_> = previous.iter().filter_map(Value::as_str).collect();
    ids.iter()
        .filter(|id| !seen.contains(id.as_str().unwrap_or("")))
        .cloned()
        .collect()
}
fn selected(device: &Value, id: &Value) -> bool {
    device["accounts"]
        .as_array()
        .into_iter()
        .flatten()
        .any(|a| a["id"] == *id)
        && device
            .get("notificationAccounts")
            .is_none_or(|ids| ids.as_array().is_some_and(|ids| ids.contains(id)))
}
impl Service {
    pub async fn notify(&self, engine: &Engine) -> Result<()> {
        let _guard = self.gate.lock().await;
        let mut devices = storage::read("devices.json")?;
        let current = crate::account::list_readonly()?;
        let mut pages = HashMap::new();
        for account in current["accounts"].as_array().into_iter().flatten() {
            let Some(id) = account["id"].as_str().filter(|s| !s.is_empty()) else {
                continue;
            };
            if !devices
                .as_object()
                .ok_or("phone_storage_invalid")?
                .values()
                .any(|d| {
                    d["notifications"] == true
                        && d["pushToken"].as_str().is_some_and(|s| !s.is_empty())
                        && selected(d, &json!(id))
                })
            {
                continue;
            }
            if let Ok(snapshot) = engine.local_mail.notification_snapshot(id).await {
                pages.insert(id.to_owned(), snapshot);
            }
        }
        let mut sender = self.push.lock().await;
        for (device_id, device) in devices.as_object_mut().ok_or("phone_storage_invalid")? {
            if device["notifications"] != true {
                continue;
            }
            let name = format!("push-{}.json", storage::hash(device_id.as_bytes()));
            let mut record = storage::read_bounded(&name, 16 * 1024 * 1024)?;
            if record["generation"] != device["pushGeneration"] {
                record = json!({"generation":device["pushGeneration"],"seen":{}});
            }
            if record["pending"].is_object() {
                if record["pending"]["counts"]
                    .as_object()
                    .is_some_and(|counts| {
                        counts.keys().any(|id| {
                            !selected(device, &json!(id))
                                || !current["accounts"]
                                    .as_array()
                                    .into_iter()
                                    .flatten()
                                    .any(|a| a["id"] == *id)
                        })
                    })
                    || !record["pending"]["accounts"]
                        .as_array()
                        .into_iter()
                        .flatten()
                        .all(|id| {
                            selected(device, id)
                                && current["accounts"]
                                    .as_array()
                                    .into_iter()
                                    .flatten()
                                    .any(|a| a["id"] == *id)
                        })
                {
                    record["pending"] = Value::Null;
                    storage::write_bounded(&name, &record, 16 * 1024 * 1024)?;
                } else {
                    sender.pending(device, &mut record).await?;
                    storage::write_bounded(&name, &record, 16 * 1024 * 1024)?;
                    if record["pending"].is_object() || device["notifications"] != true {
                        continue;
                    }
                }
            }
            let mut counts = record["counts"].as_object().cloned().unwrap_or_default();
            counts.retain(|id, _| {
                selected(device, &json!(id))
                    && current["accounts"]
                        .as_array()
                        .into_iter()
                        .flatten()
                        .any(|a| a["id"] == *id)
            });
            let mut new_ids = Vec::new();
            let mut history_accounts = Vec::new();
            let mut seen = record["seen"].as_object().cloned().unwrap_or_default();
            let mut observed = Vec::new();
            seen.retain(|id, _| selected(device, &json!(id)));
            for account in device["accounts"].as_array().into_iter().flatten() {
                if !selected(device, &account["id"]) {
                    continue;
                }
                let Some(id) = account["id"].as_str() else {
                    continue;
                };
                let Some(snapshot) = pages.get(id) else {
                    continue;
                };
                let ids = snapshot["ids"].as_array().ok_or("phone_storage_invalid")?;
                let unread = snapshot["unread"]
                    .as_array()
                    .ok_or("phone_storage_invalid")?;
                counts.insert(id.to_owned(), json!(unread.len()));
                observed.push(json!(id));
                let arrivals = fresh(&record["seen"][id], unread);
                if !arrivals.is_empty() {
                    history_accounts.push(json!(id));
                }
                for value in arrivals {
                    new_ids.push(format!("{id}:{}", value.as_str().unwrap_or("")));
                }
                seen.insert(id.to_owned(), json!(ids));
            }
            let total: usize = counts
                .values()
                .filter_map(Value::as_u64)
                .map(|v| v as usize)
                .sum();
            if new_ids.is_empty() && record["badge"] == json!(total) {
                record["seen"] = json!(seen);
                record["counts"] = json!(counts);
                storage::write_bounded(&name, &record, 16 * 1024 * 1024)?;
                continue;
            }
            new_ids.sort();
            let collapse = storage::hash(format!("{}:{total}", new_ids.join("\n")).as_bytes());
            let mut payload = json!({"aps":{"alert":{"title":"Magpie","body":if new_ids.len()==1 { "You have a new message.".to_owned() } else { format!("You have {} new messages.",new_ids.len()) }},"sound":"default","badge":total,"thread-id":"mail"},"url":format!("magpie://notifications/{collapse}")});
            if new_ids.is_empty() {
                payload = json!({"aps":{"badge":total}});
            }
            record["pending"] = json!({"payload":payload,"collapse":collapse,"seen":seen,"counts":counts,"accounts":observed,"historyAccounts":history_accounts});
            storage::write_bounded(&name, &record, 16 * 1024 * 1024)?;
            sender.pending(device, &mut record).await?;
            storage::write_bounded(&name, &record, 16 * 1024 * 1024)?;
        }
        storage::write("devices.json", &devices)
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn initial_mail_is_silent_and_seen_mail_does_not_repeat() {
        let ids = vec![json!("one"), json!("two")];
        assert!(fresh(&Value::Null, &ids).is_empty());
        assert!(fresh(&json!(ids), &ids).is_empty());
        assert_eq!(fresh(&json!(["one"]), &ids), vec![json!("two")]);
    }
    #[test]
    fn apple_responses_keep_environment_fallback_and_backoff() {
        assert_eq!(
            response(403, "BadEnvironmentKeyIdInToken"),
            Delivery::OtherKey
        );
        assert_eq!(response(410, "ExpiredToken"), Delivery::Gone);
        assert_eq!(response(429, "TooManyRequests"), Delivery::Later(60_000));
        assert_eq!(
            response(503, "ServiceUnavailable"),
            Delivery::Later(900_000)
        );
        assert_eq!(response(403, "Forbidden"), Delivery::Refused);
        assert_eq!(response(413, "PayloadTooLarge"), Delivery::Refused);
    }
    #[test]
    fn jwt_has_a_verifiable_fixed_width_es256_signature() {
        use ring::signature::{ECDSA_P256_SHA256_FIXED, KeyPair, UnparsedPublicKey};
        let rng = SystemRandom::new();
        let der = EcdsaKeyPair::generate_pkcs8(&ECDSA_P256_SHA256_FIXED_SIGNING, &rng).unwrap();
        let key = Credential {
            key: EcdsaKeyPair::from_pkcs8(&ECDSA_P256_SHA256_FIXED_SIGNING, der.as_ref(), &rng)
                .unwrap(),
            id: "TESTKEY123".into(),
        };
        let token = mint(&key, 1234).unwrap();
        let parts: Vec<_> = token.split('.').collect();
        let signature = URL_SAFE_NO_PAD.decode(parts[2]).unwrap();
        assert_eq!(signature.len(), 64);
        UnparsedPublicKey::new(&ECDSA_P256_SHA256_FIXED, key.key.public_key().as_ref())
            .verify(format!("{}.{}", parts[0], parts[1]).as_bytes(), &signature)
            .unwrap();
        let claims: Value =
            serde_json::from_slice(&URL_SAFE_NO_PAD.decode(parts[1]).unwrap()).unwrap();
        assert_eq!(claims["iat"], 1234);
        assert_eq!(claims["iss"], "DK896KQSMB");
    }
}
