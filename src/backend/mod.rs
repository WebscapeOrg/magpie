mod attachments;
mod content;
pub(crate) mod diagnostics;
pub(crate) mod mail;
mod methods;
pub mod protocol;
mod reader;
mod rpc;
pub mod stdio;
pub mod upload;
use crate::{account, message};

pub struct Session {
    calendar_reads: crate::calendar::reads::Reads,
    local_mail: crate::local_mail::LocalMail,
    reader_prefetch: tokio::sync::Semaphore,
    inbox: crate::inbox::Inbox,
    uploads: std::sync::Mutex<upload::Uploads>,
    reader: std::sync::Arc<std::sync::Mutex<reader::ReaderStore>>,
    #[cfg(all(feature = "agent", unix))]
    agent_context: crate::agent::context::Contexts,
    upload_jobs: tokio::sync::Semaphore,
    pub(crate) gmail: std::sync::Arc<crate::providers::gmail::Session>,
    mail: crate::sync::Sync,
    auth: crate::auth::Session,
    jmap: std::sync::Arc<crate::providers::jmap::Session>,
    outbox: crate::outbox::Outbox,
    queries: std::sync::Arc<crate::cache::query::QueryCache>,
    renders: std::sync::Arc<std::sync::Mutex<crate::cache::render::RenderCache>>,
    intents: std::sync::Arc<crate::account::intents::IntentStore>,
}

impl Default for Session {
    fn default() -> Self {
        let gmail = std::sync::Arc::new(crate::providers::gmail::Session::default());
        let jmap = std::sync::Arc::new(crate::providers::jmap::Session::default());
        let sender_gmail = gmail.clone();
        let sender_jmap = jmap.clone();
        let outbox = crate::outbox::Outbox::new(std::sync::Arc::new(move |job| {
            let gmail = sender_gmail.clone();
            let jmap = sender_jmap.clone();
            Box::pin(async move { crate::outbox::delivery::send(&job, &gmail, &jmap).await })
        }));
        let check_gmail = gmail.clone();
        let check_jmap = jmap.clone();
        let outbox=outbox.with_readiness(std::sync::Arc::new(move|account,provider| {
            let gmail=check_gmail.clone();
            let jmap=check_jmap.clone();
            Box::pin(async move {
                let params=serde_json::json!({"accountId":account});
                match provider.as_str() {
                    "gmail"=>{gmail.call("gmail.profile",&params).await?;}
                    "jmap"=>{jmap.call("jmap.profile",&params).await?;}
                    "imap"|"outlook"=>{crate::providers::imap::call("imap.check",&params).await?;}
                    "hey"=>{
                        let checked=crate::providers::hey_access::checked_params(&serde_json::json!({"accountId":account,"program":crate::providers::hey_access::program()?})).await?;
                        crate::providers::hey::call("hey.profile",&checked).await?;
                    }
                    _=>return Err("outbox_invalid_provider"),
                }
                Ok(())
            })
        }));
        let queries = std::sync::Arc::new(crate::cache::query::QueryCache::default());
        Self {
            calendar_reads: crate::calendar::reads::Reads::default(),
            local_mail: Default::default(),
            reader_prefetch: tokio::sync::Semaphore::new(1),
            inbox: Default::default(),
            uploads: Default::default(),
            reader: Default::default(),
            #[cfg(all(feature = "agent", unix))]
            agent_context: Default::default(),
            upload_jobs: tokio::sync::Semaphore::new(2),
            mail: crate::sync::Sync::new(gmail.clone(), jmap.clone(), queries.clone()),
            gmail,
            auth: Default::default(),
            jmap,
            outbox,
            queries,
            renders: Default::default(),
            intents: Default::default(),
        }
    }
}

