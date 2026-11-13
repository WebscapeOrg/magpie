//! List prices for every model that writes a Point or picks its model, and the token usage each
//! provider reports, so a Point's details can say what its requests cost or would have cost at API
//! prices. Amounts are billionths of a dollar, the unit `spending.rs` keeps.
//!
//! Sources, read on 7 November 2026: Claude 5.5 from Anthropic's list prices (as `claude.rs`
//! charges them); GPT-6.1 Sol from OpenAI's "Introducing GPT-6.1 Sol" ($2 input, $0.10 cached
//! input, $10 output a million tokens); GPT-6 Astra ($10, $1, $50) and GPT-6 Luna ($0.10, $0.01,
//! $0.50) from published price lists that agree with each other, since openai.com/api/pricing
//! refuses automated reads; Gemini 4 Argon and Gemini 3.8 Flash from Google's Gemini API pricing
//! page, whose introductory prices double on the dates below. OpenAI charges no cache writes, and
//! OpenAI's and Google's thinking tokens are billed as output.
use serde_json::Value;

/// Tokens of one request, split the way providers bill them. The four counts never overlap.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(crate) struct Usage {
    pub(crate) fresh: u64,
    pub(crate) written: u64,
    pub(crate) read: u64,
    pub(crate) output: u64,
}

impl Usage {
    /// Every input token the request carried: fresh, written to the cache and read from it.
    pub(crate) fn input(&self) -> Option<u64> {
        self.fresh.checked_add(self.written)?.checked_add(self.read).filter(|n| *n <= super::context_tokens::MAX)
    }
}

fn count(usage: &Value, key: &str) -> Option<u64> {
    match usage.get(key) {
        Some(value) => value.as_u64(),
        None => Some(0),
    }
}

/// Claude's usage: `input_tokens` (required), cache writes and reads, and output, all separate.
pub(crate) fn anthropic(usage: &Value) -> Option<Usage> {
    let usage = Usage {
        fresh: usage["input_tokens"].as_u64()?,
        written: count(usage, "cache_creation_input_tokens")?,
        read: count(usage, "cache_read_input_tokens")?,
        output: count(usage, "output_tokens")?,
    };
    usage.input().map(|_| usage)
}

/// Codex's `turn.completed` usage: `input_tokens` includes the cached input, and `output_tokens`
/// includes the reasoning.
pub(crate) fn codex(usage: &Value) -> Option<Usage> {
    let input = usage["input_tokens"].as_u64()?;
    let read = count(usage, "cached_input_tokens")?;
    let written = count(usage, "cache_write_input_tokens")?;
    let usage = Usage { fresh: input.checked_sub(read)?.checked_sub(written)?, written, read, output: count(usage, "output_tokens")? };
    usage.input().map(|_| usage)
}

/// Gemini's `usageMetadata`: `promptTokenCount` includes the cached content, and thinking is
/// counted apart from the answer.
pub(crate) fn gemini(usage: &Value) -> Option<Usage> {
    let prompt = usage["promptTokenCount"].as_u64()?;
    let read = count(usage, "cachedContentTokenCount")?;
    let output = count(usage, "candidatesTokenCount")?.checked_add(count(usage, "thoughtsTokenCount")?)?;
    let usage = Usage { fresh: prompt.checked_sub(read)?, written: 0, read, output };
    usage.input().map(|_| usage)
}

/// Claude 5.5's list prices: Haiku $0.10/$0.50 a million input/output tokens, Sonnet $2/$10 and Opus
/// $4/$20, cache writes at 1.25 times input, reads at $0.01, $0.20 and $0.20.
pub(crate) fn claude(model: &str) -> Option<[u64; 4]> {
    match model {
        "haiku" | "claude-haiku-5-5" => Some([100, 125, 10, 500]),
        "sonnet" | "claude-sonnet-5-5" => Some([2_000, 2_500, 200, 10_000]),
        "opus" | "claude-opus-5-5" => Some([4_000, 5_000, 200, 20_000]),
        _ => None,
    }
}

/// The prices in effect on `day` ("YYYY-MM-DD") for fresh input, cache writes, cache reads and
/// output, in billionths of a dollar a token, with the prompt size above which they no longer apply.
fn table(model: &str, day: &str) -> Option<([u64; 4], Option<u64>)> {
    if let Some(prices) = claude(model) {
        return Some((prices, None));
    }
    Some(match model {
        "gpt-6-luna" => ([100, 100, 10, 500], Some(272_000)),
        "gpt-6.1-sol" => ([2_000, 2_000, 100, 10_000], Some(272_000)),
        "gpt-6-astra" => ([10_000, 10_000, 1_000, 50_000], Some(272_000)),
        "gemini-4-argon" if day < "2026-12-01" => ([2_000, 2_000, 100, 10_000], None),
        "gemini-4-argon" => ([4_000, 4_000, 200, 20_000], None),
        "gemini-3.8-flash" if day < "2027-01-01" => ([750, 750, 75, 3_750], None),
        "gemini-3.8-flash" => ([1_500, 1_500, 150, 7_500], None),
        _ => return None,
    })
}

