use super::action::{ActionAvailability, ActionLookup, domain_action, plan_action};
use super::{Account, ActRequest, Provider};
use serde_json::{Value, json};
use std::{
    collections::HashMap,
    future::Future,
    pin::Pin,
    sync::{
        Arc,
        atomic::{AtomicUsize, Ordering},
    },
};

#[derive(Default)]
struct Effects {
    refusal_lookup: AtomicUsize,
    lookup: AtomicUsize,
}

struct RecordingLookup {
    availability: ActionAvailability,
    rows: HashMap<String, Value>,
    effects: Arc<Effects>,
}

impl ActionLookup for RecordingLookup {
    fn availability<'a>(
        &'a self,
        _account: &'a Account,
        _operation: &'a str,
    ) -> Pin<Box<dyn Future<Output = Result<ActionAvailability, &'static str>> + Send + 'a>> {
        self.effects.refusal_lookup.fetch_add(1, Ordering::SeqCst);
        Box::pin(async move { Ok(self.availability.clone()) })
    }

    fn rows<'a>(
        &'a self,
        _account: &'a Account,
        ids: &'a [String],
        _operation: &'a str,
    ) -> Pin<Box<dyn Future<Output = Result<Vec<Value>, &'static str>> + Send + 'a>> {
        self.effects.lookup.fetch_add(1, Ordering::SeqCst);
        Box::pin(async move {
            Ok(ids
                .iter()
                .filter_map(|id| self.rows.get(id).cloned())
                .collect())
        })
    }
}

fn account(provider: Provider) -> Account {
    Account {
        id: "me@example.org".into(),
        provider,
    }
}

fn request(provider: Provider, operation: &str, ids: &[&str]) -> ActRequest {
    ActRequest {
        account: account(provider),
        operation: operation.into(),
        ids: ids.iter().map(|id| (*id).into()).collect(),
        execute: false,
    }
}

fn lookup(refusals: Value, rows: &[Value], effects: Arc<Effects>) -> RecordingLookup {
    RecordingLookup {
        availability: ActionAvailability { refusals },
        rows: rows
            .iter()
            .map(|row| (row["id"].as_str().unwrap().to_owned(), row.clone()))
            .collect(),
        effects,
    }
}

fn row(id: &str) -> Value {
    json!({"id":id})
}

#[tokio::test]
async fn gmail_message_ids_are_validated_before_any_action_lookup() {
    for id in [
        "   ",
        ".",
        "..",
        "bad\r",
        "bad\n",
        "bad\r\n",
        "bad\0",
        "bad\u{0085}",
        "bad\u{202e}",
    ] {
        for execute in [false, true] {
            let effects = Arc::new(Effects::default());
            let mut request = request(Provider::Gmail, "read", &[id]);
            request.execute = execute;
            let error = plan_action(&request, &lookup(Value::Null, &[row(id)], effects.clone()))
                .await
                .unwrap_err();
            assert_eq!(error, "invalid_params", "{id:?}");
            assert_eq!(effects.refusal_lookup.load(Ordering::SeqCst), 0);
            assert_eq!(effects.lookup.load(Ordering::SeqCst), 0);
        }
    }
}

#[tokio::test]
async fn gmail_id_validation_preserves_valid_opaque_spelling() {
    let ids = [" quote\"slash\\工 ", "abc-123_", " e\u{301} ", "a/b?x#y%2e"];
    let rows: Vec<_> = ids.iter().map(|id| row(id)).collect();
    let preview = super::action::dry_run(
        &request(Provider::Gmail, "read", &ids),
        &lookup(Value::Null, &rows, Default::default()),
    )
    .await
    .unwrap();
    assert_eq!(preview["requestedIds"], json!(ids));
    assert_eq!(preview["targetIds"], json!(ids));
}

