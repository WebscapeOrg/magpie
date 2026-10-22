use super::ics::{Component, Property};
use chrono::{Datelike, Local, NaiveDate, NaiveDateTime, TimeZone};
use serde_json::{Value, json};
use std::collections::HashMap;

pub(super) fn rules(text: &str) -> HashMap<String, String> {
    text.split(';')
        .filter_map(|s| s.split_once('='))
        .map(|(name, value)| (name.trim().to_uppercase(), value.trim().to_owned()))
        .collect()
}
pub(super) fn date(text: &str) -> Option<NaiveDateTime> {
    let text = text.trim().trim_end_matches('Z');
    if text.len() == 8 {
        NaiveDate::parse_from_str(text, "%Y%m%d")
            .ok()?
            .and_hms_opt(0, 0, 0)
    } else {
        NaiveDateTime::parse_from_str(text, "%Y%m%dT%H%M%S").ok()
    }
}
pub(super) fn local(date: NaiveDateTime) -> Option<i64> {
    Local
        .from_local_datetime(&date)
        .earliest()
        .map(|instant| instant.timestamp_millis())
}
fn offset_seconds(text: &str) -> Option<i64> {
    if !matches!(text.len(), 5 | 7)
        || !text.is_ascii()
        || !text[1..].bytes().all(|byte| byte.is_ascii_digit())
    {
        return None;
    }
    let sign = match &text[..1] {
        "+" => 1,
        "-" => -1,
        _ => return None,
    };
    let hours = text[1..3].parse::<i64>().ok()?;
    let minutes = text[3..5].parse::<i64>().ok()?;
    let seconds = if text.len() == 7 {
        text[5..7].parse::<i64>().ok()?
    } else {
        0
    };
    if hours > 23 || minutes > 59 || seconds > 59 {
        return None;
    }
    Some(sign * (hours * 3600 + minutes * 60 + seconds))
}
pub(super) fn month_days(year: i32, month: u32) -> u32 {
    (28..=31)
        .rev()
        .find(|&day| NaiveDate::from_ymd_opt(year, month, day).is_some())
        .unwrap_or(0)
}
pub(super) fn weekday(text: &str) -> Option<(i32, u32)> {
    if text.len() < 2 || !text.is_ascii() {
        return None;
    }
    let at = text.len() - 2;
    let day = ["SU", "MO", "TU", "WE", "TH", "FR", "SA"]
        .iter()
        .position(|weekday| *weekday == &text[at..])? as u32;
    let ordinal = if at == 0 { 0 } else { text[..at].parse().ok()? };
    Some((ordinal, day))
}
fn transition(rule: &Component, year: i32) -> Option<i64> {
    let start = date(rule.text("DTSTART"))?;
    let parts = rules(rule.text("RRULE"));
    if parts.get("FREQ").map(String::as_str) != Some("YEARLY") {
        return None;
    }
    let month = parts
        .get("BYMONTH")
        .and_then(|value| value.parse().ok())
        .unwrap_or(start.month());
    let total = month_days(year, month);
    let day = if let Some(by) = parts.get("BYDAY") {
        let (ordinal, weekday_index) = weekday(by.split(',').next()?)?;
        let choices: Vec<_> = (1..=total)
            .filter(|day_of_month| {
                NaiveDate::from_ymd_opt(year, month, *day_of_month)
                    .is_some_and(|date| date.weekday().num_days_from_sunday() == weekday_index)
            })
            .collect();
        let index = if ordinal < 0 {
            choices.len() as i32 + ordinal
        } else {
            ordinal.max(1) - 1
        };
        *choices.get(usize::try_from(index).ok()?)?
    } else if let Some(by) = parts.get("BYMONTHDAY") {
        let day = by.split(',').next()?.parse::<i32>().ok()?;
        if day < 0 {
            (total as i32 + day + 1) as u32
        } else {
            day as u32
        }
    } else {
        start.day()
    };
    let found = NaiveDate::from_ymd_opt(year, month, day)?
        .and_time(start.time())
        .and_utc()
        .timestamp_millis();
    if let Some(until) = parts.get("UNTIL") {
        let limit = date(until)?.and_utc().timestamp_millis()
            + if until.len() == 8 { 86_399_999 } else { 0 };
        let reading = found
            - if until.ends_with('Z') {
                offset_seconds(rule.text("TZOFFSETFROM")).unwrap_or(0) * 1000
            } else {
                0
            };
        if reading > limit {
            return None;
        }
    }
    Some(found)
}
fn dated(rule: &Component) -> Vec<NaiveDateTime> {
    std::iter::once(rule.text("DTSTART"))
        .chain(
            rule.properties
                .iter()
                .filter(|property| property.name == "RDATE")
                .map(|property| property.value.as_str()),
        )
        .flat_map(|s| s.split(','))
        .filter_map(date)
        .collect()
}
pub(super) fn zone(calendar: &Component, tzid: &str, reading: NaiveDateTime) -> Option<i64> {
    let zone = calendar
        .children
        .iter()
        .find(|component| component.name == "VTIMEZONE" && component.text("TZID") == tzid)?;
    let ordered: Vec<_> = ["STANDARD", "DAYLIGHT"]
        .iter()
        .flat_map(|kind| {
            zone.children
                .iter()
                .filter(move |component| component.name == *kind)
        })
        .filter_map(|component| Some((component, offset_seconds(component.text("TZOFFSETTO"))?)))
        .collect();
    if ordered.len() == 1 {
        return Some(ordered[0].1);
    }
    let history = ordered.len() > 2
        || ordered.iter().any(|(rule, _)| {
            rule.text("RRULE").contains("UNTIL=") || rule.property("RDATE").is_some()
        });
    let mut candidates = Vec::new();
    let year = reading.year();
    for (rule, to) in &ordered {
        if rule.property("RRULE").is_some() {
            let mut years = vec![year - 1, year];
            if history {
                if let Some(last) = rules(rule.text("RRULE"))
                    .get("UNTIL")
                    .and_then(|s| date(s))
                    .map(|d| d.year())
                {
                    if last < year - 1 {
                        years.extend([last - 1, last, last + 1]);
                    }
                }
            }
            for y in years {
                if let Some(at) = transition(rule, y) {
                    candidates.push((at, *to));
                }
            }
        } else {
            for d in dated(rule) {
                if d.year() == year || d.year() == year - 1 || (history && d.year() < year) {
                    candidates.push((d.and_utc().timestamp_millis(), *to));
                }
            }
        }
    }
    let wanted = reading.and_utc().timestamp_millis();
    if let Some((_, to)) = candidates
        .into_iter()
        .filter(|(at, _)| *at <= wanted)
        .max_by_key(|(at, _)| *at)
    {
        return Some(to);
    }
    let earliest = ordered
        .iter()
        .filter_map(|(rule, _)| {
            let at = if rule.property("RRULE").is_some() {
                transition(rule, year - 1)
            } else {
                dated(rule)
                    .into_iter()
                    .filter(|d| d.year() == year - 1)
                    .map(|d| d.and_utc().timestamp_millis())
                    .min()
            }?;
            Some((at, offset_seconds(rule.text("TZOFFSETFROM"))?))
        })
        .min_by_key(|(at, _)| *at);
    earliest
        .map(|(_, offset)| offset)
        .or_else(|| ordered.first().map(|(_, offset)| *offset))
}
pub(super) fn moment(property: Option<&Property>, calendar: &Component) -> Value {
    let Some(property) = property else {
        return Value::Null;
    };
    let Some(value) = date(&property.value) else {
        return Value::Null;
    };
    let tz = property
        .params
        .get("TZID")
        .map(String::as_str)
        .unwrap_or("");
    let all_day = property.value.len() == 8;
    let universal = property.value.ends_with('Z')
        || ["UTC", "GMT", "Z", "ETC/UTC", "ETC/GMT"].contains(&tz.to_uppercase().as_str());
    let (ms, resolved, tz) = if all_day {
        (local(value), true, "")
    } else if universal {
        (Some(value.and_utc().timestamp_millis()), true, "")
    } else if !tz.is_empty() {
        let offset = zone(calendar, tz, value);
        (
            Some(value.and_utc().timestamp_millis() - offset.unwrap_or(0) * 1000),
            offset.is_some(),
            tz,
        )
    } else {
        (local(value), true, "")
    };
    ms.map(|ms| json!({"ms":ms,"allDay":all_day,"tzid":tz,"resolved":resolved}))
        .unwrap_or(Value::Null)
}
pub(super) fn duration(text: &str) -> i64 {
    let mut text = text.trim().to_uppercase();
    let sign = if text.starts_with('-') { -1 } else { 1 };
    text = text.trim_start_matches(['-', '+']).to_owned();
    let Some(text) = text.strip_prefix('P') else {
        return 0;
    };
    let mut total = 0i64;
    let mut number = String::new();
    let mut timed = false;
    for character in text.chars() {
        if character == 'T' {
            timed = true;
            continue;
        }
        if character.is_ascii_digit() {
            number.push(character);
            continue;
        }
        let multiplier = match character {
            'W' => 604800000,
            'D' => 86400000,
            'H' if timed => 3600000,
            'M' if timed => 60000,
            'S' if timed => 1000,
            _ => return 0,
        };
        let Some(value) = number
            .parse::<i64>()
            .ok()
            .and_then(|value| value.checked_mul(multiplier))
            .and_then(|value| total.checked_add(value))
        else {
            return 0;
        };
        total = value;
        number.clear();
    }
    if number.is_empty() { sign * total } else { 0 }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round2_timezone_offset_seconds_and_invalid_components_reach_events() {
        for (offset, seconds, resolved) in [
            ("+010521", 3921, true),
            ("-003021", -1821, true),
            ("+2460", 0, false),
            ("-0060", 0, false),
            ("+126199", 0, false),
            ("++100", 0, false),
        ] {
            let source = format!(
                "BEGIN:VCALENDAR\r\nBEGIN:VTIMEZONE\r\nTZID:Test\r\nBEGIN:STANDARD\r\nDTSTART:20000101T000000\r\nTZOFFSETFROM:{offset}\r\nTZOFFSETTO:{offset}\r\nEND:STANDARD\r\nEND:VTIMEZONE\r\nBEGIN:VEVENT\r\nUID:test\r\nDTSTART;TZID=Test:20260102T120000\r\nSUMMARY:Meeting\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"
            );
            let response = format!(
                "<multistatus><response><href>/meeting.ics</href><calendar-data><![CDATA[{source}]]></calendar-data></response></multistatus>"
            );
            let parsed =
                super::super::parse(&json!({"kind":"caldav","body":response,"sourceId":"test"}))
                    .unwrap();
            let event = &parsed["events"][0];
            let expected = date("20260102T120000")
                .unwrap()
                .and_utc()
                .timestamp_millis()
                - seconds * 1000;
            assert_eq!(event["start"]["ms"], expected, "{offset}");
            assert_eq!(event["start"]["resolved"], resolved, "{offset}");
        }
    }
}
