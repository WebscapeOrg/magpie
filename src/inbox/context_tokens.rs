//! What one Point's writing requests used and cost: the input tokens each provider reported, the
//! models and efforts that answered, and the cost of those requests at API list prices
//! (`prices.rs`), whether or not they were billed that way.
use super::prices::{self, Usage};
use serde_json::{Value, json};
use std::{cell::RefCell, future::Future};

pub(crate) const MAX: u64 = 9_007_199_254_740_991;
/// The most distinct model and effort pairs a Point's details keep.
pub(crate) const PASSES: usize = 6;
tokio::task_local! { static TOTAL: RefCell<Total>; }

#[derive(Default)]
struct Total {
    tokens: u64,
    reported: bool,
    incomplete: bool,
    cost: u64,
    priced: bool,
    unpriced: bool,
    passes: Vec<(String, String)>,
}

/// One writing request answered by `model` at `effort`, with the usage it reported, or None when it
/// reported none, which leaves both its tokens and its cost unknown.
pub(crate) fn record(model: &str, effort: &str, usage: Option<Usage>) {
    let _ = TOTAL.try_with(|total| {
        let mut total = total.borrow_mut();
        if let Some(model) = super::point_details::model(&json!(model)) && super::point_details::effort(effort) {
            let pass = (model.to_owned(), effort.to_owned());
            if !total.passes.contains(&pass) && total.passes.len() < PASSES { total.passes.push(pass); }
        }
        match usage.and_then(|usage| usage.input()).and_then(|tokens| total.tokens.checked_add(tokens)).filter(|n| *n <= MAX) {
            Some(tokens) => { total.tokens = tokens; total.reported = true; }
            None => total.incomplete = true,
        }
        match usage.and_then(|usage| prices::cost(model, &usage)).and_then(|cost| total.cost.checked_add(cost)).filter(|n| *n <= MAX) {
            Some(cost) => { total.cost = cost; total.priced = true; }
            None => total.unpriced = true,
        }
    });
}

/// One command-line turn: usage it reported counts, whatever the outcome; without usage, a turn
/// that was refused because the subscription is out was not billed, one that failed may have been,
/// and one that finished answered without saying what it used.
pub(crate) fn turn(model: &str, effort: &str, usage: Option<Usage>, paused: bool, failed: bool) {
    match usage {
        Some(_) => record(model, effort, usage),
        None if paused => {}
        None if failed => unreported(),
        None => record(model, effort, None),
    }
}

/// A request made on this Point's behalf whose usage was not passed on, such as a retry inside
/// The main machine's subscription router: the totals become lower bounds.
pub(crate) fn unreported() {
    let _ = TOTAL.try_with(|total| {
        let mut total = total.borrow_mut();
        total.incomplete = true;
        total.unpriced = true;
    });
}

pub(crate) async fn measure<T>(work: impl Future<Output = T>) -> (T, Value) {
    TOTAL.scope(RefCell::new(Total::default()), async {
        let result = work.await;
        let details = TOTAL.with(|total| {
            let total = total.borrow();
            let mut details = json!({});
            if total.reported {
                details["contextTokens"] = json!(total.tokens);
                details["contextTokensPartial"] = json!(total.incomplete);
            }
            if total.priced {
                details["costNanos"] = json!(total.cost);
                details["costPartial"] = json!(total.unpriced);
            }
            if !total.passes.is_empty() {
                details["passes"] = json!(total.passes.iter().map(|(model, effort)| json!({"model":model,"effort":effort})).collect::<Vec<_>>());
            }
            details
        });
        (result, details)
    }).await
}

#[cfg(test)]
mod tests {
    use super::*;

    fn claude(fresh: u64, written: u64, read: u64, output: u64) -> Option<Usage> { Some(Usage { fresh, written, read, output }) }