impl Session {
    // Performance: Heap-box provider futures because uploaded requests re-enter dispatch; embedding
    // them overflowed the worker stack in the large-request integration test.
    pub async fn dispatch(&self, method: &str, params: &Value) -> Result<Value, &'static str> {
        if matches!(method, "local.watch" | "local.unwatch" | "local.refresh") {
            if params.as_object().is_none_or(|p| p.len() != 1) {
                return Err("invalid_params");
            }
            let account = params["accountId"].as_str().ok_or("invalid_params")?;
            if reader::registered(account).await? != "gmail" {
                return Err("local_account_unknown");
            }
            if method == "local.unwatch" {
                self.local_mail.stop(account);
                return Ok(json!({"unwatched":true}));
            }
            self.local_mail.start(account, self.gmail.clone()).await?;
            if method == "local.refresh" {
                self.local_mail.refresh(account).await?;
            }
            return self.local_mail.call("local.overview", params).await;
        }
        if method.starts_with("local.") {
            return self.local_mail.call(method, params).await;
        }
        #[cfg(not(all(feature = "agent", unix)))]
        if method.starts_with("agent.") {
            return Err("unknown_method");
        }
        if method.starts_with("inbox.") {
            return self.inbox.call(method, params, self.gmail.clone()).await;
        }
        if matches!(method, "mail.list" | "mail.read" | "mail.act" | "mail.send") {
            return Box::pin(self.mail_call(method, params)).await;
        }
        if matches!(method, "system.info" | "system.quit" | "providers.list") {
            return dispatch(method, params);
        }
        if method.starts_with("credentials.") {
            return crate::credentials::rpc::call(method, params).await;
        }
        if matches!(
            method,
            "reader.open" | "reader.render" | "reader.cancel" | "reader.prefetch"
        ) {
            return Box::pin(self.reader_call(method, params)).await;
        }
        #[cfg(all(feature = "agent", unix))]
        if matches!(method, "agent.context" | "agent.contextCancel") {
            return Box::pin(self.agent_context.call(method, params, self)).await;
        }
        if matches!(method, "account.identities" | "account.conversation") {
            let method = method.to_owned();
            let params = params.clone();
            return tokio::task::spawn_blocking(move || {
                if method == "account.identities" {
                    crate::account::senders::request(&params)
                } else {
                    crate::account::conversation::request(&params)
                }
            })
            .await
            .map_err(|_| "worker_failed")?;
        }
        if matches!(method, "providers.resolve" | "providers.snapshot") {
            if method == "providers.resolve" {
                return crate::providers::domain::resolve(params);
            }
            if params != &json!({}) {
                return Err("invalid_params");
            }
            return Ok(crate::providers::domain::snapshot());
        }
        #[cfg(all(feature = "agent", unix))]
        if matches!(
            method,
            "agent.jobsList"
                | "agent.providerStatus"
                | "agent.jobsProjection"
                | "agent.jobStart"
                | "agent.jobShow"
                | "agent.jobCancel"
                | "agent.jobForget"
        ) {
            return Box::pin(crate::agent::jobs::call(method, params)).await;
        }
        if method == "draft.compose" {
            if params.as_object().is_none_or(|p| {
                p.keys()
                    .any(|key| !["accountId", "fields"].contains(&key.as_str()))
            }) {
                return Err("invalid_params");
            }
            let account = params["accountId"]
                .as_str()
                .ok_or("invalid_params")?
                .to_owned();
            let provider = reader::registered(&account).await?;
            let mut fields = params["fields"].clone();
            if !fields.is_object() {
                return Err("invalid_params");
            }
            let draft = fields["draftId"].as_str().unwrap_or("").to_owned();
            let owner = account.clone();
            let mut payload = tokio::task::spawn_blocking(move || {
                crate::attachment::vault::hydrate(&owner, &mut fields)?;
                crate::message::compose::build(&fields)
            })
            .await
            .map_err(|_| "worker_failed")??;
            payload["accountId"] = json!(account);
            return match provider.as_str() {
                "gmail" => {
                    let mut gmail = json!({"accountId":account,"raw":payload["raw"]});
                    if let Some(thread) = payload.get("threadId") {
                        gmail["threadId"] = thread.clone();
                    }
                    if !draft.is_empty() {
                        gmail["id"] = json!(draft);
                    }
                    self.gmail
                        .call_settled(
                            if draft.is_empty() {
                                "gmail.saveDraft"
                            } else {
                                "gmail.updateDraft"
                            },
                            &gmail,
                        )
                        .await
                }
                "jmap" => {
                    payload["draftId"] = json!(draft);
                    self.jmap.call("jmap.saveDraft", &payload).await
                }
                "imap" | "outlook" => {
                    crate::providers::imap::call(
                        "imap.saveDraft",
                        &json!({"accountId":account,"raw":payload["raw"],"draftId":draft}),
                    )
                    .await
                }
                _ => Err("attachment_provider_unsupported"),
            };
        }
        if method == "outbox.compose" {
            let allowed = [
                "accountId",
                "provider",
                "fields",
                "sendId",
                "order",
                "delaySeconds",
                "resumeUnsent",
            ];
            if params
                .as_object()
                .is_none_or(|p| p.keys().any(|key| !allowed.contains(&key.as_str())))
                || !params["fields"].is_object()
            {
                return Err("invalid_params");
            }
            let account = params["accountId"]
                .as_str()
                .ok_or("invalid_params")?
                .to_owned();
            let provider = params["provider"]
                .as_str()
                .ok_or("invalid_params")?
                .to_owned();
            let accounts = tokio::task::spawn_blocking(crate::account::list_readonly)
                .await
                .map_err(|_| "worker_failed")??;
            if !accounts["accounts"]
                .as_array()
                .into_iter()
                .flatten()
                .any(|row| row["id"] == account && row["provider"] == provider)
            {
                return Err("outbox_account_unavailable");
            }
            let mut fields = params["fields"].clone();
            let draft = fields["draftId"].as_str().unwrap_or("").to_owned();
            let stamp = params["order"].as_u64().ok_or("invalid_params")?;
            let seed = params["sendId"]
                .as_str()
                .filter(|v| !v.is_empty() && v.len() <= 1024 && !v.chars().any(char::is_control))
                .ok_or("invalid_params")?
                .to_owned();
            let owner = account.clone();
            let mut payload = tokio::task::spawn_blocking(move || {
                crate::attachment::vault::hydrate(&owner, &mut fields)?;
                crate::message::compose::submission(&fields, stamp, &seed)
            })
            .await
            .map_err(|_| "worker_failed")??;
            payload["draftId"] = json!(draft);
            payload["sendId"] = params["sendId"].clone();
            let mut queued = params.clone();
            queued
                .as_object_mut()
                .ok_or("invalid_params")?
                .remove("fields");
            queued["payload"] = payload;
            return Box::pin(self.outbox.call("outbox.enqueue", &queued)).await;
        }
        if method.starts_with("outbox.") {
            return Box::pin(self.outbox.call(method, params)).await;
        }
        if method == "model.intent" {
            let intents = self.intents.clone();
            let params = params.clone();
            return tokio::task::spawn_blocking(move || intents.call(&params))
                .await
                .map_err(|_| "worker_failed")?;
        }
        if method.starts_with("message.") && method != "message.parseUpload" {
            let method = method.to_owned();
            let params = params.clone();
            let renders = self.renders.clone();
            return tokio::task::spawn_blocking(move || content::call(&method, &params, &renders))
                .await
                .map_err(|_| "worker_failed")?;
        }
        if method.starts_with("cache.query") {
            let value = Box::pin(self.queries.call(method, params)).await?;
            if matches!(method, "cache.queryClear" | "cache.queryBind") {
                self.renders
                    .lock()
                    .map_err(|_| "session_failed")?
                    .invalidate(params["accountId"].as_str().unwrap_or(""), None);
            }
            return Ok(value);
        }
        if method == "attachment.forget" {
            let params = params.clone();
            return tokio::task::spawn_blocking(move || crate::attachment::forget(&params))
                .await
                .map_err(|_| "worker_failed")?;
        }
        if matches!(method, "accounts.read" | "accounts.save") {
            let method = method.to_owned();
            let params = params.clone();
            return tokio::task::spawn_blocking(move || account::call(&method, &params))
                .await
                .map_err(|_| "worker_failed")?;
        }
        if matches!(method, "compose.recoveryRead" | "compose.recoverySave") {
            let method = method.to_owned();
            let params = params.clone();
            return tokio::task::spawn_blocking(move || crate::compose::call(&method, &params))
                .await
                .map_err(|_| "worker_failed")?;
        }
        if matches!(method, "model.unified" | "model.apply") {
            let method = method.to_owned();
            let params = params.clone();
            return tokio::task::spawn_blocking(move || {
                if method == "model.unified" {
                    crate::account::unified::apply(&params)
                } else {
                    crate::account::model::apply(&params)
                }
            })
            .await
            .map_err(|_| "worker_failed")?;
        }
        if method.starts_with("hey.") {
            let checked = crate::providers::hey_access::checked_params(params).await?;
            return if matches!(method, "hey.act" | "hey.send" | "hey.saveDraft") {
                Box::pin(crate::providers::hey_actions::call(method, &checked)).await
            } else {
                Box::pin(crate::providers::hey::call(method, &checked)).await
            };
        }
        if method == "auth.token" && params["provider"] == "gmail" {
            let fields = params.as_object().ok_or("invalid_params")?;
            if fields
                .keys()
                .any(|key| !["provider", "accountId", "resource"].contains(&key.as_str()))
                || fields.get("resource").is_some_and(|value| value != "mail")
            {
                return Err("invalid_params");
            }
            let account = params["accountId"]
                .as_str()
                .filter(|id| !id.is_empty())
                .ok_or("invalid_params")?;
            let token = self.gmail.access_token(account).await?;
            // Invariant: A saved grant marker is not evidence of the scopes on a refreshed token.
            // Scope is optional on restore; initial sign-in validates the actual response.
            return Ok(json!({"access_token":token,"expires_in":60}));
        }
        if method.starts_with("auth.") {
            let value = Box::pin(self.auth.call(method, params)).await?;
            if method == "auth.poll" {
                if let Some(account) = value["profile"]["emailAddress"].as_str() {
                    self.gmail
                        .call("gmail.invalidate", &json!({"accountId":account}))
                        .await?;
                }
            }
            return Ok(value);
        }
        if method.starts_with("jmap.") {
            return Box::pin(self.jmap.call(method, params)).await;
        }
        if method.starts_with("imap.") || method == "smtp.send" {
            return Box::pin(crate::providers::imap::call(method, params)).await;
        }
        if method == "outlook.graphSend" {
            return Box::pin(self.auth.call(method, params)).await;
        }
        if method == "outlook.connectionCheck" {
            return Box::pin(crate::providers::outlook::connection_check(params)).await;
        }
        if matches!(
            method,
            "attachment.import"
                | "attachment.preview"
                | "attachment.download"
                | "attachment.retain"
        ) {
            return self.attachment_request(method, params).await;
        }
        if method == "attachment.thumbnail" {
            return crate::attachment::thumbnail::prepare(params).await;
        }
        if method == "attachment.read" {
            let params = params.clone();
            return tokio::task::spawn_blocking(move || crate::attachment::read(&params))
                .await
                .map_err(|_| "worker_failed")?;
        }
        if method == "attachment.store" {
            let params = params.clone();
            return tokio::task::spawn_blocking(move || {
                let bytes =
                    crate::attachment::decode(params["data"].as_str().ok_or("invalid_params")?)?;
                crate::attachment::store(&params, &bytes)
            })
            .await
            .map_err(|_| "worker_failed")?;
        }
        if method == "attachment.storeUpload" {
            let mut fields = params.as_object().cloned().ok_or("invalid_params")?;
            if fields
                .keys()
                .any(|key| !["upload", "filename", "open"].contains(&key.as_str()))
            {
                return Err("invalid_params");
            }
            let upload = fields.remove("upload").ok_or("invalid_params")?;
            let params = Value::Object(fields);
            let bytes = self
                .uploads
                .lock()
                .map_err(|_| "session_failed")?
                .take(&json!({"upload":upload}))?;
            return tokio::task::spawn_blocking(move || crate::attachment::store(&params, &bytes))
                .await
                .map_err(|_| "worker_failed")?;
        }
        if method == "contacts.suggest" {
            if params != &json!({}) {
                return Err("invalid_params");
            }
            return tokio::task::spawn_blocking(crate::contacts::suggest)
                .await
                .map_err(|_| "worker_failed")?;
        }
        if matches!(method, "public.image" | "public.unsubscribe") {
            let fields = params.as_object().ok_or("invalid_params")?;
            if fields.len() != 1 {
                return Err("invalid_params");
            }
            let url = fields
                .get("url")
                .and_then(Value::as_str)
                .ok_or("invalid_params")?;
            return if method == "public.image" {
                Ok(json!({"data":crate::public_http::image(url).await?}))
            } else {
                Ok(json!({"status":crate::public_http::unsubscribe(url).await?}))
            };
        }
        if method.starts_with("gmail.") {
            return Box::pin(self.gmail.call(method, params)).await;
        }
        if method.starts_with("mail.") {
            let result = Box::pin(self.mail.call(method, params)).await?;
            if let Some(account) = params["accountId"]
                .as_str()
                .filter(|id| id.contains('@') && !id.contains(':'))
            {
                if method == "mail.watch" {
                    let _ = self.local_mail.start(account, self.gmail.clone()).await;
                }
                if method == "mail.unwatch" {
                    self.local_mail.stop(account);
                }
            }
            return Ok(result);
        }
        if method == "request.upload" {
            let fields = params.as_object().ok_or("invalid_params")?;
            if fields.len() != 2 {
                return Err("invalid_params");
            }
            let target = fields
                .get("method")
                .and_then(Value::as_str)
                .ok_or("invalid_params")?;
            if target == "request.upload"
                || target == "system.quit"
                || target.starts_with("upload.")
            {
                return Err("invalid_params");
            }
            let _permit = self
                .upload_jobs
                .acquire()
                .await
                .map_err(|_| "session_failed")?;
            let upload = fields.get("upload").ok_or("invalid_params")?;
            let bytes = self
                .uploads
                .lock()
                .map_err(|_| "session_failed")?
                .take(&json!({"upload":upload}))?;
            let params: Value = serde_json::from_slice(&bytes).map_err(|_| "invalid_params")?;
            return Box::pin(self.dispatch(target, &params)).await;
        }
        if method == "calendar.parse" {
            let params = params.clone();
            return tokio::task::spawn_blocking(move || crate::calendar::parse::parse(&params))
                .await
                .map_err(|_| "worker_failed")?;
        }
        if method == "calendar.read" {
            if params["operation"] != "list" {
                return Err("invalid_params");
            }
            crate::calendar::validate(params)?;
            if matches!(
                params["source"]["kind"].as_str(),
                Some("google" | "microsoft" | "icloud")
            ) {
                reader::registered(
                    params["source"]["accountId"]
                        .as_str()
                        .ok_or("invalid_params")?,
                )
                .await?;
            }
            return self.calendar_reads.get(params,||async {
                let response=Box::pin(self.dispatch("calendar.request",params)).await?;
                let parse=serde_json::json!({"kind":params["source"]["kind"],"sourceId":params["source"]["id"],
                    "body":response["body"],
                    "startMs":chrono::DateTime::parse_from_rfc3339(params["start"].as_str().ok_or("invalid_params")?).map_err(|_|"invalid_params")?.timestamp_millis(),
                    "endMs":chrono::DateTime::parse_from_rfc3339(params["end"].as_str().ok_or("invalid_params")?).map_err(|_|"invalid_params")?.timestamp_millis()});
                tokio::task::spawn_blocking(move||crate::calendar::parse::parse(&parse)).await.map_err(|_|"worker_failed")?
            }).await;
        }
        if method == "calendar.request" {
            crate::calendar::validate(params)?;
            let token = match params["source"]["kind"].as_str() {
                Some("google") => Some(
                    self.gmail
                        .access_token(
                            params["source"]["accountId"]
                                .as_str()
                                .ok_or("invalid_params")?,
                        )
                        .await?,
                ),
                Some("microsoft") => Some(
                    crate::auth::access_token(
                        "outlook",
                        params["source"]["accountId"]
                            .as_str()
                            .ok_or("invalid_params")?,
                        "graph",
                    )
                    .await?,
                ),
                Some("caldav") => None,
                _ => None,
            };
            let answer = Box::pin(crate::calendar::call(params, token.as_deref())).await;
            if !matches!(
                params["operation"].as_str(),
                Some("list" | "get" | "lookup" | "instances")
            ) {
                self.calendar_reads.invalidate();
            }
            return answer;
        }
        if method == "calendar.attendance" {
            crate::calendar::attendance::validate(params)?;
            let token = self
                .gmail
                .access_token(params["accountId"].as_str().ok_or("invalid_params")?)
                .await?;
            let account = params["accountId"].as_str().ok_or("invalid_params")?;
            let mut addresses = vec![account.to_owned()];
            if let Ok(aliases) = self
                .gmail
                .call("gmail.sendAs", &json!({"accountId":account}))
                .await
            {
                for alias in aliases.as_array().into_iter().flatten() {
                    if let Some(email) = alias["email"].as_str().filter(|email| {
                        !email.is_empty()
                            && email.len() <= 1024
                            && !email.chars().any(char::is_control)
                    }) {
                        addresses.push(email.to_owned());
                    }
                }
            }
            return crate::calendar::attendance::google(params, &token, &addresses).await;
        }
        if method == "calendar.reminders" {
            let params = params.clone();
            return tokio::task::spawn_blocking(move || crate::calendar::reminders::call(&params))
                .await
                .map_err(|_| "calendar_reminders_unavailable")?;
        }
        if method == "calendar.discover" {
            if let Some(account) = params["accountId"]
                .as_str()
                .filter(|id| id.contains('@') && !id.contains(':'))
            {
                if params.as_object().is_none_or(|fields| fields.len() != 1)
                    || account.len() > 1024
                    || account.chars().any(|c| c.is_control() || c.is_whitespace())
                {
                    return Err("invalid_params");
                }
                let token = self.gmail.access_token(account).await?;
                return crate::calendar::discover_google(account, &token).await;
            }
            return Box::pin(crate::calendar::discover(params)).await;
        }
        if method == "cache.bodyPutUpload" {
            let mut params = params.as_object().cloned().ok_or("invalid_params")?;
            if params
                .keys()
                .any(|key| !["accountId", "id", "upload"].contains(&key.as_str()))
            {
                return Err("invalid_params");
            }
            let upload = params.remove("upload").ok_or("invalid_params")?;
            let params = Value::Object(params);
            crate::cache::validate_params(&params, true)?;
            let bytes = self
                .uploads
                .lock()
                .map_err(|_| "session_failed")?
                .take(&json!({"upload":upload}))?;
            return tokio::task::spawn_blocking(move || crate::cache::put_upload(&params, &bytes))
                .await
                .map_err(|_| "worker_failed")?;
        }
        if matches!(
            method,
            "cache.resourceRead"
                | "cache.resourcePut"
                | "cache.resourceClear"
                | "cache.bodyRead"
                | "cache.bodyPut"
                | "cache.bodyTouch"
                | "cache.bodyClear"
                | "cache.storeRead"
                | "cache.storePut"
                | "cache.calendarRead"
                | "cache.calendarPut"
        ) {
            let method = method.to_owned();
            let params = params.clone();
            let renders = self.renders.clone();
            return tokio::task::spawn_blocking(move || {
                let value = crate::cache::call(&method, &params)?;
                if matches!(method.as_str(), "cache.bodyClear" | "cache.resourceClear") {
                    renders
                        .lock()
                        .map_err(|_| "session_failed")?
                        .invalidate(params["accountId"].as_str().unwrap_or(""), None);
                }
                Ok(value)
            })
            .await
            .map_err(|_| "worker_failed")?;
        }
        if method.starts_with("upload.") {
            return self
                .uploads
                .lock()
                .map_err(|_| "session_failed")?
                .call(method, params);
        }
        if method == "message.parseUpload" {
            let bytes = self
                .uploads
                .lock()
                .map_err(|_| "session_failed")?
                .take(params)?;
            return tokio::task::spawn_blocking(move || message::parse(&bytes))
                .await
                .map_err(|_| "worker_failed")?;
        }
        let method = method.to_owned();
        let params = params.clone();
        tokio::task::spawn_blocking(move || dispatch(&method, &params))
            .await
            .map_err(|_| "worker_failed")?
    }
}

