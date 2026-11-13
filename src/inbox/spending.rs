//! What Magpie's paid AI requests cost, by feature and quarter hour, for the spending page on every device.
//!
//! Invariants:
//! - Amounts are estimates in billionths of a dollar, worked out from the usage each provider
//!   reports at list prices. A request with a reservation (a picture, an Ask Magpie request) is
//!   counted at its reservation when it is sent and corrected to its cost when the answer comes, so
//!   one cut off or ended with the app stays counted at its reservation, as the daily limits count
//!   it. They are not the provider's bill.
//! - Only features, amounts, quarter hours and the opaque ids of requests under way are kept:
//!   never a message, an address or a key.
//! - Quarter hours start at whole multiples of 15 minutes since 1970 (UTC), so the start of a day,
//!   week or month in any time zone falls on a boundary and every quarter hour belongs to one period.
//! - A failure to count never fails the request that was counted.
use super::{now, store};
use serde_json::{Map, Value, json};

/// The features whose spending is counted: AI descriptions, Ask Magpie and sender pictures.
pub(crate) const FEATURES: [&str; 3] = ["descriptions", "assistant", "pictures"];
const QUARTER_HOUR: i64 = 15 * 60_000;
/// Long enough for this month and last month's last days in every time zone.
const KEEP: i64 = 62 * 86_400_000;
/// Its own lock, so counting never holds up or waits for the changes made under the store's lock.
const LOCK: &str = ".spending.lock";
/// How long a reservation waits for its request's cost. One never settled stays counted.
const OPEN_KEEP: i64 = 86_400_000;
/// The most reservations kept open; the oldest beyond it stay counted at their reservation.
const OPEN_LIMIT: usize = 64;
/// The longest request id kept, so a stored id cannot grow the file.
const ID_LIMIT: usize = 160;
/// The longest a period may reach back: a month and a day, so a time zone ahead of UTC still fits.
const LONGEST_PERIOD: i64 = 32 * 86_400_000;

fn name() -> String {
    store::key(&["spending"])
}

fn buckets(saved: &mut Value) -> Map<String, Value> {
    match saved.get_mut("buckets").map(Value::take) {
        Some(Value::Object(map)) => map,
        _ => Map::new(),
    }
}

/// The saved ledger made sound: an object with `since`, buckets newer than `KEEP` and well-formed
/// open reservations newer than `OPEN_KEEP`, at most `OPEN_LIMIT` of them.
fn tidy(saved: &mut Value, at: i64) {
    if !saved.is_object() {
        *saved = json!({});
    }
    if saved["since"].as_i64().is_none() {
        saved["since"] = json!(at);
    }
    let mut kept = buckets(saved);
    kept.retain(|key, bucket| key.parse::<i64>().is_ok_and(|start| start > at - KEEP) && bucket.is_object());
    saved["buckets"] = Value::Object(kept);
    let mut open: Vec<(String, Value)> = match saved.get_mut("open").map(Value::take) {
        Some(Value::Object(map)) => map.into_iter().collect(),
        _ => Vec::new(),
    };
    open.retain(|(id, entry)| {
        id.len() <= ID_LIMIT
            && entry["feature"].as_str().is_some_and(|feature| FEATURES.contains(&feature))
            && entry["amount"].as_u64().is_some()
            && entry["at"].as_i64().is_some_and(|start| start > at - OPEN_KEEP && start <= at + 60_000)
    });
    open.sort_by_key(|(_, entry)| std::cmp::Reverse(entry["at"].as_i64().unwrap_or(0)));
    open.truncate(OPEN_LIMIT);
    saved["open"] = Value::Object(open.into_iter().collect());
}

/// Adds `amount` to `feature` in the quarter hour of `at`, after taking `less` away from it.
fn change_bucket(saved: &mut Value, feature: &str, at: i64, less: u64, amount: u64) {
    let start = at - at.rem_euclid(QUARTER_HOUR);
    let bucket = &mut saved["buckets"][start.to_string()];
    if !bucket.is_object() {
        *bucket = json!({});
    }
    let counted = bucket[feature].as_u64().unwrap_or(0).saturating_sub(less);
    bucket[feature] = json!(counted.saturating_add(amount));
}

/// Adds `amount` billionths of a dollar to `feature` in the quarter hour of `at`, and forgets
/// quarter hours older than `KEEP`. Blocks: call it off the async threads. On Linux it counts the
/// picker's decisions; sender pictures use `reserve` and `settle`.
fn add(feature: &str, amount: u64, at: i64) -> Result<(), &'static str> {
    store::update_waiting(LOCK, &name(), |saved| {
        tidy(saved, at);
        change_bucket(saved, feature, at, 0, amount);
        Ok(())
    })
}

