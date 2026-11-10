mod content;
mod ipc;
#[cfg(test)]
mod recovery_tests;
#[cfg(test)]
mod provider_tests;
mod search;
mod store;
mod sync;
#[cfg(test)]
mod tests;
mod vfs;

use crate::platform::{dirs::AppDirs, private_fs};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    collections::HashMap,
    sync::{Arc, Mutex},
};
use store::Store;

pub(crate) fn text_complete(resource: &Value) -> bool {
    content::extract(resource).complete
}

#[derive(Default)]
pub struct LocalMail {
    stores: Arc<Mutex<HashMap<String, Arc<Store>>>>,
    jobs: Mutex<HashMap<String, tokio::task::JoinHandle<()>>>,
    events: std::sync::OnceLock<tokio::sync::broadcast::Sender<Value>>,
}
impl LocalMail {
    pub fn subscribe(&self) -> tokio::sync::broadcast::Receiver<Value> {
        self.events
            .get_or_init(|| tokio::sync::broadcast::channel(128).0)
            .subscribe()
    }
    pub async fn start(
        &self,
        account: &str,
        gmail: Arc<crate::providers::gmail::Session>,
    ) -> Result<(), &'static str> {
        let store = self.store(account).await?;
        let mut jobs = self.jobs.lock().map_err(|_| "local_storage_unavailable")?;
        if jobs.get(account).is_some_and(|job| !job.is_finished()) {
            return Ok(());
        }
        let account = account.to_owned();
        let worker_account = account.clone();
        let events = self
            .events
            .get_or_init(|| tokio::sync::broadcast::channel(128).0)
            .clone();
        jobs.insert(account,tokio::spawn(async move {
            let mut tick = 0u64;
            let mut reported = std::time::Instant::now()-std::time::Duration::from_secs(2);
            let mut changed = false;
            loop {
                let answer = sync::step(&store,&gmail,&worker_account,tick).await;
                changed |= answer==Ok(true);
                if reported.elapsed() >= std::time::Duration::from_secs(1) || answer.is_err() {
                let error = answer.as_ref().err().copied().unwrap_or("");
                let _ = sync::disk(&store,move|s|s.write(|db| {
                    store::set_state(db,"error",error)?;
                    if error.is_empty() && changed { store::set_state(db,"updated",&chrono::Utc::now().timestamp_millis().to_string())?; }
                    Ok(())
                })).await;
                if let Ok(status) = sync::disk(&store,|s|s.status()).await {
                    let _ = events.send(json!({"jsonrpc":"2.0","method":"local.changed","params":{"accountId":worker_account,"status":status,"changed":changed}}));
                }
                reported = std::time::Instant::now();
                changed = false;
                }
                tick += 1;
                tokio::time::sleep(std::time::Duration::from_millis(if answer.is_err() {30_000} else if answer==Ok(false) {5_000} else {25})).await;
            }
        }));
        Ok(())
    }
    pub async fn refresh(&self, account: &str) -> Result<(), &'static str> {
        let store = self.store(account).await?;
        sync::disk(&store, |s| {
            s.write(|db| store::set_state(db, "lastHistory", "0"))
        })
        .await
    }
    pub fn stop(&self, account: &str) {
        if let Ok(mut jobs) = self.jobs.lock() {
            if let Some(job) = jobs.remove(account) {
                job.abort();
            }
        }
    }
    pub async fn shutdown(&self) {
        let jobs: Vec<_> = self
            .jobs
            .lock()
            .map(|mut jobs| jobs.drain().map(|(_, job)| job).collect())
            .unwrap_or_default();
        for job in jobs {
            job.abort();
            let _ = job.await;
        }
    }
    async fn store(&self, account: &str) -> Result<Arc<Store>, &'static str> {
        self.open_store(account, true).await?.ok_or("local_storage_unavailable")
    }
    async fn open_store(&self, account: &str, create: bool) -> Result<Option<Arc<Store>>, &'static str> {
        let account = account.to_owned();
        let stores = self.stores.clone();
        let identity = account.clone();
        let store = tokio::task::spawn_blocking(move || {
            let accounts = crate::account::list_readonly()?;
            if !accounts["accounts"]
                .as_array()
                .into_iter()
                .flatten()
                .any(|entry| entry["id"] == account && entry["provider"] == "gmail")
            {
                return Err("local_account_unknown");
            }
            let mut stores = stores.lock().map_err(|_| "local_storage_unavailable")?;
            if let Some(store) = stores.get(&account) {
                return Ok(Some(store.clone()));
            }
            let dirs = AppDirs::discover()?;
            let hash = format!("{:x}", Sha256::digest(account.as_bytes()));
            let directory = if create {
                private_fs::directories(&dirs.state, &["omamail", "mail", &hash], true)?
            } else {
                private_fs::directories_readonly(&dirs.state, &["omamail", "mail", &hash])?
            };
            let Some(directory) = directory else { return Ok(None) };
            let store = Store::open(directory)?;
            stores.insert(account, store.clone());
            Ok(Some(store))
        })
        .await
        .map_err(|_| "local_storage_unavailable")??;
        if let Some(store) = &store { ipc::listen(store, &identity)?; }
        Ok(store)
    }
    pub(crate) async fn resource(
        &self,
        account: &str,
        id: &str,
    ) -> Result<Option<Value>, &'static str> {
        let store = match self.open_store(account, false).await {
            Err("private_fs_busy") => {
                return ipc::request(
                    account,
                    "local.resource",
                    &json!({"accountId":account,"id":id}),
                )
                .await
                .map(|v| if v.is_null() { None } else { Some(v) });
            }
            Ok(None) => return Ok(None),
            answer => answer?.ok_or("local_storage_unavailable")?,
        };
        let id = id.to_owned();
        tokio::task::spawn_blocking(move || store.complete_resource(&id))
            .await
            .map_err(|_| "local_storage_unavailable")?
    }
    pub(crate) async fn revision(
        &self,
        account: &str,
        id: &str,
    ) -> Result<Option<String>, &'static str> {
        let store = match self.open_store(account, false).await {
            Err("private_fs_busy") => {
                return ipc::request(
                    account,
                    "local.revision",
                    &json!({"accountId":account,"id":id}),
                )
                .await
                .map(|v| v.as_str().map(str::to_owned));
            }
            Ok(None) => return Ok(None),
            answer => answer?.ok_or("local_storage_unavailable")?,
        };
        let id = id.to_owned();
        sync::disk(&store, move |s| s.revision(&id)).await
    }
    pub(crate) async fn read(
        &self,
        account: &str,
        id: &str,
        gmail: &crate::providers::gmail::Session,
    ) -> Result<Value, &'static str> {
        let store = match self.open_store(account, false).await {
            Err("private_fs_busy") => {
                if let Some(value) = self.resource(account, id).await? {
                    return Ok(value);
                }
                return gmail
                    .call(
                        "gmail.read",
                        &json!({"accountId":account,"id":id,"full":true}),
                    )
                    .await;
            }
            Ok(None) => {
                let mut resource = match crate::cache::resource::read(account, id).await? {
                    Some(resource) => resource,
                    None => gmail.call("gmail.read", &json!({"accountId":account,"id":id,"full":true})).await?,
                };
                sync::hydrate_text(gmail, account, id, &mut resource, true).await?;
                let store = self.store(account).await?;
                return Self::save_read(&store, resource).await;
            }
            answer => answer?.ok_or("local_storage_unavailable")?,
        };
        let gate = store.fetch_gate(id)?;
        let _guard = gate.lock().await;
        let message = id.to_owned();
        if let Some(resource) = sync::disk(&store, move |s| s.complete_resource(&message)).await? {
            return Ok(resource);
        }
        let message = id.to_owned();
        let partial = sync::disk(&store, move |s| s.resource(&message)).await?;
        let cached = match partial {
            Some(resource) => Some(resource),
            None => crate::cache::resource::read(account, id)
                .await
                .ok()
                .flatten(),
        };
        let mut resource = match cached {
            Some(resource) => resource,
            None => {
                gmail
                    .call(
                        "gmail.read",
                        &json!({"accountId":account,"id":id,"full":true}),
                    )
                    .await?
            }
        };
        sync::hydrate_text(gmail, account, id, &mut resource, true).await?;
        Self::save_read(&store, resource).await
    }
    async fn save_read(store: &Arc<Store>, resource: Value) -> Result<Value, &'static str> {
        let saved = resource.clone();
        let saved = sync::disk(store, move |s| {
            let generation =
                s.read(|db| Ok(store::state(db, "generation")?.parse().unwrap_or(1)))?;
            s.put(&saved, generation)
        })
        .await;
        match saved {
            Ok(()) | Err("local_disk_low" | "local_disk_full") => (),
            Err(error) => return Err(error),
        }
        Ok(resource)
    }
    pub async fn call(&self, method: &str, params: &Value) -> Result<Value, &'static str> {
        let account = params["accountId"]
            .as_str()
            .filter(|s| !s.is_empty() && s.len() < 1024 && !s.chars().any(char::is_control))
            .ok_or("invalid_params")?;
        validate(method, params, false)?;
        let store = match self.store(account).await {
            Err("private_fs_busy") => return ipc::request(account, method, params).await,
            answer => answer?,
        };
        let method = method.to_owned();
        let params = params.clone();
        sync::disk(&store, move |s| execute(s, &method, &params)).await
    }
}
impl Drop for LocalMail {
    fn drop(&mut self) {
        if let Ok(jobs) = self.jobs.lock() {
            for job in jobs.values() {
                job.abort();
            }
        }
    }
}
fn field<'a>(params: &'a Value, key: &str) -> Result<&'a str, &'static str> {
    params[key]
        .as_str()
        .filter(|s| !s.is_empty() && s.len() <= 1024 && !s.chars().any(char::is_control))
        .ok_or("invalid_params")
}
fn strings(params: &Value, key: &str, limit: usize) -> Result<Vec<String>, &'static str> {
    let values = params[key]
        .as_array()
        .filter(|v| v.len() <= limit)
        .ok_or("invalid_params")?;
    values
        .iter()
        .map(|v| {
            v.as_str()
                .filter(|s| !s.is_empty() && s.len() <= 1024 && !s.chars().any(char::is_control))
                .map(str::to_owned)
                .ok_or("invalid_params")
        })
        .collect()
}

