mod history;
mod push;
mod storage;
mod transport;
use super::Engine;
use serde_json::{Value, json};
use std::{
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};
use storage::Result;
pub use transport::serve;
struct Window {
    digest: String,
    expires: Instant,
    attempts: u8,
    accounts: Vec<Value>,
}
pub struct Service {
    push: tokio::sync::Mutex<push::Sender>,
    pub(super) active: std::sync::atomic::AtomicBool,
    pending: Arc<tokio::sync::Semaphore>,
    pairing: Mutex<Option<Window>>,
    gate: tokio::sync::Mutex<()>,
}
impl Default for Service {
    fn default() -> Self {
        Self {
            push: Default::default(),
            active: Default::default(),
            pending: Arc::new(tokio::sync::Semaphore::new(32)),
            pairing: Default::default(),
            gate: Default::default(),
        }
    }
}
fn fields(p: &Value, allowed: &[&str]) -> Result<()> {
    if p.as_object()
        .is_some_and(|v| v.keys().all(|k| allowed.contains(&k.as_str())))
    {
        Ok(())
    } else {
        Err("phone_invalid_request")
    }
}
fn text<'a>(p: &'a Value, key: &str, limit: usize) -> Result<&'a str> {
    p[key]
        .as_str()
        .filter(|v| !v.is_empty() && v.len() <= limit && !v.chars().any(char::is_control))
        .ok_or("phone_invalid_request")
}
fn device_summary(id: &str, value: &Value) -> Value {
    json!({"id":id,"name":value["name"],"created":value["created"],"notifications":value["notifications"],"accounts":value["accounts"]})
}
impl Service {
    pub(super) async fn enqueue(
        engine: Arc<Engine>,
        path: String,
        token: String,
        params: Value,
    ) -> Result<Value> {
        let permit = engine
            .phone
            .pending
            .clone()
            .try_acquire_owned()
            .map_err(|_| "phone_busy")?;
        let (send, receive) = tokio::sync::oneshot::channel();
        tokio::task::spawn_local(async move {
            let _permit = permit;
            use futures_util::FutureExt;
            let result =
                std::panic::AssertUnwindSafe(engine.phone.request(&engine, &path, &token, &params))
                    .catch_unwind()
                    .await
                    .unwrap_or(Err("phone_request_failed"));
            let _ = send.send(result);
        });
        receive.await.map_err(|_| "phone_request_failed")?
    }
    pub async fn drain(&self) {
        let _ = self.pending.acquire_many(32).await;
    }
    pub async fn desktop(&self, method: &str, params: &Value) -> Result<Value> {
        let _guard = self.gate.lock().await;
        match method {
            "phone.pairBegin" => {
                fields(params, &[])?;
                if !self.active.load(std::sync::atomic::Ordering::Acquire) {
                    return Err("phone_service_unavailable");
                }
                let accounts = crate::account::list_readonly()?["accounts"]
                    .as_array()
                    .ok_or("accounts_invalid")?
                    .iter()
                    .filter(|v| v["id"].as_str().is_some_and(|s| !s.is_empty()))
                    .cloned()
                    .collect::<Vec<_>>();
                if accounts.is_empty() {
                    return Err("phone_account_required");
                }
                let number = loop {
                    let mut bytes = [0u8; 4];
                    rustls::crypto::ring::default_provider()
                        .secure_random
                        .fill(&mut bytes)
                        .map_err(|_| "random_unavailable")?;
                    let number = u32::from_le_bytes(bytes);
                    if number < 4_294_000_000 {
                        break number % 1_000_000;
                    }
                };
                let code = format!("{number:06}");
                *self
                    .pairing
                    .lock()
                    .map_err(|_| "phone_service_unavailable")? = Some(Window {
                    digest: storage::hash(code.as_bytes()),
                    expires: Instant::now() + Duration::from_secs(300),
                    attempts: 0,
                    accounts,
                });
                Ok(json!({"code":code,"expiresInSeconds":300}))
            }
            "phone.devices" => {
                fields(params, &[])?;
                let devices = storage::read("devices.json")?;
                Ok(
                    json!({"devices":devices.as_object().ok_or("phone_storage_invalid")?.iter().map(|(id,v)|device_summary(id,v)).collect::<Vec<_>>()}),
                )
            }
            "phone.revoke" => {
                fields(params, &["id"])?;
                let id = text(params, "id", 128)?;
                let mut devices = storage::read("devices.json")?;
                devices
                    .as_object_mut()
                    .ok_or("phone_storage_invalid")?
                    .remove(id);
                storage::write("devices.json", &devices)?;
                Ok(json!({"revoked":true}))
            }
            _ => Err("unknown_method"),
        }
    }
    fn paired(&self, token: &str) -> Result<(String, Value)> {
        if token.len() != 43
            || !token
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b"_-".contains(&b))
        {
            return Err("phone_unauthorized");
        }
        let id = storage::hash(token.as_bytes());
        let devices = storage::read("devices.json")?;
        devices
            .get(&id)
            .cloned()
            .map(|device| (id, device))
            .ok_or("phone_unauthorized")
    }
    fn pair(&self, params: &Value) -> Result<Value> {
        fields(params, &["code", "name", "bundleId"])?;
        let code = text(params, "code", 6)?;
        if code.len() != 6 || !code.bytes().all(|b| b.is_ascii_digit()) {
            return Err("phone_pair_invalid");
        }
        let name = text(params, "name", 128)?;
        if text(params, "bundleId", 256)? != "XTL-DK896KQSMB.net.anotherdave.magpie" {
            return Err("phone_pair_invalid");
        }
        let mut window = self
            .pairing
            .lock()
            .map_err(|_| "phone_service_unavailable")?;
        let pair = window.as_mut().ok_or("phone_pair_expired")?;
        if pair.expires <= Instant::now() || pair.attempts >= 10 {
            *window = None;
            return Err("phone_pair_expired");
        }
        pair.attempts += 1;
        if storage::hash(code.as_bytes()) != pair.digest {
            return Err("phone_pair_invalid");
        }
        let token = storage::random()?;
        let id = storage::hash(token.as_bytes());
        let mut devices = storage::read("devices.json")?;
        if devices.as_object().ok_or("phone_storage_invalid")?.len() >= 8 {
            return Err("phone_device_limit");
        }
        devices[&id] = json!({"name":name,"created":crate::inbox::now(),"accounts":pair.accounts,"notifications":false});
        storage::write("devices.json", &devices)?;
        *window = None;
        Ok(json!({"token":token,"id":id}))
    }
    pub async fn request(
        &self,
        engine: &Arc<Engine>,
        path: &str,
        token: &str,
        p: &Value,
    ) -> Result<Value> {
        let _guard = self.gate.lock().await;
        if path == "/v1/pair" {
            return self.pair(p);
        }
        let (device_id, device) = self.paired(token)?;
        let current = crate::account::list_readonly()?;
        let accounts: Vec<_> = device["accounts"]
            .as_array()
            .ok_or("phone_storage_invalid")?
            .iter()
            .filter(|v| {
                current["accounts"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .any(|live| live["id"] == v["id"])
            })
            .cloned()
            .collect();
        if let Some(account) = p.get("accountId") {
            if !accounts.iter().any(|v| &v["id"] == account) {
                return Err("phone_account_refused");
            }
            let current = crate::account::list_readonly()?;
            if !current["accounts"]
                .as_array()
                .into_iter()
                .flatten()
                .any(|v| &v["id"] == account)
            {
                return Err("phone_account_refused");
            }
        }
        match path {
            "/v1/notifications" => history::request(p, &accounts),
            "/v1/status" => {
                fields(p, &[])?;
                Ok(
                    json!({"connected":true,"accounts":accounts,"notifications":device["notifications"],"notificationError":device["pushError"],"apiVersion":1}),
                )
            }
            "/v1/disconnect" => {
                fields(p, &[])?;
                let mut devices = storage::read("devices.json")?;
                devices
                    .as_object_mut()
                    .ok_or("phone_storage_invalid")?
                    .remove(&device_id);
                storage::write("devices.json", &devices)?;
                Ok(json!({"disconnected":true}))
            }
            "/v1/devices" => {
                fields(
                    p,
                    &["pushToken", "notifications", "environment", "accountIds"],
                )?;
                let environment = p["environment"].as_str().unwrap_or("development");
                if !["development", "production"].contains(&environment) {
                    return Err("phone_invalid_request");
                }
                let notifications = p["notifications"]
                    .as_bool()
                    .ok_or("phone_invalid_request")?;
                let push = p
                    .get("pushToken")
                    .map(|_| text(p, "pushToken", 512))
                    .transpose()?
                    .unwrap_or("");
                if !push.is_empty()
                    && (!push.len().is_multiple_of(2)
                        || push.len() < 32
                        || !push.bytes().all(|b| b.is_ascii_hexdigit()))
                {
                    return Err("phone_invalid_request");
                }
                let mut devices = storage::read("devices.json")?;
                if notifications
                    && (devices[&device_id]["notifications"] != true
                        || (!push.is_empty() && devices[&device_id]["pushToken"] != push))
                {
                    devices[&device_id]["pushGeneration"] = json!(storage::random()?);
                }
                if let Some(ids) = p.get("accountIds") {
                    let ids = ids
                        .as_array()
                        .filter(|ids| ids.len() <= 32)
                        .ok_or("phone_invalid_request")?;
                    if ids.iter().any(|id| {
                        id.as_str()
                            .is_none_or(|s| s.len() > 1024 || s.chars().any(char::is_control))
                    }) {
                        return Err("phone_invalid_request");
                    }
                    devices[&device_id]["notificationAccounts"] = json!(
                        ids.iter()
                            .filter(|id| accounts.iter().any(|a| a["id"] == **id))
                            .collect::<Vec<_>>()
                    );
                }
                devices[&device_id]["pushEnvironment"] = json!(environment);
                if notifications && devices[&device_id]["pushError"] == "push_delivery_refused" {
                    let name = format!("push-{}.json", storage::hash(device_id.as_bytes()));
                    let mut journal = storage::read_bounded(&name, 16 * 1024 * 1024)?;
                    if journal["pending"].is_object() {
                        journal["pending"]["blocked"] = json!(false);
                        journal["pending"]["retryAt"] = json!(0);
                        storage::write_bounded(&name, &journal, 16 * 1024 * 1024)?;
                    }
                }
                devices[&device_id]["notifications"] = json!(notifications);
                if !push.is_empty() {
                    devices[&device_id]["pushToken"] = json!(push);
                }
                storage::write("devices.json", &devices)?;
                Ok(json!({"notifications":notifications}))
            }
            "/v1/snoozes" => {
                fields(p, &["accountId"])?;
                let account = text(p, "accountId", 1024)?;
                engine.inbox.phone_snapshot(account).await
            }
            "/v1/snooze" | "/v1/wake" => {
                engine
                    .inbox
                    .phone_mutate(path, p, &device_id, &engine.gmail)
                    .await
            }
            "/v1/ai/options" => {
                fields(p, &[])?;
                engine.dispatch("agent.providerStatus", &json!({})).await
            }
            "/v1/overview-settings" => {
                fields(p, &["accountId", "paused", "allowRemoteImages"])?;
                text(p, "accountId", 1024)?;
                engine.dispatch("inbox.preferences", p).await
            }
            "/v1/overviews" => {
                fields(
                    p,
                    &["accountId", "ids", "request", "retry", "allowRemoteImages"],
                )?;
                let account = text(p, "accountId", 1024)?;
                let ids = p["ids"]
                    .as_array()
                    .filter(|ids| ids.len() <= 100)
                    .ok_or("phone_invalid_request")?;
                for id in ids {
                    crate::mail::action::validate_message_id(
                        crate::mail::Provider::Gmail,
                        id.as_str().ok_or("phone_invalid_request")?,
                    )?;
                }
                for key in ["request", "retry", "allowRemoteImages"] {
                    if p.get(key).is_some_and(|v| !v.is_boolean()) {
                        return Err("phone_invalid_request");
                    }
                }
                let mut accepted = Value::Null;
                if p["request"] == true {
                    if ids.is_empty() || ids.len() > 4 {
                        return Err("phone_invalid_request");
                    }
                    accepted = engine
                        .dispatch(
                            "inbox.overviews",
                            &json!({"accountId":account,"ids":ids,"retry":p["retry"] == true,"allowRemoteImages":p["allowRemoteImages"] == true}),
                        )
                        .await?["accepted"]
                        .clone();
                }
                let snapshot = engine
                    .dispatch("inbox.snapshot", &json!({"accountId":account}))
                    .await?;
                let rows: serde_json::Map<String, Value> = ids
                    .iter()
                    .filter_map(|id| {
                        let key = id.as_str()?;
                        snapshot["overviews"].get(key).map(|value| {
                            (
                                key.to_owned(),
                                project(
                                    value,
                                    &[
                                        "text",
                                        "state",
                                        "updated",
                                        "version",
                                        "expiresAt",
                                        "reason",
                                        "pendingSince",
                                    ],
                                ),
                            )
                        })
                    })
                    .collect();
                Ok(
                    json!({"overviews":rows,"accepted":accepted,"preferences":snapshot["preferences"]}),
                )
            }
            "/v1/ai/start" | "/v1/ai/show" | "/v1/ai/cancel" | "/v1/ai/list" => {
                ai(engine, path, p, &accounts, &device_id).await
            }
            _ => Err("phone_operation_refused"),
        }
    }
}
fn project(value: &Value, keys: &[&str]) -> Value {
    json!(
        keys.iter()
            .filter_map(|key| value.get(key).map(|v| ((*key).to_owned(), v.clone())))
            .collect::<serde_json::Map<_, _>>()
    )
}
fn job_view(job: &Value) -> Value {
    project(
        job,
        &[
            "id",
            "conversationId",
            "requestPreview",
            "kind",
            "messageIds",
            "state",
            "created",
            "updated",
            "resultReady",
            "canContinue",
            "provider",
            "model",
            "progress",
            "accountId",
            "subject",
            "messageId",
            "draftKey",
            "draftFingerprint",
            "events",
        ],
    )
}
fn history_view(value: &Value) -> Value {
    let proposals: Vec<_> = value["proposals"]
        .as_array()
        .into_iter()
        .flatten()
        .map(|p| {
            project(
                p,
                &[
                    "id",
                    "jobId",
                    "accountId",
                    "messageId",
                    "draftKey",
                    "subject",
                    "body",
                    "afterTurn",
                    "draftFingerprint",
                    "applicable",
                ],
            )
        })
        .collect();
    json!({"job":job_view(&value["job"]),"output":value["output"],"transcript":value["transcript"],"proposals":proposals,"previous":value["previous"]})
}
async fn identity(id: &str) -> Result<Value> {
    #[cfg(feature = "agent")]
    {
        crate::agent::jobs::identity(id).await
    }
    #[cfg(not(feature = "agent"))]
    {
        let _ = id;
        Err("agent_unavailable")
    }
}
fn ai_messages(p: &Value) -> Result<Vec<Value>> {
    if p.get("draft").is_some_and(|draft| !draft.is_object()) {
        return Err("phone_invalid_request");
    }
    if p["draft"].is_object() {
        if p.get("messageId").is_some() || p.get("messageIds").is_some() {
            return Err("phone_invalid_request");
        }
        return Ok(Vec::new());
    }
    let ids = if let Some(ids) = p.get("messageIds") {
        if p.get("messageId").is_some() {
            return Err("phone_invalid_request");
        }
        ids.as_array()
            .filter(|ids| !ids.is_empty() && ids.len() <= 20)
            .ok_or("phone_invalid_request")?
            .clone()
    } else {
        vec![json!(text(p, "messageId", 4096)?)]
    };
    let mut unique = std::collections::HashSet::new();
    for id in &ids {
        let id = id.as_str().ok_or("phone_invalid_request")?;
        crate::mail::action::validate_message_id(crate::mail::Provider::Gmail, id)?;
        if !unique.insert(id) {
            return Err("phone_invalid_request");
        }
    }
    if p["events"] == true && ids.len() != 1 {
        return Err("phone_invalid_request");
    }
    Ok(ids)
}

