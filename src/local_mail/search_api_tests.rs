use super::{
    Store, execute,
    tests::{directory, message, open_directory},
    validate,
};
use serde_json::{Value, json};

const ACCOUNT: &str = "alice@example.org";
const AS_OF: i64 = 1_700_086_400_000;

fn ids(response: &Value) -> Vec<&str> {
    response["summaries"]
        .as_array()
        .unwrap()
        .iter()
        .map(|row| row["id"].as_str().unwrap())
        .collect()
}

#[test]
fn cached_summaries_are_ordered_account_owned_metadata_without_blob_reads() {
    let path = directory();
    let store = Store::open(open_directory(&path)).unwrap();
    store.put(&message("one", "private body"), 1).unwrap();
    store.put(&message("two", "other private body"), 1).unwrap();
    std::fs::remove_dir_all(path.join("blobs")).unwrap();
    let response = execute(
        &store,
        "local.summaries",
        &json!({"accountId":ACCOUNT,"ids":["two","missing","one"],"query":"from:me","asOf":AS_OF}),
    )
    .unwrap();
    assert_eq!(ids(&response), ["two", "one"]);
    assert_eq!(response["missingIds"], json!(["missing"]));
    assert_eq!(response["asOf"], AS_OF);
    for summary in response["summaries"].as_array().unwrap() {
        assert_eq!(summary["matchesQuery"], true);
        assert_eq!(summary["pendingEdit"], false);
    }
    assert!(
        store.resource("one").is_err(),
        "summary lookup must not depend on reading a blob"
    );
    drop(store);
    std::fs::remove_dir_all(path).unwrap();
}

#[test]
fn summary_matches_use_effective_labels_and_conservative_unknown_branches() {
    let path = directory();
    let store = Store::open(open_directory(&path)).unwrap();
    store.put(&message("one", "needle"), 1).unwrap();
    store
        .edit("read", &["one".into()], &[], &["UNREAD".into()])
        .unwrap();
    for (query, expected) in [
        ("is:read", json!(true)),
        ("is:unread", json!(false)),
        ("is:unread has:drive", json!(false)),
        ("is:unread OR has:drive", Value::Null),
        ("subject:nope", json!(false)),
    ] {
        let response = execute(
            &store,
            "local.summaries",
            &json!({"accountId":ACCOUNT,"ids":["one"],"query":query,"asOf":AS_OF}),
        )
        .unwrap();
        assert_eq!(
            response["summaries"][0]["matchesQuery"], expected,
            "{query}"
        );
        assert_eq!(response["summaries"][0]["pendingEdit"], true);
        assert_eq!(response["summaries"][0]["unread"], false);
    }
    let response = execute(
        &store,
        "local.list",
        &json!({"accountId":ACCOUNT,"query":"is:read","asOf":AS_OF}),
    )
    .unwrap();
    assert_eq!(response["summaries"][0]["pendingEdit"], true);
    assert_eq!(response["summaries"][0]["matchesQuery"], true);
    drop(store);
    std::fs::remove_dir_all(path).unwrap();
}

#[test]
fn pending_summary_pages_are_bounded_and_bound_to_account_query_and_anchor() {
    let path = directory();
    let store = Store::open(open_directory(&path)).unwrap();
    let mut selected = Vec::new();
    for number in 0..103 {
        let id = format!("id-{number:03}");
        store.put(&message(&id, "needle"), 1).unwrap();
        selected.push(id);
    }
    store
        .edit("star", &selected, &["STARRED".into()], &[])
        .unwrap();
    let params = json!({"accountId":ACCOUNT,"ids":[],"query":"is:starred","includePending":true,"asOf":AS_OF});
    let first = execute(&store, "local.summaries", &params).unwrap();
    assert_eq!(ids(&first).len(), 100);
    let token = first["pendingNextPageToken"].as_str().unwrap();
    assert!(!token.is_empty());
    let mut continuation = params.clone();
    continuation["pendingPageToken"] = json!(token);
    continuation.as_object_mut().unwrap().remove("asOf");
    let second = execute(&store, "local.summaries", &continuation).unwrap();
    assert_eq!(ids(&second), ["id-100", "id-101", "id-102"]);
    assert_eq!(second["asOf"], AS_OF);
    assert_eq!(second["pendingNextPageToken"], "");
    for (key, value) in [
        ("accountId", json!("other@example.org")),
        ("query", json!("is:read")),
        ("asOf", json!(AS_OF + 1)),
    ] {
        let mut changed = continuation.clone();
        changed[key] = value;
        assert_eq!(
            execute(&store, "local.summaries", &changed),
            Err("invalid_params")
        );
    }
    drop(store);
    std::fs::remove_dir_all(path).unwrap();
}

#[test]
fn relative_list_pagination_keeps_reference_time_and_refuses_rebinding() {
    let path = directory();
    let store = Store::open(open_directory(&path)).unwrap();
    for id in ["one", "two"] {
        store.put(&message(id, "needle"), 1).unwrap();
    }
    let params = json!({"accountId":ACCOUNT,"query":"newer_than:2d","limit":1,"asOf":AS_OF});
    let first = execute(&store, "local.list", &params).unwrap();
    let mut continuation = params.clone();
    continuation["pageToken"] = first["nextPageToken"].clone();
    continuation.as_object_mut().unwrap().remove("asOf");
    let second = execute(&store, "local.list", &continuation).unwrap();
    assert_eq!(second["asOf"], AS_OF);
    assert_ne!(ids(&first), ids(&second));
    for (key, value) in [
        ("accountId", json!("other@example.org")),
        ("query", json!("newer_than:3d")),
        ("asOf", json!(AS_OF + 1)),
    ] {
        let mut changed = continuation.clone();
        changed[key] = value;
        assert_eq!(
            execute(&store, "local.list", &changed),
            Err("invalid_params")
        );
    }
    drop(store);
    std::fs::remove_dir_all(path).unwrap();
}