fn validate(method: &str, params: &Value, internal: bool) -> Result<(), &'static str> {
    let allowed: &[&str] = match method {
        "local.list" => &["accountId", "query", "limit", "pageToken"],
        "local.status" | "local.edits" | "local.overview" => &["accountId"],
        "local.labelCounts" => &["accountId", "id"],
        "local.pause" => &["accountId", "paused"],
        "local.edit" => &[
            "accountId",
            "ticket",
            "ids",
            "addLabelIds",
            "removeLabelIds",
        ],
        "local.cancelEdit" | "local.dismissConflict" => &["accountId", "ticket"],
        "local.resource" | "local.revision" if internal => &["accountId", "id"],
        _ => return Err("unknown_method"),
    };
    if params
        .as_object()
        .is_none_or(|p| p.keys().any(|key| !allowed.contains(&key.as_str())))
    {
        return Err("invalid_params");
    }
    field(params, "accountId")?;
    if method == "local.list" {
        super::local_mail::search::parse(params["query"].as_str().ok_or("invalid_params")?)?;
    }
    if method == "local.pause" && !params["paused"].is_boolean() {
        return Err("invalid_params");
    }
    if method == "local.edit" {
        field(params, "ticket")?;
        let ids = strings(params, "ids", 1000)?;
        let add = strings(params, "addLabelIds", 100)?;
        let remove = strings(params, "removeLabelIds", 100)?;
        if ids.is_empty()
            || ids.iter().collect::<std::collections::HashSet<_>>().len() != ids.len()
            || add.iter().any(|v| remove.contains(v))
            || add.iter().chain(&remove).any(|v| {
                !matches!(
                    v.as_str(),
                    "UNREAD" | "STARRED" | "INBOX" | "TRASH" | "SPAM" | "IMPORTANT"
                ) && !v.starts_with("Label_")
            })
        {
            return Err("invalid_params");
        }
    }
    Ok(())
}