#[tokio::test]
async fn malformed_final_gmail_id_is_rejected_before_any_chunk_or_lookup() {
    for provider in [Provider::Gmail] {
        let mut ids: Vec<_> = (1..=501).map(|id| format!("message-{id}")).collect();
        ids.push(".".into());
        let refs: Vec<_> = ids.iter().map(String::as_str).collect();
        let rows: Vec<_> = refs.iter().map(|id| row(id)).collect();
        let effects = Arc::new(Effects::default());
        let mut request = request(provider, "read", &refs);
        request.execute = true;
        let mutation = RecordingMutation::new(vec![Ok(json!({})), Ok(json!({}))]);
        let result = super::action::act(
            &request,
            &lookup(Value::Null, &rows, effects.clone()),
            &mutation,
        )
        .await;
        assert_eq!(result, Err("invalid_params"));
        assert!(mutation.calls.lock().unwrap().is_empty());
        assert_eq!(effects.refusal_lookup.load(Ordering::SeqCst), 0);
        assert_eq!(effects.lookup.load(Ordering::SeqCst), 0);
    }
}

#[tokio::test]
async fn invalid_gmail_ids_in_expanded_targets_cannot_reach_execution() {
    for bad in [".", "..", " ", "bad\n"] {
        let expanded = json!({"id":"message-1","thread":{"memberIds":["message-1",bad]}});
        assert_eq!(
            plan_action(
                &request(Provider::Gmail, "read", &["message-1"]),
                &lookup(Value::Null, &[expanded], Default::default())
            )
            .await
            .unwrap_err(),
            "mail_action_invalid_target"
        );
    }
}

#[tokio::test]
async fn chunk_dispatch_validates_all_plan_targets_before_the_first_provider_call() {
    let ids: Vec<_> = (1..=501).map(|id| format!("message-{id}")).collect();
    let refs: Vec<_> = ids.iter().map(String::as_str).collect();
    let rows: Vec<_> = refs.iter().map(|id| row(id)).collect();
    let mut plan = plan_action(
        &request(Provider::Gmail, "read", &refs),
        &lookup(Value::Null, &rows, Default::default()),
    )
    .await
    .unwrap();
    plan.target_ids.push(".".into());
    let mutation = RecordingMutation::new(vec![Ok(json!({})), Ok(json!({}))]);
    assert!(
        crate::backend::mail::mutate_plan(&plan, &mutation)
            .await
            .is_empty()
    );
    assert!(mutation.calls.lock().unwrap().is_empty());
}

#[test]
fn mark_vocabulary_maps_once_to_domain_actions() {
    assert_eq!(domain_action("read"), Ok("markRead"));
    assert_eq!(domain_action("unread"), Ok("markUnread"));
    assert_eq!(domain_action("star"), Ok("star"));
    assert_eq!(domain_action("unstar"), Ok("unstar"));
}

#[tokio::test]
async fn plans_exact_model_label_changes_and_a_dedicated_trash_operation() {
    for (operation, add, remove) in [
        ("read", json!([]), json!(["UNREAD"])),
        ("unread", json!(["UNREAD"]), json!([])),
        ("star", json!(["STARRED"]), json!([])),
        ("unstar", json!([]), json!(["STARRED"])),
        ("archive", json!([]), json!(["INBOX"])),
        ("spam", json!(["SPAM"]), json!(["INBOX"])),
    ] {
        let effects = Arc::new(Effects::default());
        let plan = plan_action(
            &request(Provider::Gmail, operation, &["message-1"]),
            &lookup(Value::Null, &[row("message-1")], effects),
        )
        .await
        .unwrap();
        assert_eq!(plan.operation, operation);
        assert_eq!(json!(plan.add_label_ids), add);
        assert_eq!(json!(plan.remove_label_ids), remove);
    }

    let effects = Arc::new(Effects::default());
    let plan = plan_action(
        &request(Provider::Gmail, "trash", &["message-1"]),
        &lookup(Value::Null, &[row("message-1")], effects),
    )
    .await
    .unwrap();
    assert_eq!(plan.operation, "trash");
    assert_eq!(plan.add_label_ids, ["TRASH"]);
    assert_eq!(plan.remove_label_ids, Vec::<String>::new());
}

