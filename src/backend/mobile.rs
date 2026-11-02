use super::{Engine, reader};
use serde_json::{Value, json};
impl Engine {
    pub async fn mobile_background_drain(&self) -> Result<(), &'static str> {
        self.local_mail.drain(std::time::Duration::from_secs(2)).await
    }
    pub async fn mobile_background_refresh(&self, params: &Value) -> Result<Value, &'static str> {
        if params.as_object().is_none_or(|p| !p.is_empty()) {
            return Err("invalid_params");
        }
        let registry = crate::account::list_readonly()?;
        let accounts: Vec<_> = registry["accounts"]
            .as_array()
            .into_iter()
            .flatten()
            .filter(|account| account["provider"] == "gmail")
            .filter_map(|account| account["id"].as_str().filter(|id| !id.is_empty()))
            .collect();
        let pages = futures_util::future::join_all(accounts.iter().map(|account| async move {
            self.local_mail.background_refresh(account, &self.gmail).await
                .unwrap_or_else(|error| json!({"accountId":account,"changed":false,"checked":false,"error":error,"ids":[]}))
        })).await;
        Ok(json!({"accounts":pages}))
    }
    /// Describes the waiting Inbox mail the app names, while iOS keeps the app awake.
    /// Invariant: the app names only unread Inbox mail with no saved description, at most 20 per account;
    /// the engine describes the first four of them that are due.
    pub async fn mobile_background_describe(&self, params: &Value) -> Result<Value, &'static str> {
        let fields = params.as_object().ok_or("invalid_params")?;
        let rows = params["accounts"].as_array().filter(|rows| fields.len() == 1 && rows.len() <= 32).ok_or("invalid_params")?;
        let mut work: Vec<(String, Vec<String>)> = Vec::new();
        for row in rows {
            if row.as_object().is_none_or(|fields| fields.len() != 2) {
                return Err("invalid_params");
            }
            let account = row["accountId"].as_str().filter(|id| !id.is_empty()).ok_or("invalid_params")?;
            let ids = row["ids"].as_array().filter(|ids| !ids.is_empty() && ids.len() <= 20).ok_or("invalid_params")?;
            let ids = ids
                .iter()
                .map(|id| {
                    let id = id.as_str().ok_or("invalid_params")?;
                    crate::mail::action::validate_message_id(crate::mail::Provider::Gmail, id)?;
                    Ok(id.to_owned())
                })
                .collect::<Result<Vec<_>, &'static str>>()?;
            if work.iter().any(|(seen, _)| seen == account) {
                return Err("invalid_params");
            }
            work.push((account.to_owned(), ids));
        }
        for (account, _) in &work {
            reader::registered(account).await?;
        }
        crate::inbox::claude::ready().await?;
        let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(14);
        let mut pages = Vec::new();
        for (account, ids) in work {
            let left = deadline.saturating_duration_since(tokio::time::Instant::now());
            if left < std::time::Duration::from_secs(3) {
                break;
            }
            let page = self
                .inbox
                .describe_waiting(&account, &ids, self.gmail.clone(), self.local_mail.clone(), left)
                .await
                .unwrap_or_else(|error| json!({"accountId":account,"error":error}));
            pages.push(page);
        }
        Ok(json!({"accounts":pages}))
    }
    /// The same page of descriptions Enterprise served the phone, now written on the phone.
    pub async fn mobile_overviews(&self, params: &Value) -> Result<Value, &'static str> {
        let fields = params.as_object().ok_or("invalid_params")?;
        if !fields.keys().all(|key| ["accountId", "ids", "request", "retry", "allowRemoteImages"].contains(&key.as_str())) {
            return Err("invalid_params");
        }
        let account = params["accountId"].as_str().filter(|id| !id.is_empty()).ok_or("invalid_params")?;
        let ids = params["ids"].as_array().filter(|ids| ids.len() <= 100).ok_or("invalid_params")?;
        for id in ids {
            crate::mail::action::validate_message_id(crate::mail::Provider::Gmail, id.as_str().ok_or("invalid_params")?)?;
        }
        for key in ["request", "retry", "allowRemoteImages"] {
            if params.get(key).is_some_and(|value| !value.is_boolean()) {
                return Err("invalid_params");
            }
        }
        if params["retry"] == true {
            self.inbox.forgive_failed(account)?;
        }
        let mut submitted = json!({"accepted":null});
        if params["request"] == true {
            if ids.is_empty() || ids.len() > 4 {
                return Err("invalid_params");
            }
            submitted = self
                .dispatch("inbox.overviews", &json!({"accountId":account,"ids":ids,"retry":params["retry"] == true,"allowRemoteImages":params["allowRemoteImages"] == true}))
                .await?;
        }
        let ids: Vec<&str> = ids.iter().filter_map(Value::as_str).collect();
        let page = self.inbox.overview_page(account, &ids)?;
        let keys = ["text", "state", "updated", "version", "expiresAt", "reason", "pendingSince", "attempts"];
        let rows: serde_json::Map<String, Value> = page["overviews"]
            .as_object()
            .into_iter()
            .flatten()
            .map(|(id, row)| (id.clone(), json!(keys.iter().filter_map(|key| row.get(*key).map(|value| (key.to_string(), value.clone()))).collect::<serde_json::Map<_, _>>())))
            .collect();
        let mut answer = json!({"overviews":rows,"accepted":submitted["accepted"],"preferences":page["preferences"]});
        if let Some(problem) = submitted["problem"].as_str() {
            answer["problem"] = json!(problem);
        }
        Ok(answer)
    }
    pub async fn mobile_overview_settings(&self, params: &Value) -> Result<Value, &'static str> {
        self.dispatch("inbox.preferences", params).await
    }
    /// The Claude API key: set (checked with Anthropic first), removed or described. Never returned.
    pub async fn mobile_ai_key(&self, method: &str, params: &Value) -> Result<Value, &'static str> {
        let fields = params.as_object().ok_or("invalid_params")?;
        match method {
            "ai.setKey" => {
                if fields.len() != 1 {
                    return Err("invalid_params");
                }
                let key = params["key"].as_str().filter(|key| key.len() <= 4096).ok_or("invalid_params")?;
                crate::inbox::claude::set_key(key).await
            }
            "ai.removeKey" if fields.is_empty() => crate::inbox::claude::remove_key().await,
            "ai.keyStatus" if fields.is_empty() => crate::inbox::claude::key_status().await,
            _ => Err("invalid_params"),
        }
    }
    /// The phone's own assistant: start, show, cancel and list questions about mail and drafts.
    /// Invariant: a question is accepted only for a signed-in account and only while the key could
    /// be used; the turn itself runs in its own task, never inside this call.
    pub async fn mobile_ai(&self, method: &str, params: &Value) -> Result<Value, &'static str> {
        match method {
            "ai.start" => {
                let account = params["accountId"].as_str().ok_or("invalid_params")?;
                reader::registered(account).await?;
                // A retry of a question already accepted gets its job back, whatever the key's state now.
                if let Some(accepted) = self.assistant.accepted(params)? {
                    return Ok(accepted);
                }
                crate::inbox::claude::conversation_ready().await?;
                self.assistant
                    .start(params, |request| async move {
                        self.agent_context.call("agent.context", &request, self).await
                    })
                    .await
            }
            "ai.show" => self.assistant.show(params),
            "ai.list" => self.assistant.list(params),
            "ai.cancel" => {
                let cancelled = self.assistant.cancel(params)?;
                // A question cancelled while its mail is still being read stops that reading too.
                if params["id"].as_str().is_none_or(str::is_empty) {
                    if let (Some(account), Some(request)) =
                        (params["accountId"].as_str(), params["requestId"].as_str())
                    {
                        let _ = self
                            .agent_context
                            .call(
                                "agent.contextCancel",
                                &json!({"accountId":account,"requestId":request}),
                                self,
                            )
                            .await;
                    }
                }
                Ok(cancelled)
            }
            _ => Err("invalid_params"),
        }
    }
    pub async fn mobile_mail_alerts(&self, params: &Value) -> Result<Value, &'static str> {
        if params.as_object().is_none_or(|p| !p.is_empty()) {
            return Err("invalid_params");
        }
        let registry = crate::account::list_readonly()?;
        let accounts: Vec<_> = registry["accounts"]
            .as_array()
            .into_iter()
            .flatten()
            .filter(|account| account["provider"] == "gmail")
            .filter_map(|account| account["id"].as_str().filter(|id| !id.is_empty()))
            .collect();
        let pages = futures_util::future::join_all(accounts.iter().map(|account| async move {
            match self.local_mail.alert_snapshot(account).await {
                Ok(mut page) => {
                    page["accountId"] = json!(account);
                    page
                }
                Err(error) => json!({"accountId":account,"error":error}),
            }
        }))
        .await;
        Ok(json!({"accounts":pages}))
    }
    pub async fn mobile_draft_attachments(
        &self,
        method: &str,
        params: &Value,
    ) -> Result<Value, &'static str> {
        let allowed: &[&str] = if method == "engine.copyAttachments" {
            &["accountId", "sourceDraftKey", "draftKey", "attachments"]
        } else {
            &["accountId", "draftKey"]
        };
        if params.as_object().is_none_or(|fields| {
            fields.len() != allowed.len()
                || fields.keys().any(|key| !allowed.contains(&key.as_str()))
        }) {
            return Err("invalid_params");
        }
        let account = params["accountId"].as_str().ok_or("invalid_params")?;
        reader::registered(account).await?;
        let params = params.clone();
        let copying = method == "engine.copyAttachments";
        tokio::task::spawn_blocking(move || {
            if copying {
                crate::attachment::vault::copy_draft(&params)
            } else {
                crate::attachment::vault::clear_draft(&params)
            }
        })
        .await
        .map_err(|_| "worker_failed")?
    }
    pub async fn mobile_suspend(&self) -> Result<(), &'static str> {
        self.local_mail.quiesce().await?;
        self.queries.shutdown().await?;
        self.outbox.quiesce().await
    }

    pub async fn mobile_authorize(&self, params: &Value) -> Result<(), &'static str> {
        for value in [&params["accountId"], &params["source"]["accountId"]] {
            if !value.is_null() {
                reader::registered(value.as_str().ok_or("invalid_params")?).await?;
            }
        }
        Ok(())
    }

    pub async fn mobile_remove_account(&self, params: &Value) -> Result<Value, &'static str> {
        if params.as_object().is_none_or(|p| p.len() != 1) {
            return Err("invalid_params");
        }
        let account = params["accountId"].as_str().ok_or("invalid_params")?;
        reader::registered(account).await?;
        self.outbox.remove_account(account).await?;
        self.assistant.forget_account(account)?;
        self.local_mail.retire(account).await?;
        self.gmail.call("gmail.invalidate", params).await?;
        self.queries.forget_account(account).await;
        self.reader
            .lock()
            .map_err(|_| "session_failed")?
            .forget_account(account);
        self.renders
            .lock()
            .map_err(|_| "session_failed")?
            .invalidate(account, None);
        let account = account.to_owned();
        tokio::task::spawn_blocking(move || {
            use crate::platform::{dirs::AppDirs, private_fs};
            use sha2::{Digest, Sha256};
            let dirs = AppDirs::discover()?;
            let hash = format!("{:x}", Sha256::digest(account.as_bytes()));
            for kind in ["mail", "attachments"] {
                if let Some(dir) =
                    private_fs::directories(&dirs.state, &["omamail", kind, &hash], false)?
                {
                    private_fs::clear_tree(&dir)?;
                }
            }
            crate::cache::call("cache.bodyClear", &json!({"accountId":account}))?;
            if let Some(dir) = private_fs::directories(&dirs.cache, &["omamail"], false)? {
                private_fs::remove_owned(
                    &dir,
                    &format!("{}.json", crate::cache::account_name(&account)?),
                )?;
            }
            crate::inbox::forget_phone_account(&account)?;
            crate::account::mobile_remove(&account)?;
            Ok::<_, &'static str>(json!({"removed":true}))
        })
        .await
        .map_err(|_| "worker_failed")?
    }
    pub async fn mobile_contacts(&self, params: &Value) -> Result<Value, &'static str> {
        if params.as_object().is_none_or(|p| p.len() != 1) {
            return Err("invalid_params");
        }
        let account = params["accountId"].as_str().ok_or("invalid_params")?;
        reader::registered(account).await?;
        let page = self.local_mail.phone_summaries(account, None).await?;
        Ok(crate::contacts::from_summaries(&page["summaries"]))
    }
    pub async fn mobile_release_send(&self, params: &Value) -> Result<Value, &'static str> {
        let account = params["accountId"].as_str().ok_or("invalid_params")?;
        reader::registered(account).await?;
        self.outbox.withdraw(params).await
    }

    pub async fn mobile_conversation(&self, params: &Value) -> Result<Value, &'static str> {
        if params.as_object().is_none_or(|p| {
            p.len() != 2 || !p.contains_key("accountId") || !p.contains_key("threadId")
        }) {
            return Err("invalid_params");
        }
        let account = params["accountId"].as_str().ok_or("invalid_params")?;
        let thread = params["threadId"].as_str().ok_or("invalid_params")?;
        reader::registered(account).await?;
        if thread.is_empty() || thread.len() > 1024 {
            return Err("invalid_params");
        }
        let resources = match self.gmail.thread_resources(account, thread).await {
            Ok(value) => value,
            Err(error) => {
                let mut cached = self
                    .local_mail
                    .phone_summaries(account, Some(thread.to_owned()))
                    .await?;
                if cached["summaries"]
                    .as_array()
                    .is_none_or(|rows| rows.is_empty())
                {
                    return Err(error);
                }
                cached["cached"] = json!(true);
                return Ok(cached);
            }
        };
        let summaries = resources
            .iter()
            .map(|r| crate::message::content::summarize(r, crate::inbox::now()))
            .collect::<Result<Vec<_>, _>>()?;
        Ok(json!({"summaries":summaries}))
    }
    pub async fn mobile_check_send(&self, params: &Value) -> Result<Value, &'static str> {
        if params.as_object().is_none_or(|p| {
            p.len() != 2 || !p.contains_key("accountId") || !p.contains_key("sendId")
        }) {
            return Err("invalid_params");
        }
        let account = params["accountId"].as_str().ok_or("invalid_params")?;
        reader::registered(account).await?;
        let mut request = params.clone();
        request["includePayloads"] = json!(true);
        let snapshot = self.outbox.call("outbox.snapshot", &request).await?;
        let entry = snapshot["entries"]
            .as_array()
            .and_then(|e| e.first())
            .ok_or("outbox_not_found")?;
        if entry["state"] != "unknown" {
            return Err("outbox_not_unknown");
        }
        use base64::Engine as _;
        use mailparse::MailHeaderMap;
        let raw = entry["payload"]["raw"]
            .as_str()
            .ok_or("outbox_message_invalid")?;
        let prefix = raw
            .get(..raw.len().min(87384))
            .ok_or("outbox_message_invalid")?;
        let bytes = base64::engine::general_purpose::URL_SAFE_NO_PAD
            .decode(prefix)
            .map_err(|_| "outbox_message_invalid")?;
        let end = bytes
            .windows(4)
            .position(|w| w == b"\r\n\r\n")
            .map(|n| n + 4)
            .or_else(|| bytes.windows(2).position(|w| w == b"\n\n").map(|n| n + 2))
            .ok_or("outbox_message_invalid")?;
        let (headers, _) =
            mailparse::parse_headers(&bytes[..end]).map_err(|_| "outbox_message_invalid")?;
        let id = headers
            .get_first_value("Message-ID")
            .ok_or("outbox_message_invalid")?;
        let key = id
            .strip_prefix('<')
            .and_then(|s| s.strip_suffix('>'))
            .filter(|s| {
                s.len() <= 256
                    && s.bytes()
                        .all(|b| b.is_ascii_alphanumeric() || b"@.-_".contains(&b))
            })
            .ok_or("outbox_message_invalid")?;
        let page=self.gmail.call("gmail.list",&json!({"accountId":account,"query":format!("in:sent rfc822msgid:{key}"),"pageSize":100})).await?;
        let mut summaries = Vec::new();
        for id in page["ids"].as_array().into_iter().flatten() {
            let resource = self
                .gmail
                .call(
                    "gmail.read",
                    &json!({"accountId":account,"id":id,"full":false}),
                )
                .await?;
            summaries.push(crate::message::content::summarize(
                &resource,
                crate::inbox::now(),
            )?);
        }
        Ok(json!({"summaries":summaries}))
    }
}
