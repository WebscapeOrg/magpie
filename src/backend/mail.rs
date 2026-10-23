use super::Session;
use crate::mail::{ActRequest, ListRequest, ReadRequest, SendRequest};
use serde_json::{Value, json};
use std::{future::Future, pin::Pin};

struct MailList<'a> {
    session: &'a Session,
}

struct MailRead<'a> {
    session: &'a Session,
}

struct SendIdentities<'a> {
    session: &'a Session,
}

impl crate::mail::send::IdentityLookup for SendIdentities<'_> {
    fn identities<'a>(
        &'a self,
        account: &'a crate::mail::Account,
    ) -> Pin<Box<dyn Future<Output = Result<Value, &'static str>> + Send + 'a>> {
        Box::pin(async move {
            let refusals = crate::account::refusals_readonly(&account.id)?;
            if !crate::providers::can(account.provider.id(), "send", &refusals) {
                return Err("mail_send_unavailable");
            }
            let params = json!({"accountId":account.id});
            self.session.gmail.call("gmail.sendAs", &params).await
        })
    }
}

pub(crate) trait MutationAdapter: Send + Sync {
    fn call<'a>(
        &'a self,
        method: &'a str,
        params: Value,
    ) -> Pin<Box<dyn Future<Output = Result<Value, &'static str>> + Send + 'a>>;
}

struct MailMutation<'a> {
    session: &'a Session,
}

impl MutationAdapter for MailMutation<'_> {
    fn call<'a>(
        &'a self,
        method: &'a str,
        params: Value,
    ) -> Pin<Box<dyn Future<Output = Result<Value, &'static str>> + Send + 'a>> {
        Box::pin(async move { self.session.gmail.call_settled(method, &params).await })
    }
}

/// Invariant: Provider results are acknowledgements, never diagnostics to forward. A partial
/// response must name every requested ID exactly once; malformed or contradictory acknowledgements
/// cannot confirm any member of that call.
fn confirmed_ids(reply: Result<Value, &'static str>, ids: &[String]) -> Vec<String> {
    let Ok(reply) = reply else {
        return Vec::new();
    };
    if reply.get("succeededIds").is_none() && reply.get("failedIds").is_none() {
        return ids.to_vec();
    }
    let (Some(succeeded), Some(failed)) = (
        reply["succeededIds"].as_array(),
        reply["failedIds"].as_array(),
    ) else {
        return Vec::new();
    };
    let mut seen = std::collections::HashSet::new();
    for id in succeeded.iter().chain(failed) {
        let Some(id) = id.as_str() else {
            return Vec::new();
        };
        if !ids.iter().any(|target| target == id) || !seen.insert(id) {
            return Vec::new();
        }
    }
    if seen.len() != ids.len() {
        return Vec::new();
    }
    succeeded
        .iter()
        .filter_map(Value::as_str)
        .map(str::to_owned)
        .collect()
}

pub(crate) async fn mutate_plan(
    plan: &crate::mail::action::ActionPlan,
    adapter: &impl MutationAdapter,
) -> Vec<String> {
    // Invariant: Validate the complete plan before chunking: a malformed later target must never
    // permit an earlier chunk to mutate the provider or caches.
    if plan
        .target_ids
        .iter()
        .any(|id| crate::mail::action::validate_message_id(plan.account.provider, id).is_err())
    {
        return Vec::new();
    }
    let mut succeeded = Vec::new();
    let chunk_size = if plan.operation == "trash" { 1 } else { 1000 };
    for ids in plan.target_ids.chunks(chunk_size) {
        let mut params = json!({"accountId":plan.account.id,"ids":ids});
        let method = if plan.operation == "trash" {
            params = json!({"accountId":plan.account.id,"id":ids[0]});
            "gmail.trash"
        } else {
            params["addLabelIds"] = json!(plan.add_label_ids);
            params["removeLabelIds"] = json!(plan.remove_label_ids);
            "gmail.batchModify"
        };
        succeeded.extend(confirmed_ids(adapter.call(method, params).await, ids));
    }
    succeeded
}

