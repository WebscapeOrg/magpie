use super::*;
use crate::mail::tests::{account_fixture, isolated};

/// 2026-11-03 10:20 UTC, which is 12:20 in Johannesburg and 15:50 in Kolkata.
const AT: i64 = 1_793_701_200_000;
const HOUR: i64 = 3_600_000;
const DAY: i64 = 24 * HOUR;

fn fixture() -> crate::mail::tests::AccountFixture {
    account_fixture(json!({"version":1,"accounts":[]}))
}

fn period(totals: &Value, name: &str) -> Vec<u64> {
    FEATURES.iter().map(|feature| totals["periods"][name][*feature].as_u64().unwrap()).collect()
}

#[test]
fn spending_is_summed_by_feature_from_each_periods_start() {
    if isolated() {
        return;
    }
    let _fixture = fixture();
    add("descriptions", 100, AT).unwrap();
    add("descriptions", 50, AT + 60_000).unwrap();
    add("pictures", 13_000_000, AT - 2 * DAY).unwrap();
    add("assistant", 7, AT - 20 * DAY).unwrap();
    let starts = [("day".to_owned(), AT - HOUR), ("week".to_owned(), AT - 3 * DAY), ("month".to_owned(), AT - 25 * DAY)];
    let totals = totals(&starts).unwrap();
    assert_eq!(period(&totals, "day"), vec![150, 0, 0]);
    assert_eq!(period(&totals, "week"), vec![150, 0, 13_000_000]);
    assert_eq!(period(&totals, "month"), vec![150, 7, 13_000_000]);
    assert_eq!(totals["since"], json!(AT), "counting began with the first amount written");
}

#[test]
fn a_quarter_hour_belongs_to_the_day_it_starts_in_a_half_hour_time_zone() {
    if isolated() {
        return;
    }
    let _fixture = fixture();
    // Midnight in Kolkata (UTC+5:30) is 18:30 UTC. Spending at 18:29 and 18:31 UTC falls either side.
    let midnight = AT - AT.rem_euclid(DAY) + 18 * HOUR + 30 * 60_000;
    add("descriptions", 1, midnight - 60_000).unwrap();
    add("descriptions", 10, midnight + 60_000).unwrap();
    let totals = totals(&[("day".to_owned(), midnight)]).unwrap();
    assert_eq!(totals["periods"]["day"]["descriptions"], json!(10));
}

#[test]
fn spending_older_than_two_months_is_forgotten_when_more_is_counted() {
    if isolated() {
        return;
    }
    let _fixture = fixture();
    add("pictures", 5, AT - 70 * DAY).unwrap();
    add("pictures", 6, AT).unwrap();
    let saved = store::read(&name()).unwrap().unwrap();
    assert_eq!(saved["buckets"].as_object().unwrap().len(), 1);
    // Only amounts, features and times are kept.
    let text = saved.to_string();
    assert!(!text.contains('@') && !text.contains("sk-"));
}

#[test]
fn spending_asks_for_three_recent_period_starts() {
    if isolated() {
        return;
    }
    let _fixture = fixture();
    let at = now();
    let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
    let ask = |params: Value| runtime.block_on(spending(&params));
    let good = json!({"day":at - HOUR,"week":at - 3 * DAY,"month":at - 20 * DAY});
    let answer = ask(good).unwrap();
    assert_eq!(answer["periods"]["month"]["pictures"], json!(0));
    assert_eq!(answer["since"], Value::Null, "nothing counted yet");
    for bad in [
        json!({"day":at,"week":at}),
        json!({"day":at,"week":at,"month":at,"extra":1}),
        json!({"day":at + DAY,"week":at,"month":at}),
        json!({"day":at,"week":at,"month":at - 40 * DAY}),
        json!({"day":"today","week":at,"month":at}),
        json!([]),
    ] {
        assert_eq!(ask(bad).unwrap_err(), "invalid_params");
    }
}