pub(crate) fn runtime() -> std::io::Result<tokio::runtime::Runtime> {
    tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .max_blocking_threads(8)
        .enable_all()
        .build()
}

use serde_json::{Value, json};
use sha2::{Digest, Sha256};

/// Invariant: Both frontends use this dispatcher. Add domain operations here, never in CLI parsing.
pub fn dispatch(method: &str, params: &Value) -> Result<Value, &'static str> {
    if method == "message.parse" {
        return message::request(params);
    }
    if !params.is_object() || !params.as_object().unwrap().is_empty() {
        return Err("invalid_params");
    }
    match method {
        "system.info" => Ok(json!({
            "name": "omamail", "version": env!("CARGO_PKG_VERSION"),
            "protocol": 1, "apiVersion": 8, "methods": methods::available(),
            "contractHash": format!("{:x}", Sha256::digest(include_bytes!("../../backend-api.json"))),
            "capabilities": {"agent": cfg!(all(feature = "agent", unix))}
        })),
        "system.quit" => Ok(json!({"quitReady": true})),
        "accounts.list" => account::list(),
        "providers.list" => Ok(crate::providers::list()),
        _ => Err("unknown_method"),
    }
}

#[cfg(test)]
mod api_contract_tests {
    use super::*;

    #[test]
    fn advertised_api_matches_versioned_contract() {
        let contract: Value = serde_json::from_str(include_str!("../../backend-api.json")).unwrap();
        let info = dispatch("system.info", &json!({})).unwrap();
        assert_eq!(info["apiVersion"], contract["apiVersion"]);
        assert_eq!(info["protocol"], contract["protocolVersion"]);
        let expected: Vec<_> = contract["methods"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|method| {
                cfg!(all(feature = "agent", unix))
                    || !method.as_str().unwrap().starts_with("agent.")
            })
            .collect();
        assert_eq!(info["methods"], json!(expected));
    }
}

