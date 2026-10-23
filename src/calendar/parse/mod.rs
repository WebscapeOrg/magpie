use chrono::{DateTime, Local, NaiveDate, TimeZone};
use serde_json::{Value, json};
type Result<T> = std::result::Result<T, &'static str>;
fn text<'a>(value: &'a Value, key: &str) -> &'a str {
    value[key].as_str().unwrap_or("")
}
fn default<'a>(value: &'a Value, key: &str, fallback: &'a str) -> &'a str {
    value[key]
        .as_str()
        .filter(|s| !s.is_empty())
        .unwrap_or(fallback)
}
fn sort(events: &mut [Value]) {
    events.sort_by(|a, b| {
        a["start"]["ms"]
            .as_i64()
            .unwrap_or(0)
            .cmp(&b["start"]["ms"].as_i64().unwrap_or(0))
            .then_with(|| {
                text(a, "summary")
                    .to_lowercase()
                    .cmp(&text(b, "summary").to_lowercase())
            })
    });
}
fn moment(text: &str, all_day: bool) -> Value {
    let ms = if all_day {
        text.get(..10)
            .and_then(|s| NaiveDate::parse_from_str(s, "%Y-%m-%d").ok())
            .and_then(|d| d.and_hms_opt(0, 0, 0))
            .and_then(|date| Local.from_local_datetime(&date).earliest())
            .map(|instant| instant.timestamp_millis())
    } else {
        DateTime::parse_from_rfc3339(text)
            .ok()
            .map(|d| d.timestamp_millis())
    };
    ms.map(|ms| json!({"ms":ms,"allDay":all_day,"tzid":"","resolved":true}))
        .unwrap_or(Value::Null)
}
fn google(payload: &Value, source: &str) -> Vec<Value> {
    let mut events = Vec::new();
    for item in payload["items"].as_array().into_iter().flatten() {
        if text(item, "status").eq_ignore_ascii_case("cancelled") {
            continue;
        }
        let at = |key: &str| {
            moment(
                default(&item[key], "dateTime", text(&item[key], "date")),
                text(&item[key], "dateTime").is_empty() && !text(&item[key], "date").is_empty(),
            )
        };
        let start = at("start");
        if start.is_null() {
            continue;
        }
        let mut row = json!({"method":"","uid":default(item,"iCalUID",text(item,"id")),"googleId":text(item,"id"),
            "etag":text(item,"etag"),"recurringEventId":text(item,"recurringEventId"),"originalStartTime":item["originalStartTime"],
            "timeZone":default(&item["start"],"timeZone",text(payload,"timeZone")),"reminders":item.get("reminders").cloned().unwrap_or(json!({"useDefault":true})),
            "conferenceData":item["conferenceData"],"eventType":default(item,"eventType","default"),"guestsCanModify":item["guestsCanModify"]==true,
            "transparency":default(item,"transparency","opaque"),"visibility":default(item,"visibility","default"),"sequence":item["sequence"].as_u64().unwrap_or(0),
            "summary":default(item,"summary","Untitled event"),"description":text(item,"description"),"location":text(item,"location"),
            "status":text(item,"status").to_uppercase(),"organizer":item["organizer"],"attendees":item["attendees"].as_array().cloned().unwrap_or_default(),
            "recurrenceLines":item["recurrence"].as_array().cloned().unwrap_or_default(),"start":start,"end":at("end"),
            "recurrence":"","meetLink":text(item,"hangoutLink"),"sourceId":source,"href":text(item,"htmlLink"),"source":null});
        row["recurrence"] = json!(
            item["recurrence"]
                .as_array()
                .into_iter()
                .flatten()
                .filter_map(Value::as_str)
                .collect::<Vec<_>>()
                .join("; ")
        );
        events.push(row);
    }
    sort(&mut events);
    events
}
pub(crate) fn parse(params: &Value) -> Result<Value> {
    if params.as_object().is_none_or(|p| {
        p.keys()
            .any(|k| !["body", "kind", "sourceId", "startMs", "endMs"].contains(&k.as_str()))
    }) {
        return Err("invalid_params");
    }
    let body = params["body"].as_str().ok_or("invalid_params")?;
    if body.len() > 16 * 1024 * 1024 {
        return Err("calendar_response_too_large");
    }
    let source = text(params, "sourceId");
    let events = match text(params, "kind") {
        "google" => {
            let payload: Value =
                serde_json::from_str(body).map_err(|_| "calendar_invalid_response")?;
            if !payload.is_object()
                || payload.get("items").is_some_and(|v| !v.is_array())
                || payload.get("error").is_some()
            {
                return Err("calendar_invalid_response");
            }
            google(&payload, source)
        }
        _ => return Err("calendar_provider_unsupported"),
    };
    Ok(json!({"events":events}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn google_calendar_regressions_match_native_parsing() {
        let output = std::process::Command::new("node")
            .arg("tests/calendar_parse_oracle.js")
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "{}",
            String::from_utf8_lossy(&output.stderr)
        );
        let cases: Vec<Value> = serde_json::from_slice(&output.stdout).unwrap();
        assert!(!cases.is_empty());
        for (index, case) in cases.into_iter().enumerate() {
            let args = &case["args"];
            let result =
                parse(&json!({"kind":"google","sourceId":args[1],"body":args[0].to_string()}))
                    .unwrap();
            assert_eq!(result["events"], case["result"], "case {index}");
        }
    }

    #[test]
    fn unsupported_calendar_documents_are_not_parsed() {
        for kind in ["caldav", "icloud", "microsoft", "hey", "unknown"] {
            let payload = json!({"kind":kind,"body":"<!DOCTYPE d [<!ENTITY x SYSTEM 'file:///etc/passwd'>]><response><calendar-data>&x;</calendar-data></response>"});
            assert_eq!(parse(&payload), Err("calendar_provider_unsupported"));
        }
    }
}
