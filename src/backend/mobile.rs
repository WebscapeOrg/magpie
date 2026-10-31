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