#[tokio::test]
async fn conversation_targets_are_deduplicated_in_first_appearance_order() {
    let effects = Arc::new(Effects::default());
    let conversation = json!({
        "id":"conversation-1",
        "thread":{"memberIds":["inbox-1", "sent-1", "inbox-1", "self-1", "excluded-1"]}
    });
    let plan = plan_action(
        &request(Provider::Gmail, "archive", &["conversation-1"]),
        &lookup(Value::Null, &[conversation], effects),
    )
    .await
    .unwrap();
    assert_eq!(
        plan.target_ids,
        ["inbox-1", "sent-1", "self-1", "excluded-1"]
    );
}

#[tokio::test]
async fn malformed_conversation_members_are_rejected_before_any_coercion_or_trim() {
    for members in [
        json!(["safe", "bad\n"]),
        json!(["safe", 7]),
        json!(["safe", null]),
    ] {
        let effects = Arc::new(Effects::default());
        let conversation = json!({"id":"conversation-1","thread":{"memberIds":members}});
        let error = plan_action(
            &request(Provider::Gmail, "archive", &["conversation-1"]),
            &lookup(Value::Null, &[conversation], effects),
        )
        .await
        .unwrap_err();
        assert_eq!(error, "mail_action_invalid_target");
    }
}

#[tokio::test]
async fn explicit_empty_applicable_conversation_has_no_fallback_representative_target() {
    let effects = Arc::new(Effects::default());
    let empty = json!({"id":"sent-only","thread":{"memberIds":[]}});
    assert_eq!(
        plan_action(
            &request(Provider::Gmail, "archive", &["sent-only"]),
            &lookup(Value::Null, &[empty], effects),
        )
        .await
        .unwrap_err(),
        "mail_action_target_unknown"
    );
}

#[tokio::test]
async fn account_refusals_precede_target_lookup() {
    for operation in ["archive", "star", "spam"] {
        let effects = Arc::new(Effects::default());
        let error = plan_action(
            &request(Provider::Gmail, operation, &["message-1"]),
            &lookup(
                json!({operation:"disabled"}),
                &[row("message-1")],
                effects.clone(),
            ),
        )
        .await
        .unwrap_err();
        assert_eq!(error, "mail_action_unavailable", "{operation}");
        assert_eq!(effects.lookup.load(Ordering::SeqCst), 0);
    }
    assert!(!crate::providers::can("unknown", "archive", &Value::Null));
}

#[tokio::test]
async fn duplicate_requested_ids_are_deduplicated_before_provider_lookup() {
    let effects = Arc::new(Effects::default());
    let plan = plan_action(
        &request(Provider::Gmail, "archive", &["one", "one", "two", "one"]),
        &lookup(Value::Null, &[row("one"), row("two")], effects.clone()),
    )
    .await
    .unwrap();
    assert_eq!(plan.target_ids, ["one", "two"]);
    assert_eq!(effects.lookup.load(Ordering::SeqCst), 1);
}

#[tokio::test]
async fn aggregate_conversation_expansion_is_bounded_before_a_preview_is_retained() {
    let effects = Arc::new(Effects::default());
    let members = (0..2001)
        .map(|n| json!(format!("m{n}")))
        .collect::<Vec<_>>();
    let oversized = json!({"id":"one","thread":{"memberIds":members}});
    assert_eq!(
        plan_action(
            &request(Provider::Gmail, "archive", &["one"]),
            &lookup(Value::Null, &[oversized], effects),
        )
        .await
        .unwrap_err(),
        "mail_action_target_limit"
    );
}

