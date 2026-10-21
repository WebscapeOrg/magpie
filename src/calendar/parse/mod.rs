mod dates;
mod ics;
mod recurrence;
use chrono::{DateTime, NaiveDate, NaiveDateTime};
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
fn moment(text: &str, all_day: bool, graph: bool) -> Value {
    let ms = if all_day {
        text.get(..10)
            .and_then(|s| NaiveDate::parse_from_str(s, "%Y-%m-%d").ok())
            .and_then(|d| d.and_hms_opt(0, 0, 0))
            .and_then(dates::local)
    } else if graph {
        NaiveDateTime::parse_from_str(text.trim_end_matches('Z'), "%Y-%m-%dT%H:%M:%S%.f")
            .ok()
            .map(|d| d.and_utc().timestamp_millis())
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
                false,
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
fn graph(payload: &Value, source: &str) -> Vec<Value> {
    let person = |p: &Value| json!({"email":text(&p["emailAddress"],"address"),"displayName":text(&p["emailAddress"],"name")});
    let mut events = Vec::new();
    for item in payload["value"].as_array().into_iter().flatten() {
        if item["isCancelled"] == true {
            continue;
        }
        let at = |key: &str| moment(text(&item[key], "dateTime"), item["isAllDay"] == true, true);
        let start = at("start");
        if start.is_null() {
            continue;
        }
        events.push(json!({"method":"","uid":default(item,"iCalUId",text(item,"id")),"graphId":text(item,"id"),"sequence":0,
            "summary":default(item,"subject","Untitled event"),"description":text(item,"bodyPreview"),"location":text(&item["location"],"displayName"),
            "status":"CONFIRMED","organizer":if item["organizer"].is_object(){person(&item["organizer"])}else{Value::Null},
            "attendees":item["attendees"].as_array().into_iter().flatten().map(person).collect::<Vec<_>>(),"start":start,"end":at("end"),
            "recurrence":"","meetLink":text(&item["onlineMeeting"],"joinUrl"),"sourceId":source,"href":text(item,"webLink"),"source":null}));
    }
    sort(&mut events);
    events
}
fn caldav(xml: &str, source: &str, start: i64, end: i64) -> Result<Vec<Value>> {
    use quick_xml::{Reader, events::Event};
    let mut reader = Reader::from_str(xml);
    let mut tags: Vec<String> = Vec::new();
    let mut href = String::new();
    let mut data = String::new();
    let mut events = Vec::new();
    loop {
        match reader
            .read_event()
            .map_err(|_| "calendar_invalid_response")?
        {
            Event::Start(e) => {
                if tags.len() > 64 {
                    return Err("calendar_response_too_large");
                }
                let tag = String::from_utf8_lossy(e.local_name().as_ref()).into_owned();
                if tag == "response" {
                    href.clear();
                    data.clear();
                }
                tags.push(tag);
            }
            Event::Text(e) => {
                let decoded = e.decode().map_err(|_| "calendar_invalid_response")?;
                let value = quick_xml::escape::unescape(&decoded)
                    .map_err(|_| "calendar_invalid_response")?;
                match tags.last().map(String::as_str) {
                    Some("href") => href.push_str(&value),
                    Some("calendar-data") => data.push_str(&value),
                    _ => (),
                }
            }
            Event::CData(e) => {
                let value = e.decode().map_err(|_| "calendar_invalid_response")?;
                match tags.last().map(String::as_str) {
                    Some("href") => href.push_str(&value),
                    Some("calendar-data") => data.push_str(&value),
                    _ => (),
                }
            }
            Event::GeneralRef(e) => {
                let name = e.decode().map_err(|_| "calendar_invalid_response")?;
                let encoded = format!("&{name};");
                let value = quick_xml::escape::unescape(&encoded)
                    .map_err(|_| "calendar_invalid_response")?;
                match tags.last().map(String::as_str) {
                    Some("href") => href.push_str(&value),
                    Some("calendar-data") => data.push_str(&value),
                    _ => (),
                }
            }
            Event::End(_) => {
                if tags.pop().as_deref() == Some("response") && !data.is_empty() {
                    let calendar = ics::parse(&data)?;
                    for mut event in ics::events(&calendar) {
                        event["sourceId"] = json!(source);
                        event["href"] = json!(href);
                        event["calendarData"] = json!(data);
                        events.push(event);
                    }
                    if events.len() > 25000 {
                        return Err("calendar_response_too_large");
                    }
                }
            }
            Event::DocType(_) => return Err("calendar_invalid_response"),
            Event::Eof => break,
            _ => (),
        }
    }
    if !tags.is_empty() {
        return Err("calendar_invalid_response");
    }
    if start != 0 && end != 0 {
        recurrence::expand(events, start, end)
    } else {
        events.retain(|e| e["status"] != "CANCELLED");
        sort(&mut events);
        Ok(events)
    }
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
        "google" | "microsoft" => {
            let payload: Value =
                serde_json::from_str(body).map_err(|_| "calendar_invalid_response")?;
            let items = if text(params, "kind") == "google" {
                "items"
            } else {
                "value"
            };
            if !payload.is_object()
                || payload.get(items).is_some_and(|v| !v.is_array())
                || payload.get("error").is_some()
            {
                return Err("calendar_invalid_response");
            }
            if text(params, "kind") == "google" {
                google(&payload, source)
            } else {
                graph(&payload, source)
            }
        }
        "caldav" | "icloud" => caldav(
            body,
            source,
            params["startMs"].as_i64().unwrap_or(0),
            params["endMs"].as_i64().unwrap_or(0),
        )?,
        _ => return Err("invalid_params"),
    };
    Ok(json!({"events":events}))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn existing_calendar_regressions_match_native_parsing() {
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
        assert!(cases.len() > 20);
        for (index, case) in cases.into_iter().enumerate() {
            let args = &case["args"];
            let name = text(&case, "name");
            if matches!(name, "eventsFrom" | "invitationFrom")
                && args[0]
                    .as_str()
                    .is_some_and(|s| !s.trim_end().ends_with("END:VCALENDAR"))
            {
                assert!(
                    ics::parse(args[0].as_str().unwrap()).is_err(),
                    "truncated calendars must not replace a complete saved range"
                );
                continue;
            }
            let got = if matches!(name, "eventsFrom" | "invitationFrom") {
                let mut events = ics::parse(args[0].as_str().unwrap())
                    .map(|c| ics::events(&c))
                    .unwrap_or_default();
                if let Some(fallback) = args[1].as_str() {
                    for event in &mut events {
                        if event["method"] == "" {
                            event["method"] = json!(fallback.to_uppercase());
                        }
                    }
                }
                if name == "invitationFrom" {
                    events.into_iter().next().unwrap_or(Value::Null)
                } else {
                    json!(events)
                }
            } else {
                let kind = match name {
                    "eventsFromGoogle" => "google",
                    "eventsFromGraph" => "microsoft",
                    _ => "caldav",
                };
                parse(&json!({"kind":kind,"sourceId":args[1],"body":if kind=="caldav"{args[0].as_str().unwrap().to_owned()}else{args[0].to_string()},
                    "startMs":args[2],"endMs":args[3]})).unwrap_or_else(|error|panic!("case {index} {name}: {error}"))["events"].clone()
            };
            assert_eq!(got, case["result"], "case {index} {name}");
        }
    }
    #[test]
    fn xml_entities_cannot_read_external_files() {
        let payload = json!({"kind":"caldav","body":"<!DOCTYPE d [<!ENTITY x SYSTEM 'file:///etc/passwd'>]><response><calendar-data>&x;</calendar-data></response>"});
        assert_eq!(parse(&payload), Err("calendar_invalid_response"));
    }
}
