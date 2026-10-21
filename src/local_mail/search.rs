use chrono::{Local, NaiveDate, TimeZone};
use rusqlite::types::Value;

pub(super) struct Query {
    pub sql: String,
    pub values: Vec<Value>,
    matches: Vec<usize>,
}
impl Query {
    pub(super) fn choose_plan(&mut self, db: &rusqlite::Connection) -> Result<(), &'static str> {
        for index in &self.matches {
            let count: i64 = super::store::sql(db.query_row(
                "SELECT count(*) FROM (SELECT rowid FROM search WHERE search MATCH ?1 LIMIT 10001)",
                [&self.values[index - 1]],
                |r| r.get(0),
            ))?;
            if count > 10000 {
                self.sql = self.sql.replace(
                    &format!("m.rowid IN (SELECT rowid FROM search WHERE search MATCH ?{index})"),
                    &format!(
                        "EXISTS(SELECT 1 FROM search WHERE rowid=m.rowid AND search MATCH ?{index})"
                    ),
                );
            }
        }
        Ok(())
    }
}
pub(super) fn parse(input: &str) -> Result<Query, &'static str> {
    if input.len() > 32768 || input.chars().any(char::is_control) {
        return Err("local_search_unsupported");
    }
    let mut tokens = Vec::new();
    let mut word = String::new();
    let mut quoted = false;
    for ch in input.chars() {
        if ch == '"' {
            quoted = !quoted;
            word.push(ch);
        } else if ch.is_whitespace() && !quoted {
            if !word.is_empty() {
                tokens.push(std::mem::take(&mut word));
            }
        } else {
            word.push(ch);
        }
    }
    if quoted {
        return Err("local_search_unsupported");
    }
    if !word.is_empty() {
        tokens.push(word);
    }
    if tokens.len() > 128 {
        return Err("local_search_unsupported");
    }
    let mut query = Query {
        sql: String::new(),
        values: Vec::new(),
        matches: Vec::new(),
    };
    let mut groups = Vec::new();
    let mut terms = Vec::new();
    let mut anywhere = false;
    for token in tokens {
        if token == "OR" {
            if terms.is_empty() {
                return Err("local_search_unsupported");
            }
            groups.push(format!("({})", terms.join(" AND ")));
            terms.clear();
            continue;
        }
        let negative = token.starts_with('-');
        let token = token.strip_prefix('-').unwrap_or(&token);
        if token.is_empty() || token.contains(['(', ')', '{', '}']) {
            return Err("local_search_unsupported");
        }
        let (field, text) = if token.starts_with('"') {
            ("", token)
        } else {
            token.split_once(':').unwrap_or(("", token))
        };
        let text = text.trim_matches('"');
        if text.is_empty() {
            return Err("local_search_unsupported");
        }
        let predicate = match field {
            "in" if matches!(text, "anywhere" | "all") => {
                anywhere = true;
                "1".into()
            }
            "in" | "label" | "is" => {
                let label = match text.to_lowercase().as_str() {
                    "inbox" => "INBOX",
                    "sent" => "SENT",
                    "draft" | "drafts" => "DRAFT",
                    "trash" => "TRASH",
                    "spam" => "SPAM",
                    "unread" => "UNREAD",
                    "starred" => "STARRED",
                    "important" => "IMPORTANT",
                    _ if field == "label" => text,
                    _ => return Err("local_search_unsupported"),
                };
                if matches!(label, "SPAM" | "TRASH") && !negative {
                    anywhere = true;
                }
                query.values.push(Value::Text(label.into()));
                let n = query.values.len();
                format!(
                    "EXISTS(SELECT 1 FROM labels l WHERE l.message_id=m.id AND (l.label=?{n} OR l.label IN (SELECT id FROM label_names WHERE name=?{n} COLLATE NOCASE)))"
                )
            }
            "has" if text == "attachment" => "m.has_attachment=1".into(),
            "category"
                if matches!(
                    text,
                    "personal" | "social" | "promotions" | "updates" | "forums"
                ) =>
            {
                query
                    .values
                    .push(Value::Text(format!("CATEGORY_{}", text.to_uppercase())));
                format!(
                    "EXISTS(SELECT 1 FROM labels l WHERE l.message_id=m.id AND l.label=?{})",
                    query.values.len()
                )
            }
            "before" | "after" => {
                let date = NaiveDate::parse_from_str(&text.replace('/', "-"), "%Y-%m-%d")
                    .map_err(|_| "local_search_unsupported")?;
                let date = Local
                    .from_local_datetime(
                        &date
                            .and_hms_opt(0, 0, 0)
                            .ok_or("local_search_unsupported")?,
                    )
                    .earliest()
                    .ok_or("local_search_unsupported")?;
                query.values.push(Value::Integer(date.timestamp_millis()));
                format!(
                    "m.date{}?{}",
                    if field == "before" { "<" } else { ">=" },
                    query.values.len()
                )
            }
            "from" | "to" | "cc" | "filename" => {
                let column = match field {
                    "from" => "sender",
                    "to" => "recipients",
                    "cc" => "copied",
                    _ => "filenames",
                };
                let value = text
                    .to_lowercase()
                    .replace('\\', "\\\\")
                    .replace('%', "\\%")
                    .replace('_', "\\_");
                query.values.push(Value::Text(format!("%{value}%")));
                format!("m.{column} LIKE ?{} ESCAPE '\\'", query.values.len())
            }
            "" | "subject" => {
                let prefix = text.ends_with('*') && !token.ends_with('"');
                let text = if prefix {
                    &text[..text.len() - 1]
                } else {
                    text
                };
                if text.contains('*') || text.is_empty() {
                    return Err("local_search_unsupported");
                }
                let term = format!(
                    "{}\"{}\"{}",
                    if field == "subject" { "subject:" } else { "" },
                    text.replace('"', "\"\""),
                    if prefix { "*" } else { "" }
                );
                query.values.push(Value::Text(term));
                query.matches.push(query.values.len());
                format!(
                    "m.rowid IN (SELECT rowid FROM search WHERE search MATCH ?{})",
                    query.values.len()
                )
            }
            _ => return Err("local_search_unsupported"),
        };
        terms.push(if negative {
            format!("NOT ({predicate})")
        } else {
            format!("({predicate})")
        });
    }
    if terms.is_empty() && !groups.is_empty() {
        return Err("local_search_unsupported");
    }
    if !terms.is_empty() {
        groups.push(format!("({})", terms.join(" AND ")));
    }
    query.sql = if groups.is_empty() {
        "1".into()
    } else {
        format!("({})", groups.join(" OR "))
    };
    if !anywhere {
        query.sql.push_str(" AND NOT EXISTS(SELECT 1 FROM labels l WHERE l.message_id=m.id AND l.label IN ('SPAM','TRASH'))");
    }
    Ok(query)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn search_values_never_become_sql() {
        let query = parse("from:\"x' OR 1=1 --\" subject:\"a b\" -is:unread OR café*").unwrap();
        assert!(!query.sql.contains("x'"));
        assert_eq!(query.values.len(), 4);
        assert!(query.sql.contains("NOT ("));
        assert!(parse("larger:1M").is_err());
        assert!(parse("\"unclosed").is_err());
        assert!(parse("a OR").is_err());
        assert!(parse("a*b").is_err());
    }
}