#[tokio::test]
async fn unsafe_or_oversized_ids_fail_before_any_lookup_or_mutation() {
    for id in [
        "line\rbreak",
        "line\nbreak",
        "line\r\nbreak",
        "nul\0byte",
        "bidi\u{202e}override",
        &"x".repeat(8193),
    ] {
        let effects = Arc::new(Effects::default());
        let error = plan_action(
            &request(Provider::Gmail, "archive", &[id]),
            &lookup(Value::Null, &[row("message-1")], effects.clone()),
        )
        .await
        .unwrap_err();
        assert_eq!(error, "invalid_params");
        assert_eq!(effects.refusal_lookup.load(Ordering::SeqCst), 0);
        assert_eq!(effects.lookup.load(Ordering::SeqCst), 0);
    }

    let effects = Arc::new(Effects::default());
    let plan = plan_action(
        &request(Provider::Gmail, "archive", &["quote\"slash\\"]),
        &lookup(Value::Null, &[row("quote\"slash\\")], effects.clone()),
    )
    .await
    .unwrap();
    assert_eq!(plan.target_ids, ["quote\"slash\\"]);
}

#[tokio::test]
async fn execution_consumes_the_same_plan_without_repeating_target_lookup() {
    let effects = Arc::new(Effects::default());
    let mut action = request(Provider::Gmail, "archive", &["message-1"]);
    action.execute = true;
    let plan = plan_action(
        &action,
        &lookup(Value::Null, &[row("message-1")], effects.clone()),
    )
    .await
    .unwrap();
    let mutation = RecordingMutation::new(vec![Ok(json!({}))]);
    let result = super::action::execute_action(plan, &mutation).await;
    assert_eq!(result["succeededIds"], json!(["message-1"]));
    assert_eq!(effects.refusal_lookup.load(Ordering::SeqCst), 1);
    assert_eq!(effects.lookup.load(Ordering::SeqCst), 1);
}

struct RecordingMutation {
    calls: std::sync::Mutex<Vec<(String, Value)>>,
    replies: std::sync::Mutex<std::collections::VecDeque<Result<Value, &'static str>>>,
}

impl RecordingMutation {
    fn new(replies: Vec<Result<Value, &'static str>>) -> Self {
        Self {
            calls: Default::default(),
            replies: std::sync::Mutex::new(replies.into()),
        }
    }
}

impl crate::backend::mail::MutationAdapter for RecordingMutation {
    fn call<'a>(
        &'a self,
        method: &'a str,
        params: Value,
    ) -> Pin<Box<dyn Future<Output = Result<Value, &'static str>> + Send + 'a>> {
        self.calls.lock().unwrap().push((method.into(), params));
        Box::pin(async move {
            self.replies
                .lock()
                .unwrap()
                .pop_front()
                .expect("unexpected retry")
        })
    }
}

impl super::action::ActionMutation for RecordingMutation {
    fn execute<'a>(
        &'a self,
        plan: &'a super::action::ActionPlan,
    ) -> Pin<Box<dyn Future<Output = Vec<String>> + Send + 'a>> {
        Box::pin(crate::backend::mail::mutate_plan(plan, self))
    }
}

#[tokio::test]
async fn routes_all_gmail_actions_using_exact_arguments() {
    let ids = ["m1", "m2"];
    for (operation, add, remove) in [
        ("read", json!([]), json!(["UNREAD"])),
        ("unread", json!(["UNREAD"]), json!([])),
        ("star", json!(["STARRED"]), json!([])),
        ("unstar", json!([]), json!(["STARRED"])),
        ("archive", json!([]), json!(["INBOX"])),
        ("trash", json!(["TRASH"]), json!([])),
        ("spam", json!(["SPAM"]), json!(["INBOX"])),
    ] {
        let mut request = request(Provider::Gmail, operation, &ids);
        request.execute = true;
        let rows: Vec<_> = ids.iter().map(|id| row(id)).collect();
        let mutation = RecordingMutation::new(vec![Ok(json!({})); 2]);
        let result = super::action::act(
            &request,
            &lookup(Value::Null, &rows, Default::default()),
            &mutation,
        )
        .await
        .unwrap();
        assert_eq!(
            result,
            json!({"dryRun":false,"executed":true,"operation":operation,
            "accountId":request.account.id,"requestedIds":ids,"targetIds":ids,"succeededIds":ids,"failedIds":[]})
        );
        let expected = if operation == "trash" {
            vec![
                (
                    "gmail.trash".into(),
                    json!({"accountId":request.account.id,"id":"m1"}),
                ),
                (
                    "gmail.trash".into(),
                    json!({"accountId":request.account.id,"id":"m2"}),
                ),
            ]
        } else {
            vec![(
                "gmail.batchModify".into(),
                json!({"accountId":request.account.id,"ids":ids,"addLabelIds":add,"removeLabelIds":remove}),
            )]
        };
        assert_eq!(*mutation.calls.lock().unwrap(), expected, "{operation}");
    }
}