async fn ai(
    engine: &Engine,
    path: &str,
    p: &Value,
    accounts: &[Value],
    device: &str,
) -> Result<Value> {
    if path == "/v1/ai/list" {
        fields(p, &["offset"])?;
        let page = engine
            .dispatch(
                "agent.jobsList",
                &json!({"offset":p.get("offset").cloned().unwrap_or(json!(0)),"paged":true}),
            )
            .await?;
        let jobs: Vec<_> = page["jobs"]
            .as_array()
            .into_iter()
            .flatten()
            .filter(|job| accounts.iter().any(|v| v["id"] == job["accountId"]))
            .map(job_view)
            .collect();
        return Ok(json!({"jobs":jobs,"hasMore":page["hasMore"]}));
    }
    if path != "/v1/ai/start" {
        fields(p, &["id", "before", "requestId", "accountId"])?;
        let derived;
        let id = if p["id"].as_str().is_some_and(|s| !s.is_empty()) {
            text(p, "id", 128)?
        } else {
            let request = text(p, "requestId", 128)?;
            derived = storage::hash(format!("{device}:{request}").as_bytes())[..32].to_owned();
            if path == "/v1/ai/cancel" {
                let mut cancelled = storage::read("ai-cancelled.json")?;
                let entries = cancelled.as_object_mut().ok_or("phone_storage_invalid")?;
                entries.retain(|_, v| {
                    v.as_i64()
                        .is_some_and(|t| t > crate::inbox::now() - 31 * 86_400_000)
                });
                if entries.len() >= 4096 {
                    return Err("phone_request_limit");
                }
                entries.insert(derived.clone(), json!(crate::inbox::now()));
                storage::write("ai-cancelled.json", &cancelled)?;
                match identity(&derived).await {
                    Err("agent_job_missing") => return Ok(json!({"cancelled":true})),
                    Err(error) => return Err(error),
                    Ok(_) => (),
                }
            }
            &derived
        };
        let job = identity(id).await?;
        if !accounts.iter().any(|v| v["id"] == job["accountId"]) {
            return Err("phone_account_refused");
        }
        if path == "/v1/ai/cancel" {
            return engine
                .dispatch("agent.jobCancel", &json!({"id":id}))
                .await
                .map(|job| job_view(&job));
        }
        let result = engine
            .dispatch(
                "agent.jobShow",
                &json!({"id":id,"before":p.get("before").cloned().unwrap_or(json!(""))}),
            )
            .await?;
        return Ok(history_view(&result));
    }
    fields(
        p,
        &[
            "accountId",
            "messageId",
            "messageIds",
            "draft",
            "prompt",
            "parentId",
            "requestId",
            "issuedAt",
            "events",
            "provider",
            "model",
        ],
    )?;
    if p.get("events").is_some_and(|v| !v.is_boolean()) {
        return Err("phone_invalid_request");
    }
    let ids = ai_messages(p)?;
    if p.get("parentId")
        .is_some_and(|value| !value.is_null() && !value.is_string())
    {
        return Err("phone_invalid_request");
    }
    let provider = p
        .get("provider")
        .map(|v| v.as_str().ok_or("phone_invalid_request"))
        .transpose()?
        .unwrap_or("");
    let model = p
        .get("model")
        .map(|v| v.as_str().ok_or("phone_invalid_request"))
        .transpose()?
        .unwrap_or("");
    if !["", "claude", "codex", "opencode"].contains(&provider)
        || model.len() > 200
        || (!model.is_empty()
            && (!model.as_bytes()[0].is_ascii_alphanumeric()
                || !model
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b"-._/:#@+".contains(&b))))
    {
        return Err("phone_invalid_request");
    }
    if !p["parentId"].as_str().unwrap_or("").is_empty()
        && (!provider.is_empty() || !model.is_empty())
    {
        return Err("phone_invalid_request");
    }
    let account = text(p, "accountId", 1024)?;
    let prompt = p["prompt"]
        .as_str()
        .filter(|s| {
            !s.trim().is_empty()
                && s.len() <= 200_000
                && !s
                    .chars()
                    .any(|c| c.is_control() && !matches!(c, '\n' | '\r' | '\t'))
        })
        .ok_or("phone_invalid_request")?;
    let request = text(p, "requestId", 128)?;
    p["issuedAt"]
        .as_i64()
        .filter(|time| {
            *time <= crate::inbox::now() + 60_000 && *time > crate::inbox::now() - 30 * 86_400_000
        })
        .ok_or("phone_request_expired")?;
    let submission_id = storage::hash(format!("{device}:{request}").as_bytes())[..32].to_owned();
    let digest = storage::hash(&serde_json::to_vec(p).map_err(|_| "phone_invalid_request")?);
    if storage::read("ai-cancelled.json")?
        .get(&submission_id)
        .is_some()
    {
        return Err("agent_cancelled");
    }
    match identity(&submission_id).await {
        Ok(existing) => {
            if existing["accountId"] != account || existing["submissionDigest"] != digest {
                return Err("agent_submission_conflict");
            }
            return Ok(job_view(&existing));
        }
        Err("agent_job_missing") => (),
        Err(error) => return Err(error),
    }
    let draft = if p["draft"].is_object() {
        let mut draft = p["draft"].clone();
        let fields = draft.as_object_mut().ok_or("phone_invalid_request")?;
        if fields.keys().any(|k| {
            ![
                "draftKey",
                "from",
                "to",
                "cc",
                "bcc",
                "replyTo",
                "subject",
                "body",
                "signature",
                "signatureHtml",
                "signatureOffset",
                "draftId",
                "threadId",
                "inReplyTo",
                "references",
                "attachments",
            ]
            .contains(&k.as_str())
        }) {
            return Err("phone_invalid_request");
        }
        fields.remove("attachments");
        fields.remove("signature");
        fields.remove("signatureHtml");
        fields.remove("signatureOffset");
        Some(draft)
    } else {
        None
    };
    let payload = if let Some(parent) = p["parentId"].as_str().filter(|s| !s.is_empty()) {
        if p["events"] == true {
            return Err("phone_invalid_request");
        }
        let job = json!({"job":identity(parent).await?});
        if job["job"]["accountId"] != account {
            return Err("phone_account_refused");
        }
        let mut continuation = json!({"parent":parent,"prompt":prompt});
        if let Some(draft) = draft {
            continuation["draftUpdate"] = json!({"accountId":account,"draftKey":draft["draftKey"],"draft":project(&draft,&["from","to","cc","bcc","subject","body"])});
        } else {
            let mut original = job["job"]["messageIds"]
                .as_array()
                .ok_or("phone_invalid_request")?
                .clone();
            let mut selected = ids.clone();
            original.sort_by_key(|id| id.as_str().unwrap_or("").to_owned());
            selected.sort_by_key(|id| id.as_str().unwrap_or("").to_owned());
            if original != selected {
                return Err("phone_account_refused");
            }
            if ids.len() > 1 {
                return engine.dispatch("agent.jobStart", &json!({"payload":continuation,"provider":provider,"model":model,"submission":{"id":submission_id,"digest":digest}})).await.map(|job| job_view(&job));
            }
            let id = &ids[0];
            let context=engine.dispatch("agent.context",&json!({"accountId":account,"requestId":request,"ids":[id],"summaries":[{"id":id}],"folder":"","prompt":prompt})).await?;
            continuation["mailUpdate"] = project(
                &context["payload"],
                &[
                    "accountId",
                    "messageId",
                    "message",
                    "threadContext",
                    "threadMessages",
                ],
            );
        }
        continuation
    } else if let Some(draft) = draft {
        if p["events"] == true {
            return Err("phone_invalid_request");
        }
        json!({"draftFields":draft,"ask":prompt,"account":account,"accountId":account})
    } else {
        let summaries: Vec<_> = ids.iter().map(|id| json!({"id":id})).collect();
        let context=engine.dispatch("agent.context",&json!({"accountId":account,"requestId":request,"ids":ids,"summaries":summaries,"folder":"","prompt":prompt})).await?;
        let mut payload = context["payload"].clone();
        if p["events"] == true {
            payload = project(
                &payload,
                &[
                    "accountId",
                    "messageId",
                    "account",
                    "subject",
                    "message",
                    "folder",
                ],
            );
            payload["events"] = json!(true);
            payload["prompt"] = json!("Find the calendar events in this message.");
        }
        payload
    };
    engine
        .dispatch(
            "agent.jobStart",
            &json!({"payload":payload,"provider":provider,"model":model,"submission":{"id":submission_id,"digest":digest}}),
        )
        .await
        .map(|job| job_view(&job))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn ai_messages_keeps_a_bounded_unambiguous_selection() {
        assert_eq!(
            ai_messages(&json!({"messageId":"ab12"})).unwrap(),
            vec![json!("ab12")]
        );
        assert_eq!(
            ai_messages(&json!({"messageIds":["ab12","cd34"]})).unwrap(),
            vec![json!("ab12"), json!("cd34")]
        );
        assert!(
            ai_messages(&json!({"draft":{"draftKey":"editor"}}))
                .unwrap()
                .is_empty()
        );
        for value in [
            json!({"messageIds":[]}),
            json!({"messageIds":["ab12","ab12"]}),
            json!({"messageIds":["bad\nheader"]}),
            json!({"messageIds":["ab12"],"messageId":"cd34"}),
            json!({"draft":{},"messageIds":["ab12"]}),
            json!({"draft":"invalid","messageId":"ab12"}),
            json!({"events":true,"messageIds":["ab12","cd34"]}),
            json!({"messageIds":(1..=21).map(|id|format!("{id:x}")).collect::<Vec<_>>()}),
        ] {
            assert!(ai_messages(&value).is_err(), "{value}");
        }
    }

    #[tokio::test]
    async fn pairing_is_single_use_and_account_scoped_before_dispatch() {
        if crate::mail::tests::isolated() {
            return;
        }
        let _fixture = crate::mail::tests::account_fixture(
            json!({"version":1,"accounts":[{"email":"one@example.org","label":"First","provider":"gmail"}]}),
        );
        let engine = Arc::new(Engine::default());
        engine
            .phone
            .active
            .store(true, std::sync::atomic::Ordering::Release);
        let code = engine
            .phone
            .desktop("phone.pairBegin", &json!({}))
            .await
            .unwrap()["code"]
            .clone();
        let params = json!({"code":code,"name":"Test iPhone","bundleId":"XTL-DK896KQSMB.net.anotherdave.magpie"});
        let paired = engine
            .phone
            .request(&engine, "/v1/pair", "", &params)
            .await
            .unwrap();
        let token = paired["token"].as_str().unwrap();
        assert_eq!(
            engine.phone.request(&engine, "/v1/pair", "", &params).await,
            Err("phone_pair_expired")
        );
        let disk = storage::read("devices.json").unwrap().to_string();
        assert!(!disk.contains(token));
        assert_eq!(engine.phone.request(&engine,"/v1/ai/start",token,&json!({"accountId":"other@example.org","prompt":"Write","draft":{"body":"secret"}})).await,Err("phone_account_refused"));
        assert_eq!(
            engine
                .phone
                .request(
                    &engine,
                    "/v1/request.upload",
                    token,
                    &json!({"method":"credentials.get"})
                )
                .await,
            Err("phone_operation_refused")
        );
        assert_eq!(
            engine
                .phone
                .request(&engine, "/v1/status", "invalid", &json!({}))
                .await,
            Err("phone_unauthorized")
        );
        let status = engine
            .phone
            .request(&engine, "/v1/status", token, &json!({}))
            .await
            .unwrap();
        assert_eq!(status["accounts"][0]["id"], "one@example.org");
        let pending = json!({"collapse":"synthetic-history","historyAccounts":["one@example.org"],"payload":{"aps":{"alert":{"title":"Magpie","body":"You have a new message."}}}});
        history::retain(&pending).unwrap();
        history::retain(&json!({"collapse":"foreign-history","historyAccounts":["other@example.org"],"payload":{"aps":{"alert":{"title":"Private","body":"Forbidden"}}}})).unwrap();
        let before = storage::read_bounded("notification-history.json", 16 * 1024 * 1024).unwrap();
        assert_eq!(
            engine
                .phone
                .request(
                    &engine,
                    "/v1/notifications",
                    token,
                    &json!({"id":"foreign-history","read":true})
                )
                .await,
            Err("notification_not_found")
        );
        assert_eq!(
            engine
                .phone
                .request(
                    &engine,
                    "/v1/notifications",
                    "invalid",
                    &json!({"id":"synthetic-history","read":true})
                )
                .await,
            Err("phone_unauthorized")
        );
        assert_eq!(
            storage::read_bounded("notification-history.json", 16 * 1024 * 1024).unwrap(),
            before
        );
        let history_list = engine
            .phone
            .request(&engine, "/v1/notifications", token, &json!({}))
            .await
            .unwrap();
        assert_eq!(history_list["notifications"].as_array().unwrap().len(), 1);
        assert!(!history_list.to_string().contains("Forbidden"));
        engine
            .phone
            .request(
                &engine,
                "/v1/notifications",
                token,
                &json!({"id":"synthetic-history","read":true}),
            )
            .await
            .unwrap();
        history::retain(&pending).unwrap();
        assert_eq!(
            storage::read_bounded("notification-history.json", 16 * 1024 * 1024).unwrap()["synthetic-history"]
                ["unread"],
            false
        );
        engine
            .phone
            .request(&engine, "/v1/disconnect", token, &json!({}))
            .await
            .unwrap();
        assert_eq!(
            engine
                .phone
                .request(&engine, "/v1/status", token, &json!({}))
                .await,
            Err("phone_unauthorized")
        );
        assert!(
            storage::read("devices.json")
                .unwrap()
                .as_object()
                .unwrap()
                .is_empty()
        );
    }
    #[tokio::test]
    async fn guessing_never_creates_a_pairing_or_increases_its_budget() {
        if crate::mail::tests::isolated() {
            return;
        }
        let _fixture = crate::mail::tests::account_fixture(
            json!({"version":1,"accounts":[{"email":"one@example.org","provider":"gmail"}]}),
        );
        let engine = Arc::new(Engine::default());
        engine
            .phone
            .active
            .store(true, std::sync::atomic::Ordering::Release);
        let code = engine
            .phone
            .desktop("phone.pairBegin", &json!({}))
            .await
            .unwrap()["code"]
            .clone();
        let wrong = if code == "000000" { "000001" } else { "000000" };
        for _ in 0..10 {
            assert_eq!(engine.phone.pair(&json!({"code":wrong,"name":"Test","bundleId":"XTL-DK896KQSMB.net.anotherdave.magpie"})),Err("phone_pair_invalid"));
        }
        assert_eq!(engine.phone.pair(&json!({"code":code,"name":"Test","bundleId":"XTL-DK896KQSMB.net.anotherdave.magpie"})),Err("phone_pair_expired"));
        assert!(storage::bytes("devices.json", 1024).unwrap().is_none());
    }
}
