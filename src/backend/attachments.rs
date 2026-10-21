use super::Session;
use crate::attachment::{self, vault};
use serde_json::{Value, json};

impl Session {
    async fn attachment_data(
        &self,
        account: &str,
        id: &str,
        part: &str,
    ) -> Result<Value, &'static str> {
        crate::cache::validate_params(&json!({"accountId":account,"id":id}), true)?;
        if part.is_empty() || part.len() > 16384 || part.chars().any(char::is_control) {
            return Err("invalid_params");
        }
        let provider = super::reader::registered(account).await?;
        let (a, m, p) = (account.to_owned(), id.to_owned(), part.to_owned());
        if let Some(value) = tokio::task::spawn_blocking(move || vault::cached(&a, &m, &p))
            .await
            .map_err(|_| "worker_failed")??
        {
            return Ok(value);
        }
        let params = json!({"accountId":account,"messageId":id,"attachmentId":part});
        let value = match provider.as_str() {
            "gmail" => self.gmail.call("gmail.attachment", &params).await?,
            "jmap" => {
                self.jmap
                    .call(
                        "jmap.attachment",
                        &json!({"accountId":account,"attachmentId":part}),
                    )
                    .await?
            }
            "imap" | "outlook" => crate::providers::imap::call("imap.attachment", &params).await?,
            _ => return Err("attachment_provider_unsupported"),
        };
        let (a, m, p, saved) = (
            account.to_owned(),
            id.to_owned(),
            part.to_owned(),
            value.clone(),
        );
        tokio::task::spawn_blocking(move || vault::cache(&a, &m, &p, &saved))
            .await
            .map_err(|_| "worker_failed")??;
        Ok(value)
    }
    pub(super) async fn attachment_request(
        &self,
        method: &str,
        params: &Value,
    ) -> Result<Value, &'static str> {
        let allowed: &[&str] = match method {
            "attachment.import" => &["accountId", "draftKey", "path"],
            "attachment.preview" => &[
                "accountId",
                "messageId",
                "attachmentId",
                "filename",
                "mimeType",
            ],
            "attachment.download" => &[
                "accountId",
                "messageId",
                "attachmentId",
                "filename",
                "mimeType",
                "open",
            ],
            "attachment.retain" => &[
                "accountId",
                "messageId",
                "attachmentId",
                "filename",
                "mimeType",
                "draftKey",
            ],
            _ => return Err("unknown_method"),
        };
        if params
            .as_object()
            .is_none_or(|p| p.keys().any(|key| !allowed.contains(&key.as_str())))
        {
            return Err("invalid_params");
        }
        if method == "attachment.download" && !params["open"].is_boolean() {
            return Err("invalid_params");
        }
        if method == "attachment.retain"
            && params["draftKey"]
                .as_str()
                .is_none_or(|v| v.is_empty() || v.len() > 4096 || v.chars().any(char::is_control))
        {
            return Err("invalid_params");
        }
        let account = params["accountId"]
            .as_str()
            .ok_or("invalid_params")?
            .to_owned();
        super::reader::registered(&account).await?;
        if method == "attachment.import" {
            let params = params.clone();
            return tokio::task::spawn_blocking(move || vault::import(&params))
                .await
                .map_err(|_| "worker_failed")?;
        }
        let id = params["messageId"].as_str().ok_or("invalid_params")?;
        let part = params["attachmentId"].as_str().ok_or("invalid_params")?;
        let mut value = self.attachment_data(&account, id, part).await?;
        value["filename"] = params["filename"].clone();
        value["mimeType"] = params["mimeType"].clone();
        match method {
            "attachment.preview" => {
                attachment::thumbnail::prepare(
                    &json!({"data":value["data"],"mimeType":value["mimeType"]}),
                )
                .await
            }
            "attachment.download" => {
                value["open"] = json!(params["open"].as_bool().ok_or("invalid_params")?);
                tokio::task::spawn_blocking(move || {
                    let bytes = attachment::decode(
                        value["data"].as_str().ok_or("attachment_data_invalid")?,
                    )?;
                    attachment::store(&value, &bytes)
                })
                .await
                .map_err(|_| "worker_failed")?
            }
            "attachment.retain" => {
                let draft = params["draftKey"]
                    .as_str()
                    .filter(|s| !s.is_empty() && s.len() < 4096 && !s.chars().any(char::is_control))
                    .ok_or("invalid_params")?
                    .to_owned();
                tokio::task::spawn_blocking(move || vault::retain(&account, &draft, &value))
                    .await
                    .map_err(|_| "worker_failed")?
            }
            _ => Err("unknown_method"),
        }
    }
}