#[cfg(test)]
mod cache_lifecycle_tests {
    use super::*;
    #[tokio::test]
    async fn successful_clear_invalidates_only_its_account_and_refused_clear_preserves_cache() {
        if crate::mail::tests::isolated() {
            return;
        }
        let fixture = crate::mail::tests::account_fixture(json!({"version":1,"accounts":[]}));
        let root = fixture.cache.join("clear-lifecycle");
        let session = Session {
            queries: std::sync::Arc::new(crate::cache::query::QueryCache::at(root.clone())),
            ..Default::default()
        };
        for account in ["one@example.org", "two@example.org"] {
            session
                .renders
                .lock()
                .unwrap()
                .put(account, "id", "html", &json!({}), json!({"html":"safe"}))
                .unwrap();
        }
        let restored = session
            .dispatch(
                "cache.queryRestore",
                &json!({"accountId":"one@example.org"}),
            )
            .await
            .unwrap();
        assert!(
            session
                .dispatch(
                    "cache.queryClear",
                    &json!({"accountId":"one@example.org","generation":0})
                )
                .await
                .is_err()
        );
        assert!(
            session
                .renders
                .lock()
                .unwrap()
                .get("one@example.org", "id", "html", &json!({}))
                .is_some()
        );
        session
            .dispatch(
                "cache.queryClear",
                &json!({"accountId":"one@example.org","generation":restored["generation"]}),
            )
            .await
            .unwrap();
        assert!(
            session
                .renders
                .lock()
                .unwrap()
                .get("one@example.org", "id", "html", &json!({}))
                .is_none()
        );
        assert!(
            session
                .renders
                .lock()
                .unwrap()
                .get("two@example.org", "id", "html", &json!({}))
                .is_some()
        );
        session.queries.shutdown().await.unwrap();
    }
}
