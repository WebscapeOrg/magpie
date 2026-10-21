use super::dates;
use serde_json::{Value, json};
use std::collections::HashMap;

#[derive(Clone, Default)]
pub(super) struct Property {
    pub name: String,
    pub value: String,
    pub params: HashMap<String, String>,
    pub raw: String,
}
#[derive(Clone, Default)]
pub(super) struct Component {
    pub name: String,
    pub properties: Vec<Property>,
    pub children: Vec<Component>,
    pub lines: Vec<String>,
}
impl Component {
    pub fn property(&self, name: &str) -> Option<&Property> {
        self.properties.iter().find(|p| p.name == name)
    }
    pub fn text(&self, name: &str) -> &str {
        self.property(name).map(|p| p.value.as_str()).unwrap_or("")
    }
    pub fn raw(&self, name: &str) -> &str {
        self.property(name).map(|p| p.raw.as_str()).unwrap_or("")
    }
}
fn split(text: &str, separator: char) -> Vec<&str> {
    let mut quoted = false;
    let mut at = 0;
    let mut parts = Vec::new();
    for (index, c) in text.char_indices() {
        if c == '"' {
            quoted = !quoted;
        }
        if c == separator && !quoted {
            parts.push(&text[at..index]);
            at = index + c.len_utf8();
        }
    }
    parts.push(&text[at..]);
    parts
}
pub(super) fn property(line: &str) -> Option<Property> {
    let chunks = split(line, ':');
    if chunks.len() < 2 {
        return None;
    }
    let mut names = split(chunks[0], ';').into_iter();
    let name = names.next()?.to_uppercase();
    let params = names
        .filter_map(|s| s.split_once('='))
        .map(|(k, v)| (k.to_uppercase(), v.trim_matches('"').to_owned()))
        .collect();
    Some(Property {
        name,
        value: line[chunks[0].len() + 1..].to_owned(),
        params,
        raw: line.to_owned(),
    })
}
pub(super) fn parse(text: &str) -> Result<Component, &'static str> {
    if text.len() > 512 * 1024 {
        return Err("calendar_response_too_large");
    }
    let mut lines: Vec<String> = Vec::new();
    let normalized = text.replace("\r\n", "\n").replace('\r', "\n");
    for line in normalized.split('\n') {
        if (line.starts_with(' ') || line.starts_with('\t')) && !lines.is_empty() {
            lines.last_mut().unwrap().push_str(&line[1..]);
        } else if !line.trim().is_empty() {
            lines.push(line.to_owned());
        }
    }
    let mut stack: Vec<Component> = Vec::new();
    let mut root = None;
    for line in lines {
        let Some(p) = property(&line) else { continue };
        if p.name == "BEGIN" {
            if stack.len() >= 8 {
                return Err("calendar_response_too_large");
            }
            stack.push(Component {
                name: p.value.to_uppercase(),
                ..Default::default()
            });
        } else if p.name == "END" {
            let Some(child) = stack.pop() else {
                return Err("calendar_invalid_response");
            };
            if child.name != p.value.to_uppercase() {
                return Err("calendar_invalid_response");
            }
            if let Some(parent) = stack.last_mut() {
                parent.lines.push(format!("BEGIN:{}", child.name));
                parent.lines.extend(child.lines.clone());
                parent.lines.push(format!("END:{}", child.name));
                parent.children.push(child);
            } else if root.replace(child).is_some() {
                return Err("calendar_invalid_response");
            }
        } else if let Some(current) = stack.last_mut() {
            current.lines.push(line);
            current.properties.push(p);
        }
    }
    if !stack.is_empty() {
        return Err("calendar_invalid_response");
    }
    root.filter(|c| c.name == "VCALENDAR")
        .ok_or("calendar_invalid_response")
}
fn unescape(text: &str) -> String {
    let mut result = String::new();
    let mut chars = text.chars();
    while let Some(c) = chars.next() {
        if c != '\\' {
            result.push(c);
            continue;
        }
        if let Some(c) = chars.next() {
            result.push(if c == 'n' || c == 'N' { '\n' } else { c });
        }
    }
    result
}
fn address(property: Option<&Property>) -> Value {
    let Some(p) = property else {
        return Value::Null;
    };
    let email = if p.value.to_lowercase().starts_with("mailto:") {
        &p.value[7..]
    } else {
        &p.value
    }
    .trim();
    let name = unescape(p.params.get("CN").map(String::as_str).unwrap_or(""))
        .trim()
        .to_owned();
    let role = p
        .params
        .get("ROLE")
        .cloned()
        .unwrap_or_default()
        .to_uppercase();
    json!({"name":if name.is_empty(){email}else{&name},"email":email,
        "role":role,"optional":role=="OPT-PARTICIPANT",
        "resource":p.params.get("CUTYPE").is_some_and(|s|s.eq_ignore_ascii_case("RESOURCE")),
        "partstat":p.params.get("PARTSTAT").cloned().unwrap_or_default().to_uppercase()})
}
fn recurrence(rule: &str) -> String {
    if rule.is_empty() {
        return String::new();
    }
    let parts = dates::rules(rule);
    let frequency = parts.get("FREQ").map(String::as_str).unwrap_or("");
    let (one, many) = match frequency {
        "DAILY" => ("Daily", "days"),
        "WEEKLY" => ("Weekly", "weeks"),
        "MONTHLY" => ("Monthly", "months"),
        "YEARLY" => ("Yearly", "years"),
        _ => return "Repeats".into(),
    };
    let interval = parts
        .get("INTERVAL")
        .and_then(|s| s.parse::<i64>().ok())
        .unwrap_or(1);
    let mut text = if interval > 1 {
        format!("Every {interval} {many}")
    } else {
        one.into()
    };
    if matches!(frequency, "WEEKLY" | "MONTHLY") {
        let names = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
        let days: Vec<_> = parts
            .get("BYDAY")
            .into_iter()
            .flat_map(|s| s.split(','))
            .filter_map(|s| dates::weekday(s).map(|(_, day)| names[day as usize]))
            .collect();
        if !days.is_empty() {
            text.push_str(&format!(" on {}", days.join(", ")));
        }
    }
    if let Some(count) = parts
        .get("COUNT")
        .and_then(|s| s.parse::<u64>().ok())
        .filter(|n| *n > 0)
    {
        text.push_str(&format!(", {count} times"));
    } else if let Some(until) = parts.get("UNTIL").and_then(|s| dates::date(s)) {
        text.push_str(&until.format(", until %b %-d, %Y").to_string());
    }
    text
}
fn conference(event: &Component) -> String {
    static MEET: std::sync::OnceLock<regex::Regex> = std::sync::OnceLock::new();
    static OTHER: std::sync::OnceLock<regex::Regex> = std::sync::OnceLock::new();
    let meet =
        MEET.get_or_init(|| regex::Regex::new(r"https://meet\.google\.com/[a-z0-9-]+").unwrap());
    let other=OTHER.get_or_init(||regex::Regex::new(r#"https://(?:[a-z0-9-]+\.)*(?:zoom\.us|teams\.microsoft\.com|teams\.live\.com|meet\.google\.com|whereby\.com|webex\.com|chime\.aws)/[^\s<>"]+"#).unwrap());
    for key in ["X-GOOGLE-CONFERENCE", "LOCATION", "DESCRIPTION"] {
        if let Some(found) = meet.find(event.text(key)) {
            return found.as_str().into();
        }
    }
    for key in ["LOCATION", "DESCRIPTION"] {
        if let Some(found) = other.find(event.text(key)) {
            return found.as_str().into();
        }
    }
    String::new()
}
pub(super) fn events(calendar: &Component) -> Vec<Value> {
    let zones: Vec<_> = calendar
        .children
        .iter()
        .filter(|c| c.name == "VTIMEZONE")
        .map(|c| {
            format!(
                "BEGIN:VTIMEZONE\r\n{}\r\nEND:VTIMEZONE",
                c.lines.join("\r\n")
            )
        })
        .collect();
    let mut events = Vec::new();
    for event in calendar
        .children
        .iter()
        .filter(|c| c.name == "VEVENT" && !c.text("UID").is_empty())
    {
        let start = dates::moment(event.property("DTSTART"), calendar);
        let mut end = dates::moment(event.property("DTEND"), calendar);
        let duration = dates::duration(event.text("DURATION"));
        if end.is_null() && start.is_object() && duration > 0 {
            end = start.clone();
            end["ms"] = json!(start["ms"].as_i64().unwrap_or(0).saturating_add(duration));
        }
        let excluded: Vec<_> = event
            .properties
            .iter()
            .filter(|p| p.name == "EXDATE")
            .flat_map(|p| {
                p.value.split(',').map(|value| Property {
                    value: value.into(),
                    ..p.clone()
                })
            })
            .filter_map(|p| dates::moment(Some(&p), calendar)["ms"].as_i64())
            .collect();
        let attendees: Vec<_> = event
            .properties
            .iter()
            .filter(|p| p.name == "ATTENDEE")
            .map(|p| address(Some(p)))
            .filter(|p| p["email"] != "")
            .collect();
        let rule = event.text("RRULE");
        let method = calendar.text("METHOD").trim().to_uppercase();
        events.push(json!({"method":if ["REQUEST","REPLY","CANCEL","PUBLISH","COUNTER","REFRESH","ADD","DECLINECOUNTER"].contains(&method.as_str()){method}else{String::new()},
            "uid":unescape(event.text("UID")),"sequence":event.text("SEQUENCE").parse::<u64>().unwrap_or(0),
            "summary":unescape(event.text("SUMMARY")),"description":unescape(event.text("DESCRIPTION")),"location":unescape(event.text("LOCATION")),
            "status":event.text("STATUS").to_uppercase(),"organizer":address(event.property("ORGANIZER")),"attendees":attendees,
            "start":start,"end":end,"recurrence":recurrence(rule),"recurrenceRule":rule,
            "recurrenceIdMs":dates::moment(event.property("RECURRENCE-ID"),calendar)["ms"].as_i64().unwrap_or(0),
            "excludedMs":excluded,"meetLink":conference(event),
            "source":{"dtstart":event.raw("DTSTART"),"dtend":event.raw("DTEND"),"duration":event.raw("DURATION"),
                "recurrenceId":event.raw("RECURRENCE-ID"),"timezones":zones}}));
    }
    events
}