#[test]
fn summary_limits_reject_invalid_input_before_opening_storage() {
    let base = json!({"accountId":ACCOUNT,"ids":["one"]});
    for (key, value) in [
        ("ids", json!(["one", "one"])),
        ("ids", json!(vec!["one"; 101])),
        ("ids", json!(["a\nb"])),
        ("asOf", json!(-1)),
        ("asOf", json!(9_007_199_254_740_992_i64)),
        ("includePending", json!("true")),
        ("pendingPageToken", json!("unowned")),
    ] {
        let mut params = base.clone();
        params[key] = value;
        assert_eq!(
            validate("local.summaries", &params, false),
            Err("invalid_params")
        );
    }
    let mut params = base;
    params["query"] = json!("subject:\"");
    assert_eq!(
        validate("local.summaries", &params, false),
        Err("local_search_invalid")
    );
}

#[test]
fn incomplete_body_does_not_remove_server_confirmed_pending_results() {
    let path = directory();
    let store = Store::open(open_directory(&path)).unwrap();
    let mut resource = message("one", "");
    resource["payload"]["body"] = json!({"attachmentId":"missing-body","size":32});
    store.put(&resource, 1).unwrap();
    store
        .edit("star", &["one".into()], &["STARRED".into()], &[])
        .unwrap();
    let response = execute(
        &store,
        "local.summaries",
        &json!({"accountId":ACCOUNT,"ids":["one"],"query":"needle is:starred","asOf":AS_OF}),
    )
    .unwrap();
    assert!(response["summaries"][0]["matchesQuery"].is_null());
    assert!(response["summaries"][0]["pendingLabelMatch"].is_null());
    let response = execute(
        &store,
        "local.summaries",
        &json!({"accountId":ACCOUNT,"ids":["one"],"query":"needle -is:starred","asOf":AS_OF}),
    )
    .unwrap();
    assert_eq!(response["summaries"][0]["matchesQuery"], false);
    assert_eq!(response["summaries"][0]["pendingLabelMatch"], false);
    drop(store);
    std::fs::remove_dir_all(path).unwrap();
}

#[test]
fn summary_response_bound_and_sql_parameters_do_not_allow_untrusted_ids_to_change_storage() {
    let path = directory();
    let store = Store::open(open_directory(&path)).unwrap();
    store.put(&message("one", "needle"), 1).unwrap();
    let hostile = "one'; DELETE FROM messages; --";
    let response = execute(
        &store,
        "local.summaries",
        &json!({"accountId":ACCOUNT,"ids":[hostile]}),
    )
    .unwrap();
    assert_eq!(response["summaries"], json!([]));
    assert_eq!(response["missingIds"], json!([hostile]));
    assert_eq!(store.status().unwrap()["stored"], 1);
    store
        .write(|db| {
            let huge = json!({"id":"one","snippet":"x".repeat(16 * 1024 * 1024)}).to_string();
            super::store::sql(
                db.execute("UPDATE messages SET summary=?1 WHERE id='one'", [&huge]),
            )?;
            Ok(())
        })
        .unwrap();
    assert_eq!(
        execute(
            &store,
            "local.summaries",
            &json!({"accountId":ACCOUNT,"ids":["one"]})
        ),
        Err("local_content_too_large")
    );
    assert_eq!(store.status().unwrap()["stored"], 1);
    drop(store);
    std::fs::remove_dir_all(path).unwrap();
}

#[test]
fn incomplete_negative_body_matches_cannot_add_unconfirmed_pending_results() {
    let path = directory();
    let store = Store::open(open_directory(&path)).unwrap();
    let mut resource = message("one", "");
    resource["payload"]["body"] = json!({"attachmentId":"missing-body","size":32});
    store.put(&resource, 1).unwrap();
    store
        .edit("star", &["one".into()], &["STARRED".into()], &[])
        .unwrap();
    for (query, expected) in [
        ("-needle is:starred", Value::Null),
        ("-(needle OR other) is:starred", Value::Null),
        ("is:starred", json!(true)),
        ("is:starred OR -needle", json!(true)),
    ] {
        for method in ["local.summaries", "local.list"] {
            let mut params = json!({"accountId":ACCOUNT,"query":query,"asOf":AS_OF});
            if method == "local.summaries" {
                params["ids"] = json!(["one"]);
            }
            let response = execute(&store, method, &params).unwrap();
            assert_eq!(ids(&response), ["one"], "{method}: {query}");
            assert_eq!(
                response["summaries"][0]["matchesQuery"], expected,
                "{method}: {query}"
            );
            assert_eq!(
                response["summaries"][0]["pendingLabelMatch"], expected,
                "{method}: {query}"
            );
        }
    }
    store
        .put(&message("one", "The missing body contains needle."), 1)
        .unwrap();
    let response = execute(
        &store,
        "local.summaries",
        &json!({"accountId":ACCOUNT,"query":"-needle is:starred","asOf":AS_OF,"ids":["one"]}),
    )
    .unwrap();
    assert_eq!(response["summaries"][0]["matchesQuery"], false);
    assert_eq!(response["summaries"][0]["pendingEdit"], true);
    let response = execute(
        &store,
        "local.list",
        &json!({"accountId":ACCOUNT,"query":"-needle is:starred","asOf":AS_OF}),
    )
    .unwrap();
    assert!(ids(&response).is_empty());
    drop(store);
    std::fs::remove_dir_all(path).unwrap();
}
