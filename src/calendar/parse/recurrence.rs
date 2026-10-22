use super::{dates, ics, sort};
use chrono::{Datelike, Duration};
use serde_json::{Value, json};
use std::collections::{HashMap, HashSet};
type Result<T> = std::result::Result<T, &'static str>;
fn ms(event: &Value) -> i64 {
    event["start"]["ms"].as_i64().unwrap_or(0)
}
fn in_range(event: &Value, start: i64, end: i64) -> bool {
    ms(event) < end && event["end"]["ms"].as_i64().unwrap_or(ms(event) + 1) > start
}
fn listed(value: i32, text: &str) -> bool {
    text.split(',')
        .any(|s| s.parse::<i32>().ok() == Some(value))
}
fn by_day(day: chrono::NaiveDate, text: &str) -> bool {
    text.split(',')
        .filter_map(dates::weekday)
        .any(|(ordinal, weekday)| {
            if day.weekday().num_days_from_sunday() != weekday {
                return false;
            }
            ordinal == 0
                || ordinal == (day.day() as i32 - 1) / 7 + 1
                || ordinal
                    == -((dates::month_days(day.year(), day.month()) - day.day()) as i32 / 7) - 1
        })
}
fn week(day: chrono::NaiveDate) -> i64 {
    (day.signed_duration_since(chrono::NaiveDate::from_ymd_opt(1970, 1, 1).unwrap())
        .num_days()
        - day.weekday().num_days_from_monday() as i64)
        .div_euclid(7)
}
fn starts(event: &Value, from: i64, to: i64) -> Result<Vec<i64>> {
    let parts = dates::rules(event["recurrenceRule"].as_str().unwrap_or(""));
    let frequency = parts.get("FREQ").map(String::as_str).unwrap_or("");
    if !matches!(frequency, "DAILY" | "WEEKLY" | "MONTHLY" | "YEARLY") {
        return Err("calendar_recurrence_unsupported");
    }
    let interval = parts
        .get("INTERVAL")
        .and_then(|s| s.parse::<i64>().ok())
        .unwrap_or(1)
        .max(1);
    let count = parts
        .get("COUNT")
        .and_then(|s| s.parse::<usize>().ok())
        .unwrap_or(0);
    let until = parts
        .get("UNTIL")
        .and_then(|s| {
            dates::date(s).map(|d| {
                if s.ends_with('Z') {
                    d.and_utc().timestamp_millis()
                } else {
                    dates::local(d).unwrap_or(0)
                }
            })
        })
        .unwrap_or(0);
    let property = ics::property(event["source"]["dtstart"].as_str().unwrap_or(""))
        .ok_or("calendar_invalid_response")?;
    let base = dates::date(&property.value).ok_or("calendar_invalid_response")?;
    let zones = event["source"]["timezones"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(Value::as_str)
        .collect::<Vec<_>>()
        .join("\r\n");
    let calendar = ics::parse(&format!("BEGIN:VCALENDAR\r\n{zones}\r\nEND:VCALENDAR"))?;
    let mut current = base;
    if count == 0 {
        let skip = from
            .saturating_sub(172_800_000)
            .saturating_sub(base.and_utc().timestamp_millis())
            .div_euclid(86_400_000)
            .max(0);
        current = current
            .checked_add_signed(Duration::try_days(skip).ok_or("calendar_invalid_response")?)
            .ok_or("calendar_invalid_response")?;
    }
    let mut out = Vec::new();
    let mut emitted = 0;
    for _ in 0..10000 {
        if current.and_utc().timestamp_millis() >= to.saturating_add(86_400_000) {
            return Ok(out);
        }
        let delta = current.date().signed_duration_since(base.date()).num_days();
        let month_delta = (current.year() - base.year()) as i64 * 12 + current.month() as i64
            - base.month() as i64;
        let year_delta = (current.year() - base.year()) as i64;
        let month_day = parts
            .get("BYMONTHDAY")
            .map(|s| listed(current.day() as i32, s))
            .unwrap_or_else(|| {
                parts
                    .get("BYDAY")
                    .map(|s| by_day(current.date(), s))
                    .unwrap_or(current.day() == base.day())
            });
        let matches = match frequency {
            "DAILY" => delta >= 0 && delta % interval == 0,
            "WEEKLY" => {
                parts
                    .get("BYDAY")
                    .map(|s| by_day(current.date(), s))
                    .unwrap_or(current.weekday() == base.weekday())
                    && (week(current.date()) - week(base.date())) % interval == 0
            }
            "MONTHLY" => month_delta >= 0 && month_delta % interval == 0 && month_day,
            "YEARLY" => {
                year_delta >= 0
                    && year_delta % interval == 0
                    && month_day
                    && parts
                        .get("BYMONTH")
                        .map(|s| listed(current.month() as i32, s))
                        .unwrap_or(current.month() == base.month())
            }
            _ => false,
        };
        let mut occurrence = property.clone();
        occurrence.value = current
            .format(if property.value.len() == 8 {
                "%Y%m%d"
            } else if property.value.ends_with('Z') {
                "%Y%m%dT%H%M%SZ"
            } else {
                "%Y%m%dT%H%M%S"
            })
            .to_string();
        let at = dates::moment(Some(&occurrence), &calendar)["ms"]
            .as_i64()
            .ok_or("calendar_invalid_response")?;
        if until > 0 && at > until {
            return Ok(out);
        }
        if matches && at >= ms(event) {
            emitted += 1;
            if count > 0 && emitted > count {
                return Ok(out);
            }
            out.push(at);
        }
        current = current
            .checked_add_signed(Duration::days(1))
            .ok_or("calendar_invalid_response")?;
    }
    Err("calendar_recurrence_too_large")
}
pub(super) fn expand(events: Vec<Value>, from: i64, to: i64) -> Result<Vec<Value>> {
    let mut overrides = HashMap::new();
    let mut masters = Vec::new();
    let mut out = Vec::new();
    let mut budget = super::EventBudget::default();
    for event in events {
        let at = event["recurrenceIdMs"].as_i64().unwrap_or(0);
        if at != 0 {
            overrides.insert((event["uid"].as_str().unwrap_or("").to_owned(), at), event);
        } else if !event["recurrenceRule"].as_str().unwrap_or("").is_empty() {
            masters.push(event);
        } else if event["status"] != "CANCELLED" && in_range(&event, from, to) {
            budget.reserve(&event, 0)?;
            out.push(event);
        }
    }
    for master in masters {
        let excluded: HashSet<_> = master["excludedMs"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(Value::as_i64)
            .collect();
        for at in starts(&master, from, to)? {
            let key = (master["uid"].as_str().unwrap_or("").to_owned(), at);
            if let Some(replacement) = overrides.remove(&key) {
                if replacement["status"] != "CANCELLED" && in_range(&replacement, from, to) {
                    budget.reserve(&replacement, 0)?;
                    out.push(replacement);
                }
            } else if !excluded.contains(&at) && master["status"] != "CANCELLED" {
                let end = master["end"]["ms"]
                    .as_i64()
                    .map(|end| end.saturating_add(at.saturating_sub(ms(&master))));
                if at >= to || end.unwrap_or(at.saturating_add(1)) <= from {
                    continue;
                }
                budget.reserve(&master, 64)?;
                let mut event = master.clone();
                event["start"]["ms"] = json!(at);
                if let Some(end) = end {
                    event["end"]["ms"] = json!(end);
                }
                event["recurrenceIdMs"] = json!(at);
                out.push(event);
            }
        }
    }
    for event in overrides
        .into_values()
        .filter(|event| event["status"] != "CANCELLED" && in_range(event, from, to))
    {
        budget.reserve(&event, 0)?;
        out.push(event);
    }
    sort(&mut out);
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn review_extreme_ranges_cannot_panic_during_recurrence_seek() {
        let event = json!({"recurrenceRule":"FREQ=DAILY", "start":{"ms":1767225600000_i64},
            "source":{"dtstart":"DTSTART:20260101T000000Z","timezones":[]}});
        assert_eq!(starts(&event, i64::MIN, i64::MIN + 1), Ok(vec![]));
        assert_eq!(
            starts(&event, i64::MAX - 1, i64::MAX),
            Err("calendar_invalid_response")
        );
    }
}