impl crate::mail::action::ActionMutation for MailMutation<'_> {
    fn execute<'a>(
        &'a self,
        plan: &'a crate::mail::action::ActionPlan,
    ) -> Pin<Box<dyn Future<Output = Vec<String>> + Send + 'a>> {
        Box::pin(async move {
            let succeeded = mutate_plan(plan, self).await;
            if !succeeded.is_empty() {
                self.session
                    .invalidate_action_caches(&plan.account.id)
                    .await;
            }
            succeeded
        })
    }
}

struct AccountActionLookup;

impl crate::mail::action::ActionLookup for AccountActionLookup {
    fn availability<'a>(
        &'a self,
        account: &'a crate::mail::Account,
        _operation: &'a str,
    ) -> Pin<
        Box<
            dyn Future<Output = Result<crate::mail::action::ActionAvailability, &'static str>>
                + Send
                + 'a,
        >,
    > {
        Box::pin(async move {
            let refusals = crate::account::refusals_readonly(&account.id)?;
            Ok(crate::mail::action::ActionAvailability { refusals })
        })
    }

    fn rows<'a>(
        &'a self,
        _account: &'a crate::mail::Account,
        ids: &'a [String],
        _operation: &'a str,
    ) -> Pin<Box<dyn Future<Output = Result<Vec<Value>, &'static str>> + Send + 'a>> {
        Box::pin(async move { Ok(ids.iter().map(|id| json!({"id":id})).collect()) })
    }
}

fn summaries(messages: &[Value]) -> Result<Vec<Value>, &'static str> {
    let now = chrono::Utc::now().timestamp_millis();
    messages
        .iter()
        .map(|message| crate::message::content::summarize(message, now))
        .collect()
}

impl Session {
    pub(crate) async fn finish_cli_send(&self, result: &mut Value) -> Result<(), &'static str> {
        result["outbox"] = self
            .outbox
            .wait_for_send(
                result["accountId"]
                    .as_str()
                    .ok_or("outbox_invalid_params")?,
                result["sendId"].as_str().ok_or("outbox_invalid_params")?,
            )
            .await?;
        Ok(())
    }

    pub(super) async fn mail_call(
        &self,
        method: &str,
        params: &Value,
    ) -> Result<Value, &'static str> {
        match method {
            "mail.send" => {
                let request = SendRequest::try_from(params)?;
                crate::mail::send::send_with(
                    request,
                    &SendIdentities { session: self },
                    &self.outbox,
                )
                .await
            }
            "mail.list" => {
                let request = ListRequest::try_from(params)?;
                crate::mail::list::list_with(request, &MailList { session: self }).await
            }
            "mail.read" => {
                let request = ReadRequest::try_from(params)?;
                crate::mail::read::read_with(request, &MailRead { session: self }).await
            }
            "mail.act" => {
                let request = ActRequest::try_from(params)?;
                crate::mail::action::act(
                    &request,
                    &AccountActionLookup,
                    &MailMutation { session: self },
                )
                .await
            }
            _ => Err("unknown_method"),
        }
    }

    async fn invalidate_action_caches(&self, account: &str) {
        let params = json!({"accountId":account});
        // Invariant: Cache failures cannot erase confirmed delivery or invite a retry.
        if let Ok(restored) = self.queries.call("cache.queryRestore", &params).await {
            let _ = self
                .queries
                .call(
                    "cache.queryInvalidate",
                    &json!({"accountId":account,"generation":restored["generation"],"ids":[]}),
                )
                .await;
            // Invariant: The one-shot CLI can exit before the cache's debounce fires.
            let _ = self
                .queries
                .call(
                    "cache.queryFlush",
                    &json!({"accountId":account,"generation":restored["generation"]}),
                )
                .await;
        }
        if let Ok(mut renders) = self.renders.lock() {
            renders.invalidate(account, None);
        }
        let _ = tokio::task::spawn_blocking(move || {
            for method in ["cache.resourceClear", "cache.bodyClear"] {
                let _ = crate::cache::call(method, &params);
            }
        })
        .await;
    }

    async fn list_page(&self, request: &ListRequest, query: String) -> Result<Value, &'static str> {
        let params = json!({
            "accountId":request.account.id,
            "query":query,
            "pageSize":request.limit,
            "pageToken":request.page_token,
        });
        self.gmail_list(&params).await
    }

    async fn gmail_list(&self, params: &Value) -> Result<Value, &'static str> {
        let page = self.gmail.call("gmail.list", params).await?;
        let ids = page["ids"]
            .as_array()
            .ok_or("gmail_invalid_response")?
            .iter()
            .map(|id| {
                id.as_str()
                    .map(str::to_owned)
                    .ok_or("gmail_invalid_response")
            })
            .collect::<Result<Vec<_>, _>>()?;
        use futures_util::{StreamExt, TryStreamExt};
        let pending = ids
            .iter()
            .cloned()
            .map(|id| async move {
                self.gmail
                    .call(
                        "gmail.read",
                        &json!({"accountId":params["accountId"],"id":id,"full":false}),
                    )
                    .await
            })
            .collect::<Vec<_>>();
        let messages = futures_util::stream::iter(pending)
            .buffered(4)
            .try_collect::<Vec<_>>()
            .await?;
        Ok(json!({
            "ids":ids,
            "messages":summaries(&messages)?,
            "nextPageToken":page["nextPageToken"].as_str().unwrap_or(""),
            "estimate":page["estimate"].as_u64().unwrap_or(0),
        }))
    }
}