    #[tokio::test]
    async fn writing_passes_include_cached_context_and_are_priced_at_their_own_models() {
        let (_, details) = measure(async {
            record("claude-sonnet-5-5", "low", claude(100, 200, 300, 999));
            record("claude-haiku-5-5", "low", claude(50, 0, 600, 0));
            record("claude-sonnet-5-5", "low", claude(0, 0, 0, 1));
        }).await;
        let sonnet = 100 * 2_000 + 200 * 2_500 + 300 * 200 + 999 * 10_000 + 10_000;
        let haiku = 50 * 100 + 600 * 10;
        assert_eq!(details, json!({"contextTokens":1250,"contextTokensPartial":false,"costNanos":sonnet + haiku,"costPartial":false,
            "passes":[{"model":"claude-sonnet-5-5","effort":"low"},{"model":"claude-haiku-5-5","effort":"low"}]}));
        let (_, partial) = measure(async { record("gpt-6.1-sol", "low", None); record("gpt-6.1-sol", "low", claude(90, 0, 0, 10)); }).await;
        assert_eq!(partial, json!({"contextTokens":90,"contextTokensPartial":true,"costNanos":90 * 2_000 + 10 * 10_000,"costPartial":true,"passes":[{"model":"gpt-6.1-sol","effort":"low"}]}));
        assert_eq!(measure(async { record("opus", "low", None); }).await.1, json!({"passes":[{"model":"opus","effort":"low"}]}));
        assert_eq!(measure(async {}).await.1, json!({}));
        let (_, routed) = measure(async { record("sonnet", "low", claude(10, 0, 0, 0)); unreported(); }).await;
        assert_eq!((routed["contextTokensPartial"].clone(), routed["costPartial"].clone()), (json!(true), json!(true)));
    }

    #[tokio::test]
    async fn only_turns_that_answered_or_were_billed_count() {
        let (_, details) = measure(async {
            turn("sonnet", "low", None, true, true);
            turn("gpt-6.1-sol", "low", None, false, true);
            turn("gemini-4-argon", "low", claude(10, 0, 0, 1), false, false);
        }).await;
        assert_eq!(details["passes"], json!([{"model":"gemini-4-argon","effort":"low"}]), "a refused or failed turn names no model");
        assert_eq!(details["costPartial"], true, "a failed turn may have been billed");
        let (_, refused) = measure(async { turn("sonnet", "low", None, true, false); turn("haiku", "low", claude(10, 0, 0, 0), false, false); }).await;
        assert_eq!((refused["costPartial"].clone(), refused["contextTokensPartial"].clone()), (json!(false), json!(false)), "a turn refused as out was not billed");
        let (_, silent) = measure(async { turn("opus", "low", None, false, false); }).await;
        assert_eq!(silent, json!({"passes":[{"model":"opus","effort":"low"}]}));
    }

    #[tokio::test]
    async fn an_unknown_model_or_effort_is_counted_but_never_named_or_priced() {
        let (_, details) = measure(async { record("<img>", "SECRET", claude(10, 0, 0, 5)); }).await;
        assert_eq!(details, json!({"contextTokens":10,"contextTokensPartial":false}));
        let (_, many) = measure(async {
            for model in ["haiku", "sonnet", "opus", "gpt-6-luna", "gpt-6.1-sol", "gpt-6-astra", "gemini-4-argon"] { record(model, "low", None); }
        }).await;
        assert_eq!(many["passes"].as_array().unwrap().len(), PASSES);
    }

    #[tokio::test]
    async fn concurrent_messages_do_not_share_their_totals() {
        let (first, second) = tokio::join!(measure(async { record("haiku", "low", claude(10, 0, 0, 0)); tokio::task::yield_now().await; record("haiku", "low", claude(20, 0, 0, 0)); }), measure(async { record("opus", "low", claude(7, 0, 0, 0)); }));
        assert_eq!(first.1["contextTokens"], 30);
        assert_eq!(first.1["costNanos"], 3_000);
        assert_eq!(second.1["contextTokens"], 7);
        assert_eq!(second.1["passes"], json!([{"model":"opus","effort":"low"}]));
        let (_, outer) = measure(async {
            record("haiku", "low", claude(5, 0, 0, 0));
            let (_, inner) = measure(async { record("haiku", "low", claude(99, 0, 0, 0)); }).await;
            assert_eq!(inner["contextTokens"], 99);
            record("haiku", "low", claude(6, 0, 0, 0));
        }).await;
        assert_eq!(outer["contextTokens"], 11);
        record("haiku", "low", claude(500, 0, 0, 0));
        assert_eq!(measure(async {}).await.1, json!({}));
    }

    #[test]
    fn malformed_or_unreported_usage_is_not_a_zero_or_an_estimate() {
        for value in [json!({}), json!({"input_tokens":"100"}), json!({"input_tokens":-1}), json!({"input_tokens":1.5}), json!({"input_tokens":1,"cache_read_input_tokens":null}), json!({"input_tokens":MAX,"cache_creation_input_tokens":1})] {
            assert_eq!(prices::anthropic(&value).and_then(|usage| usage.input()), None);
        }
        assert_eq!(prices::anthropic(&json!({"input_tokens":0})).and_then(|usage| usage.input()), Some(0));
    }
}