/// Counts request `id` at its reservation before it is sent. A request already open is not
/// counted again. Blocks.
fn open(id: &str, feature: &str, amount: u64, at: i64) -> Result<(), &'static str> {
    if id.is_empty() || id.len() > ID_LIMIT {
        return Err("invalid_params");
    }
    store::update_waiting(LOCK, &name(), |saved| {
        tidy(saved, at);
        if saved["open"].get(id).is_some() {
            return Ok(());
        }
        change_bucket(saved, feature, at, 0, amount);
        saved["open"][id] = json!({"feature":feature,"amount":amount,"at":at});
        // Keeps the newest `OPEN_LIMIT`, this one among them.
        tidy(saved, at);
        Ok(())
    })
}

/// Replaces request `id`'s reservation with what it cost, in the quarter hour it was sent. When
/// its open entry is gone (older than a day, ahead of the clock, or already settled), a request
/// that was `reserved` stays counted at its reservation, which went into a bucket when it was
/// written; one whose reservation was never written is counted now. Blocks.
fn close(id: &str, feature: &str, cost: u64, reserved: bool, at: i64) -> Result<(), &'static str> {
    store::update_waiting(LOCK, &name(), |saved| {
        tidy(saved, at);
        let entry = saved["open"].as_object_mut().and_then(|open| open.remove(id));
        match entry {
            Some(entry) if entry["feature"] == feature => {
                let sent = entry["at"].as_i64().unwrap_or(at);
                change_bucket(saved, feature, sent, entry["amount"].as_u64().unwrap_or(0), cost);
            }
            _ if reserved => {}
            _ => change_bucket(saved, feature, at, 0, cost),
        }
        Ok(())
    })
}

/// Counts request `id` of `feature` at `amount` before it is sent; `settle` corrects it. Says
/// whether the reservation was written; a failure to count is ignored, so it never stops the
/// request.
pub(crate) async fn reserve(id: String, feature: &'static str, amount: u64) -> bool {
    if !FEATURES.contains(&feature) {
        return false;
    }
    let at = now();
    matches!(tokio::task::spawn_blocking(move || open(&id, feature, amount, at)).await, Ok(Ok(())))
}

/// Corrects request `id`'s reservation to what it cost; `reserved` is what `reserve` said. Call it
/// once per request.
pub(crate) async fn settle(id: String, feature: &'static str, cost: u64, reserved: bool) {
    if !FEATURES.contains(&feature) {
        return;
    }
    let at = now();
    let _ = tokio::task::spawn_blocking(move || close(&id, feature, cost, reserved, at)).await;
}

/// Counts what one request cost. A failure to count is ignored, so it never fails the request.
pub(crate) async fn record(feature: &'static str, amount: u64) {
    if amount == 0 || !FEATURES.contains(&feature) {
        return;
    }
    let at = now();
    let _ = tokio::task::spawn_blocking(move || add(feature, amount, at)).await;
}

/// The spending of each feature since each named start, and since when Magpie has counted.
/// Blocks: call it off the async threads.
fn totals(starts: &[(String, i64)]) -> Result<Value, &'static str> {
    let saved = store::read(&name())?.unwrap_or(json!({}));
    let mut periods = Map::new();
    for (period, start) in starts {
        let mut sums: Map<String, Value> = FEATURES.iter().map(|feature| ((*feature).to_owned(), json!(0u64))).collect();
        for (key, bucket) in saved["buckets"].as_object().into_iter().flatten() {
            if !key.parse::<i64>().is_ok_and(|bucket| bucket >= *start) {
                continue;
            }
            for feature in FEATURES {
                let amount = bucket[feature].as_u64().unwrap_or(0);
                let sum = sums[feature].as_u64().unwrap_or(0).saturating_add(amount);
                sums.insert(feature.to_owned(), json!(sum));
            }
        }
        periods.insert(period.clone(), Value::Object(sums));
    }
    Ok(json!({"periods": periods, "since": saved["since"].as_i64()}))
}

/// `ai.spending`: the app names when today, this week and this month started in its time zone.
pub(crate) async fn spending(params: &Value) -> Result<Value, &'static str> {
    let fields = params.as_object().filter(|fields| fields.len() == 3).ok_or("invalid_params")?;
    let at = now();
    let mut starts = Vec::new();
    for period in ["day", "week", "month"] {
        let start = fields
            .get(period)
            .and_then(Value::as_i64)
            .filter(|start| *start <= at && *start >= at - LONGEST_PERIOD)
            .ok_or("invalid_params")?;
        starts.push((period.to_owned(), start));
    }
    tokio::task::spawn_blocking(move || totals(&starts))
        .await
        .map_err(|_| "inbox_storage_unavailable")?
}

#[cfg(test)]
#[path = "spending_tests.rs"]
mod tests;