impl crate::mail::list::ListAdapter for MailList<'_> {
    fn list<'a>(
        &'a self,
        request: &'a ListRequest,
        provider_query: String,
    ) -> Pin<Box<dyn Future<Output = Result<Value, &'static str>> + Send + 'a>> {
        Box::pin(self.session.list_page(request, provider_query))
    }
}

impl crate::mail::read::ReadAdapter for MailRead<'_> {
    fn call<'a>(
        &'a self,
        method: &'a str,
        params: Value,
    ) -> Pin<Box<dyn Future<Output = Result<Value, &'static str>> + Send + 'a>> {
        Box::pin(async move {
            if method == "reader.open" {
                return self.session.reader_call(method, &params).await;
            }
            if method == "account.conversation" {
                return tokio::task::spawn_blocking(move || {
                    crate::account::conversation::request(&params)
                })
                .await
                .map_err(|_| "worker_failed")?;
            }
            Err("unknown_method")
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::mail::{Account, Provider, ReadRequest};
    use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
    use std::{
        future::Future,
        pin::Pin,
        sync::{Arc, Mutex},
    };

    struct ReaderProjectionAdapter {
        opened: Value,
        calls: Arc<Mutex<Vec<String>>>,
    }

    impl crate::mail::read::ReadAdapter for ReaderProjectionAdapter {
        fn call<'a>(
            &'a self,
            method: &'a str,
            _params: Value,
        ) -> Pin<Box<dyn Future<Output = Result<Value, &'static str>> + Send + 'a>> {
            self.calls.lock().unwrap().push(method.to_owned());
            Box::pin(async move {
                if method == "reader.open" {
                    Ok(self.opened.clone())
                } else {
                    Err("unexpected_method")
                }
            })
        }
    }

    fn reader_resource(html: &str, multipart: bool) -> Value {
        let html = URL_SAFE_NO_PAD.encode(html);
        let payload = if multipart {
            json!({"mimeType":"multipart/alternative","headers":[],"parts":[
                {"mimeType":"text/plain","body":{"data":URL_SAFE_NO_PAD.encode("Safe text")}},
                {"mimeType":"text/html","body":{"data":html}}
            ]})
        } else {
            json!({"mimeType":"text/html","headers":[],"body":{"data":html}})
        };
        json!({"id":"message-1","payload":payload})
    }

    async fn assert_closed_mail_read_projection(
        resource: Value,
        expected_text: &str,
        has_plain_images: bool,
    ) {
        let tracker = "https://tracker.example/pixel";
        let data_script = "data:text/html,&lt;script&gt;forbiddenDataScript&lt;/script&gt;";
        let opened = super::super::reader::projection(
            &resource,
            "reader@example.org",
            "message-1",
            "test-reader-key",
            0,
            json!({"allowRemoteImages":false,"withReader":true}),
            &Default::default(),
            None,
        )
        .unwrap();
        assert!(
            opened["nativeRender"]["remoteImageSources"]
                .to_string()
                .contains(tracker)
        );
        if has_plain_images {
            assert!(
                opened["nativeRender"]["plainText"]["images"]
                    .to_string()
                    .contains(data_script)
            );
        }

        let calls = Arc::new(Mutex::new(Vec::new()));
        let result = crate::mail::read::read_with(
            ReadRequest {
                account: Account {
                    id: "reader@example.org".into(),
                    provider: Provider::Gmail,
                },
                id: "message-1".into(),
            },
            &ReaderProjectionAdapter {
                opened,
                calls: calls.clone(),
            },
        )
        .await
        .unwrap();
        assert_eq!(
            result["message"]["nativeContent"]["body"]["text"],
            expected_text
        );
        assert!(result["message"]["nativeRender"]["document"].is_object());
        let serialized = result.to_string();
        assert!(!serialized.contains(tracker));
        assert!(!serialized.contains(data_script));
        assert_eq!(&*calls.lock().unwrap(), &["reader.open"]);
    }

    #[tokio::test]
    async fn mail_read_projects_actual_multipart_reader_output_without_image_sources() {
        assert_closed_mail_read_projection(
            reader_resource(
                "<p>Safe HTML</p><img src=\"https://tracker.example/pixel\"><img src=\"data:text/html,&lt;script&gt;forbiddenDataScript&lt;/script&gt;\">",
                true,
            ),
            "Safe text",
            false,
        )
        .await;
    }

    #[tokio::test]
    async fn mail_read_projects_actual_html_reader_output_without_image_sources() {
        assert_closed_mail_read_projection(
            reader_resource(
                "<p>Safe HTML</p><img src=\"https://tracker.example/pixel\"><img src=\"data:text/html,&lt;script&gt;forbiddenDataScript&lt;/script&gt;\">",
                false,
            ),
            "Safe HTML\n[image 1][image 2]",
            true,
        )
        .await;
    }

    #[tokio::test]
    async fn mail_read_drops_inline_raster_data_from_actual_reader_document() {
        let image = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScL6fQAAAABJRU5ErkJggg==";
        let opened = super::super::reader::projection(
            &reader_resource(
                &format!("<p>Visible image text</p><img src=\"{image}\">"),
                false,
            ),
            "reader@example.org",
            "message-1",
            "test-reader-key",
            0,
            json!({"allowRemoteImages":false,"withReader":true}),
            &Default::default(),
            None,
        )
        .unwrap();
        assert!(
            opened["nativeRender"]["document"]
                .to_string()
                .contains(image)
        );

        let calls = Arc::new(Mutex::new(Vec::new()));
        let result = crate::mail::read::read_with(
            ReadRequest {
                account: Account {
                    id: "reader@example.org".into(),
                    provider: Provider::Gmail,
                },
                id: "message-1".into(),
            },
            &ReaderProjectionAdapter {
                opened,
                calls: calls.clone(),
            },
        )
        .await
        .unwrap();
        assert!(
            result["message"]["nativeContent"]["body"]["text"]
                .as_str()
                .is_some_and(|text| text.contains("Visible image text"))
        );
        let document = &result["message"]["nativeRender"]["document"];
        assert_eq!(document["children"][0]["name"], "p");
        assert!(document.to_string().contains("Visible image text"));
        assert_eq!(document["children"][1]["name"], "img");
        assert_eq!(document["children"][1]["attrs"], json!([]));
        let serialized = result.to_string();
        assert!(!serialized.contains(image));
        assert!(!serialized.contains("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJ"));
        assert_eq!(&*calls.lock().unwrap(), &["reader.open"]);
    }

    async fn actual_mail_read(resource: Value) -> (Value, Value) {
        let opened = super::super::reader::projection(
            &resource,
            "reader@example.org",
            "message-1",
            "test-reader-key",
            0,
            json!({"allowRemoteImages":false,"withReader":true}),
            &Default::default(),
            None,
        )
        .unwrap();
        let calls = Arc::new(Mutex::new(Vec::new()));
        let result = crate::mail::read::read_with(
            ReadRequest {
                account: Account {
                    id: "reader@example.org".into(),
                    provider: Provider::Gmail,
                },
                id: "message-1".into(),
            },
            &ReaderProjectionAdapter {
                opened: opened.clone(),
                calls: calls.clone(),
            },
        )
        .await
        .unwrap();
        assert_eq!(&*calls.lock().unwrap(), &["reader.open"]);
        (opened, result)
    }

    fn document_node_count(node: &Value) -> usize {
        1 + node
            .get("children")
            .and_then(Value::as_array)
            .map(|children| children.iter().map(document_node_count).sum())
            .unwrap_or(0)
    }

    #[tokio::test]
    async fn mail_read_keeps_actual_reader_documents_above_the_former_node_limit() {
        let (opened, result) =
            actual_mail_read(reader_resource(&"<p>x</p>".repeat(4096), false)).await;
        assert_eq!(
            document_node_count(&opened["nativeRender"]["document"]),
            8193
        );
        assert_eq!(
            result["message"]["nativeRender"]["document"]["children"]
                .as_array()
                .unwrap()
                .len(),
            4096
        );
    }

    #[tokio::test]
    async fn mail_read_keeps_empty_body_metadata_from_an_attachment_only_reader_result() {
        let resource = json!({"id":"message-1","payload":{"mimeType":"multipart/mixed","headers":[],"parts":[
            {"mimeType":"application/octet-stream","filename":"brief.bin","body":{"data":URL_SAFE_NO_PAD.encode("attachment-bytes"),"attachmentId":"download-1","size":16}}
        ]}});
        let (opened, result) = actual_mail_read(resource).await;
        assert_eq!(opened["nativeContent"]["body"]["source"], "");
        assert_eq!(opened["nativeContent"]["body"]["bodyDirection"], "");
        assert_eq!(result["message"]["nativeContent"]["body"]["source"], "");
        assert_eq!(
            result["message"]["nativeContent"]["body"]["bodyDirection"],
            ""
        );
        assert_eq!(
            result["message"]["attachments"][0]["attachmentId"],
            "download-1"
        );
    }

    #[tokio::test]
    async fn mail_read_keeps_empty_direction_for_direction_neutral_text() {
        let resource = json!({"id":"message-1","payload":{"mimeType":"text/plain","headers":[],"body":{"data":URL_SAFE_NO_PAD.encode("  123 😀  \n")}}});
        let (opened, result) = actual_mail_read(resource).await;
        assert_eq!(opened["nativeContent"]["body"]["source"], "plain");
        assert_eq!(opened["nativeContent"]["body"]["bodyDirection"], "");
        assert_eq!(
            result["message"]["nativeContent"]["body"]["text"],
            "  123 😀  \n"
        );
        assert_eq!(
            result["message"]["nativeContent"]["body"]["bodyDirection"],
            ""
        );
    }
}