fn execute(store: &Store, method: &str, params: &Value) -> Result<Value, &'static str> {
    validate(method, params, true)?;
    match method {
        "local.overview" => store.overview(),
        "local.labelCounts" => store.label_counts(field(params, "id")?),
        "local.dismissConflict" => {
            store.dismiss_conflict(field(params, "ticket")?)?;
            Ok(json!({"dismissed":true}))
        }
        "local.list" => {
            let query = params["query"].as_str().ok_or("invalid_params")?;
            let limit = params
                .get("limit")
                .map_or(Some(50), Value::as_u64)
                .filter(|n| (1..=100000).contains(n))
                .ok_or("invalid_params")? as usize;
            let cursor = params
                .get("pageToken")
                .map_or(Some(""), Value::as_str)
                .ok_or("invalid_params")?;
            store.list(query, limit, cursor)
        }
        "local.resource" => Ok(store
            .complete_resource(field(params, "id")?)?
            .unwrap_or(Value::Null)),
        "local.revision" => Ok(json!(store.revision(field(params, "id")?)?)),
        "local.status" => store.status(),
        "local.edits" => store.edits(),
        "local.pause" => {
            let paused = params["paused"].as_bool().ok_or("invalid_params")?;
            store.write(|db| {
                store::set_state(db, "paused", if paused { "true" } else { "false" })
            })?;
            store.status()
        }
        "local.edit" => {
            let ticket = field(&params, "ticket")?;
            let ids = strings(&params, "ids", 1000)?;
            let add = strings(&params, "addLabelIds", 100)?;
            let remove = strings(&params, "removeLabelIds", 100)?;
            if ids.is_empty() || add.iter().any(|label| remove.contains(label)) {
                return Err("invalid_params");
            }
            store.edit(ticket, &ids, &add, &remove)
        }
        "local.cancelEdit" => {
            store.cancel_edit(field(&params, "ticket")?)?;
            Ok(json!({"cancelled":true}))
        }
        _ => Err("unknown_method"),
    }
}