#[tokio::test]
async fn dry_run_and_planning_failures_never_reach_mutations() {
    for (execute, refusals, ids) in [
        (false, Value::Null, vec!["m1"]),
        (true, json!({"archive":"disabled"}), vec!["m1"]),
        (true, Value::Null, vec!["m1", "missing"]),
        (true, Value::Null, vec!["m1", "bad\n"]),
    ] {
        let mut request = request(Provider::Gmail, "archive", &ids);
        request.execute = execute;
        let mutation = RecordingMutation::new(vec![]);
        let result = super::action::act(
            &request,
            &lookup(refusals, &[row("m1")], Default::default()),
            &mutation,
        )
        .await;
        if !execute {
            assert_eq!(result.unwrap()["executed"], false);
        } else {
            assert!(result.is_err());
        }
        assert!(mutation.calls.lock().unwrap().is_empty());
    }
}

#[tokio::test]
async fn partial_and_uncertain_results_keep_ids_explicit_without_retrying() {
    for (provider, operation, replies, succeeded, failed) in [
        (
            Provider::Gmail,
            "trash",
            vec![Ok(json!({})), Err("gmail_timeout")],
            json!(["m2"]),
            json!(["m1"]),
        ),
        (
            Provider::Gmail,
            "star",
            vec![Err("gmail_timeout")],
            json!([]),
            json!(["m2", "m1"]),
        ),
        (
            Provider::Gmail,
            "read",
            vec![Ok(json!({"succeededIds":["m1"],"failedIds":["m2"]}))],
            json!(["m1"]),
            json!(["m2"]),
        ),
        (
            Provider::Gmail,
            "read",
            vec![Ok(json!({"succeededIds":["unsolicited"],"failedIds":[]}))],
            json!([]),
            json!(["m2", "m1"]),
        ),
    ] {
        let request = request(provider, operation, &["m2", "m1", "m2"]);
        let plan = plan_action(
            &request,
            &lookup(Value::Null, &[row("m1"), row("m2")], Default::default()),
        )
        .await
        .unwrap();
        let count = replies.len();
        let mutation = RecordingMutation::new(replies);
        let result = super::action::execute_action(plan, &mutation).await;
        assert_eq!(result["requestedIds"], json!(["m2", "m1", "m2"]));
        assert_eq!(result["targetIds"], json!(["m2", "m1"]));
        assert_eq!(result["succeededIds"], succeeded);
        assert_eq!(result["failedIds"], failed);
        assert_eq!(mutation.calls.lock().unwrap().len(), count);
    }
}

#[tokio::test]
async fn gmail_batches_respect_the_native_limit_and_keep_later_failures_explicit() {
    let ids: Vec<_> = (1..=1001).map(|id| format!("message-{id}")).collect();
    let members = json!({"id":"thread","thread":{"memberIds":ids}});
    let plan = plan_action(
        &request(Provider::Gmail, "read", &["thread"]),
        &lookup(Value::Null, &[members], Default::default()),
    )
    .await
    .unwrap();
    let mutation = RecordingMutation::new(vec![Ok(json!({})), Err("gmail_timeout")]);
    let result = super::action::execute_action(plan, &mutation).await;
    assert_eq!(result["succeededIds"], json!(&ids[..1000]));
    assert_eq!(result["failedIds"], json!(["message-1001"]));
    let calls = mutation.calls.lock().unwrap();
    assert_eq!(calls.len(), 2);
    assert_eq!(calls[0].1["ids"], json!(&ids[..1000]));
    assert_eq!(calls[1].1["ids"], json!(["message-1001"]));
}
