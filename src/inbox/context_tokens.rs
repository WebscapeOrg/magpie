use serde_json::{Value, json};
use std::{cell::RefCell, future::Future};

pub(crate) const MAX: u64 = 9_007_199_254_740_991;
tokio::task_local! { static TOTAL: RefCell<Total>; }

#[derive(Default)]
struct Total {
    tokens: u64,
    reported: bool,
    incomplete: bool,
}

pub(crate) fn input(usage: &Value) -> Option<u64> {
    let mut total = usage["input_tokens"].as_u64().filter(|n| *n <= MAX)?;
    for key in ["cache_creation_input_tokens", "cache_read_input_tokens"] {
        let count = match usage.get(key) { Some(value) => value.as_u64()?, None => 0 };
        total = total.checked_add(count).filter(|n| *n <= MAX)?;
    }
    Some(total)
}

pub(crate) fn record(tokens: Option<u64>) {
    let _ = TOTAL.try_with(|total| {
        let mut total = total.borrow_mut();
        match tokens.and_then(|tokens| total.tokens.checked_add(tokens)).filter(|n| *n <= MAX) {
            Some(tokens) => { total.tokens = tokens; total.reported = true; }
            None => total.incomplete = true,
        }
    });
}

pub(crate) async fn measure<T>(work: impl Future<Output = T>) -> (T, Value) {
    TOTAL.scope(RefCell::new(Total::default()), async {
        let result = work.await;
        let details = TOTAL.with(|total| {
            let total = total.borrow();
            if !total.reported { return json!({}); }
            json!({"contextTokens":total.tokens,"contextTokensPartial":total.incomplete})
        });
        (result, details)
    }).await
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn writing_passes_include_cached_context_and_keep_unknown_requests_explicit() {
        let (_, details) = measure(async {
            record(input(&json!({"input_tokens":100,"cache_creation_input_tokens":200,"cache_read_input_tokens":300,"output_tokens":999})));
            record(input(&json!({"input_tokens":50,"cache_read_input_tokens":600})));
        }).await;
        assert_eq!(details, json!({"contextTokens":1250,"contextTokensPartial":false}));
        let (_, partial) = measure(async { record(None); record(Some(90)); }).await;
        assert_eq!(partial, json!({"contextTokens":90,"contextTokensPartial":true}));
        assert_eq!(measure(async { record(None); }).await.1, json!({}));
        assert_eq!(measure(async {}).await.1, json!({}));
    }

    #[tokio::test]
    async fn concurrent_messages_do_not_share_their_token_counts() {
        let (first, second) = tokio::join!(measure(async { record(Some(10)); tokio::task::yield_now().await; record(Some(20)); }), measure(async { record(Some(7)); }));
        assert_eq!(first.1["contextTokens"], 30);
        assert_eq!(second.1["contextTokens"], 7);
        let (_, outer) = measure(async {
            record(Some(5));
            let (_, inner) = measure(async { record(Some(99)); }).await;
            assert_eq!(inner["contextTokens"], 99);
            record(Some(6));
        }).await;
        assert_eq!(outer["contextTokens"], 11);
        record(Some(500));
        assert_eq!(measure(async {}).await.1, json!({}));
    }

    #[test]
    fn malformed_or_unreported_usage_is_not_a_zero_or_an_estimate() {
        for value in [json!({}), json!({"input_tokens":"100"}), json!({"input_tokens":-1}), json!({"input_tokens":1.5}), json!({"input_tokens":1,"cache_read_input_tokens":null}), json!({"input_tokens":MAX,"cache_creation_input_tokens":1})] {
            assert_eq!(input(&value), None);
        }
        assert_eq!(input(&json!({"input_tokens":0})), Some(0));
    }
}