/// What one request cost on `day` at the model's API list price, or None for a model without a
/// known price or a prompt beyond the size its price covers. Haiku 5.5 costs five times as much
/// above 100,000 prompt tokens.
pub(crate) fn cost_on(model: &str, usage: &Usage, day: &str) -> Option<u64> {
    let (prices, limit) = table(model, day)?;
    let prompt = usage.input()?;
    if limit.is_some_and(|limit| prompt > limit) {
        return None;
    }
    let step = if matches!(model, "haiku" | "claude-haiku-5-5") && prompt > 100_000 { 5 } else { 1 };
    let tokens = [usage.fresh, usage.written, usage.read, usage.output];
    Some(tokens.iter().zip(prices).fold(0u64, |total, (tokens, price)| total.saturating_add(tokens.saturating_mul(price))).saturating_mul(step))
}

pub(crate) fn cost(model: &str, usage: &Usage) -> Option<u64> {
    cost_on(model, usage, &chrono::Utc::now().format("%Y-%m-%d").to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn each_provider_splits_cached_input_without_counting_it_twice() {
        assert_eq!(anthropic(&json!({"input_tokens":100,"cache_creation_input_tokens":200,"cache_read_input_tokens":300,"output_tokens":40})), Some(Usage { fresh: 100, written: 200, read: 300, output: 40 }));
        assert_eq!(codex(&json!({"input_tokens":1000,"cached_input_tokens":800,"output_tokens":50,"reasoning_output_tokens":30})), Some(Usage { fresh: 200, written: 0, read: 800, output: 50 }));
        assert_eq!(gemini(&json!({"promptTokenCount":1000,"cachedContentTokenCount":600,"candidatesTokenCount":20,"thoughtsTokenCount":80})), Some(Usage { fresh: 400, written: 0, read: 600, output: 100 }));
        assert_eq!(gemini(&json!({"promptTokenCount":10})), Some(Usage { fresh: 10, ..Usage::default() }));
        for broken in [json!({}), json!({"input_tokens":"1"}), json!({"input_tokens":1,"output_tokens":-1})] {
            assert_eq!(anthropic(&broken), None);
            assert_eq!(codex(&broken), None);
        }
        assert_eq!(codex(&json!({"input_tokens":5,"cached_input_tokens":6})), None);
        assert_eq!(gemini(&json!({"promptTokenCount":5,"cachedContentTokenCount":6})), None);
        assert_eq!(anthropic(&json!({"input_tokens":super::super::context_tokens::MAX,"cache_read_input_tokens":1})), None);
    }

    #[test]
    fn requests_are_priced_at_each_models_list_price_on_the_day() {
        let million = |fresh, read, output| Usage { fresh, written: 0, read, output };
        assert_eq!(cost_on("claude-sonnet-5-5", &million(1_000_000, 0, 1_000_000), "2026-11-07"), Some(12_000_000_000));
        assert_eq!(cost_on("opus", &Usage { written: 1_000_000, ..Usage::default() }, "2026-11-07"), Some(5_000_000_000));
        assert_eq!(cost_on("haiku", &million(50_000, 0, 10_000), "2026-11-07"), Some(10_000_000));
        assert_eq!(cost_on("claude-haiku-5-5", &million(200_000, 0, 0), "2026-11-07"), Some(100_000_000), "Haiku's long-prompt price is five times");
        assert_eq!(cost_on("gpt-6.1-sol", &million(100_000, 100_000, 10_000), "2026-11-07"), Some(310_000_000));
        assert_eq!(cost_on("gpt-6-astra", &million(1_000, 0, 1_000), "2026-11-07"), Some(60_000_000));
        assert_eq!(cost_on("gpt-6-luna", &million(300_000, 0, 0), "2026-11-07"), None, "beyond 272,000 tokens OpenAI charges more than this table knows");
        assert_eq!(cost_on("gemini-4-argon", &million(1_000_000, 0, 0), "2026-11-30"), Some(2_000_000_000));
        assert_eq!(cost_on("gemini-4-argon", &million(1_000_000, 0, 0), "2026-12-01"), Some(4_000_000_000));
        assert_eq!(cost_on("gemini-3.8-flash", &million(0, 1_000_000, 1_000_000), "2026-12-31"), Some(3_825_000_000));
        assert_eq!(cost_on("gemini-3.8-flash", &million(0, 1_000_000, 1_000_000), "2027-01-01"), Some(7_650_000_000));
        assert_eq!(cost_on("gpt-7", &million(1, 0, 0), "2026-11-07"), None);
        assert_eq!(cost_on("opus", &million(u64::MAX / 2, 0, u64::MAX / 2), "2026-11-07"), None, "a count beyond any real request is not priced");
    }
}
