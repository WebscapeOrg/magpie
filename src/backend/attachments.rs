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
        super::reader::registered(account).await?;
        let (cached_account, message_id, attachment_id) =
            (account.to_owned(), id.to_owned(), part.to_owned());
        if let Some(value) = tokio::task::spawn_blocking(move || {
            vault::cached(&cached_account, &message_id, &attachment_id)
        })
        .await
        .map_err(|_| "worker_failed")??
        {
            return Ok(value);
        }
        let params = json!({"accountId":account,"messageId":id,"attachmentId":part});
        let value = self.gmail.call("gmail.attachment", &params).await?;
        let (cached_account, message_id, attachment_id, saved) = (
            account.to_owned(),
            id.to_owned(),
            part.to_owned(),
            value.clone(),
        );
        tokio::task::spawn_blocking(move || {
            vault::cache(&cached_account, &message_id, &attachment_id, &saved)
        })
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
        let draft = if method == "attachment.retain" {
            Some(
                params["draftKey"]
                    .as_str()
                    .filter(|value| {
                        !value.is_empty()
                            && value.len() <= 4096
                            && !value.chars().any(char::is_control)
                    })
                    .ok_or("invalid_params")?
                    .to_owned(),
            )
        } else {
            None
        };
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
                let draft = draft.ok_or("invalid_params")?;
                tokio::task::spawn_blocking(move || vault::retain(&account, &draft, &value))
                    .await
                    .map_err(|_| "worker_failed")?
            }
            _ => Err("unknown_method"),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn retain_accepts_the_draft_key_boundary_and_rejects_larger_keys_before_storage() {
        if crate::mail::tests::isolated() {
            return;
        }
        let fixture = crate::mail::tests::account_fixture(
            json!({"version":1,"accounts":[{"provider":"gmail","email":"owner@example.test"}]}),
        );
        let data = json!({"data":"c3ludGhldGlj"});
        vault::cache("owner@example.test", "message", "part", &data).unwrap();
        let session = Session::default();
        let draft = "d".repeat(4096);
        let mut params = json!({"accountId":"owner@example.test","messageId":"message","attachmentId":"part","filename":"example.txt","mimeType":"text/plain","draftKey":draft});
        let retained = session
            .attachment_request("attachment.retain", &params)
            .await
            .unwrap();
        let mut fields = json!({"draftKey":draft,"attachments":[retained]});
        vault::hydrate("owner@example.test", &mut fields).unwrap();
        assert_eq!(fields["attachments"][0]["data"], data["data"]);
        let before = crate::mail::tests::fixture_tree(&fixture.root);
        params["draftKey"] = json!("d".repeat(4097));
        assert_eq!(
            session
                .attachment_request("attachment.retain", &params)
                .await,
            Err("invalid_params")
        );
        assert_eq!(crate::mail::tests::fixture_tree(&fixture.root), before);
    }
}