#[test]
fn a_reservation_counts_until_its_cost_replaces_it_in_the_quarter_hour_it_was_sent() {
    if isolated() {
        return;
    }
    let _fixture = fixture();
    let day = [("day".to_owned(), AT - HOUR)];
    open("p-1", "pictures", 70_000_000, AT).unwrap();
    open("p-1", "pictures", 70_000_000, AT).unwrap();
    assert_eq!(totals(&day).unwrap()["periods"]["day"]["pictures"], json!(70_000_000), "a request is reserved once");
    // The answer comes in the next quarter hour; the cost replaces the reservation where it was counted.
    close("p-1", "pictures", 14_200_000, true, AT + 20 * 60_000).unwrap();
    let saved = store::read(&name()).unwrap().unwrap();
    assert_eq!(saved["buckets"].as_object().unwrap().len(), 1);
    assert_eq!(saved["open"], json!({}));
    assert_eq!(totals(&day).unwrap()["periods"]["day"]["pictures"], json!(14_200_000));
    // A request iOS ended never settles, and stays counted at its reservation.
    open("a-1", "assistant", 900, AT).unwrap();
    // A request whose reservation was never written is counted when its cost comes.
    close("a-2", "assistant", 40, false, AT + 60_000).unwrap();
    assert_eq!(totals(&day).unwrap()["periods"]["day"]["assistant"], json!(940));
    // After a day the reservation is no longer open, and it stays counted.
    add("pictures", 1, AT + OPEN_KEEP + 1).unwrap();
    assert_eq!(store::read(&name()).unwrap().unwrap()["open"], json!({}));
    assert_eq!(totals(&day).unwrap()["periods"]["day"]["assistant"], json!(940));
    // Settling it then, or settling a request a second time, does not count it again.
    close("a-1", "assistant", 40, true, AT + OPEN_KEEP + 2).unwrap();
    close("p-1", "pictures", 14_200_000, true, AT + OPEN_KEEP + 3).unwrap();
    let after = totals(&[("day".to_owned(), AT - HOUR)]).unwrap();
    assert_eq!((after["periods"]["day"]["assistant"].clone(), after["periods"]["day"]["pictures"].clone()), (json!(940), json!(14_200_001)));
}

#[test]
fn a_reservation_dropped_when_the_clock_goes_back_is_counted_once() {
    if isolated() {
        return;
    }
    let _fixture = fixture();
    open("p-ahead", "pictures", 70_000_000, AT + HOUR).unwrap();
    // The clock went back an hour before the answer came: the entry is ahead of it and dropped.
    close("p-ahead", "pictures", 14_200_000, true, AT).unwrap();
    assert_eq!(store::read(&name()).unwrap().unwrap()["open"], json!({}));
    assert_eq!(totals(&[("day".to_owned(), AT - HOUR)]).unwrap()["periods"]["day"]["pictures"], json!(70_000_000));
}

#[test]
fn malformed_or_surplus_reservations_are_dropped_and_stay_counted() {
    if isolated() {
        return;
    }
    let _fixture = fixture();
    store::write(
        &name(),
        &json!({"since":AT,"buckets":{},"open":{
            "feature":{"feature":"messages","amount":5,"at":AT},
            "amount":{"feature":"pictures","amount":"5","at":AT},
            "ahead":{"feature":"pictures","amount":5,"at":AT + HOUR},
            "x".repeat(ID_LIMIT + 1):{"feature":"pictures","amount":5,"at":AT}}}),
    )
    .unwrap();
    open("kept", "pictures", 5, AT).unwrap();
    let saved = store::read(&name()).unwrap().unwrap();
    assert_eq!(saved["open"].as_object().unwrap().keys().collect::<Vec<_>>(), ["kept"]);
    for n in 0..OPEN_LIMIT as i64 + 6 {
        open(&format!("r-{n}"), "pictures", 1, AT + n).unwrap();
    }
    let saved = store::read(&name()).unwrap().unwrap();
    assert_eq!(saved["open"].as_object().unwrap().len(), OPEN_LIMIT, "the newest are kept open");
    assert!(saved["open"].get("r-0").is_none());
    assert_eq!(totals(&[("day".to_owned(), AT - HOUR)]).unwrap()["periods"]["day"]["pictures"], json!(5 + OPEN_LIMIT as u64 + 6));
    assert_eq!(open("", "pictures", 1, AT), Err("invalid_params"));
}

#[test]
fn an_unknown_feature_or_nothing_spent_is_not_counted() {
    if isolated() {
        return;
    }
    let _fixture = fixture();
    let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
    runtime.block_on(record("descriptions", 0));
    runtime.block_on(record("messages", 9));
    assert!(store::read(&name()).unwrap().is_none());
    runtime.block_on(record("assistant", 9));
    assert!(store::read(&name()).unwrap().unwrap()["since"].as_i64().is_some());
}
