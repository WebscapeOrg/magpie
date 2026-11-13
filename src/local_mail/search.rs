use chrono::{FixedOffset, NaiveDate, TimeZone, Utc};
use rusqlite::types::Value;
use std::collections::HashMap;

type Result<T> = std::result::Result<T, &'static str>;
const INVALID: &str = "local_search_invalid";
const UNSUPPORTED: &str = "local_search_unsupported";
const LENGTH: &str = "query_length";
const CONTROL: &str = "query_control";
const QUOTE: &str = "query_quote";
const ESCAPE: &str = "query_escape";
const GROUP: &str = "query_group";
const VALUE: &str = "query_value";
const DATE: &str = "query_date";
const PERIOD: &str = "query_period";
const COMPLEX: &str = "query_complex";
const MAX_TOKENS: usize = 128;
const MAX_DEPTH: usize = 16;

pub(super) struct Query {
    pub sql: String,
    pub values: Vec<Value>,
    matches: Vec<usize>,
}

impl Query {
    pub(super) fn choose_plan(&mut self, db: &rusqlite::Connection) -> Result<()> {
        for index in &self.matches {
            let count: i64 = super::store::sql(db.query_row(
                "SELECT count(*) FROM (SELECT rowid FROM search WHERE search MATCH ?1 LIMIT 10001)",
                [&self.values[index - 1]],
                |row| row.get(0),
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

    fn parameter(&mut self, value: Value) -> usize {
        self.values.push(value);
        self.values.len()
    }

    fn compile(&mut self, expression: &Expression) -> Result<String> {
        Ok(match expression {
            Expression::All => "1".into(),
            Expression::And(left, right) => {
                format!("({} AND {})", self.compile(left)?, self.compile(right)?)
            }
            Expression::Or(left, right) => {
                format!("({} OR {})", self.compile(left)?, self.compile(right)?)
            }
            Expression::Not(inner) => format!("NOT ({})", self.compile(inner)?),
            Expression::Term(term) => self.compile_term(term)?,
        })
    }

    fn compile_term(&mut self, term: &Term) -> Result<String> {
        Ok(match term {
            Term::Unknown => return Err(UNSUPPORTED),
            Term::Anywhere => "1".into(),
            Term::Attachment => "m.has_attachment=1".into(),
            Term::Label(label) => {
                let index = self.parameter(Value::Text(label.clone()));
                format!(
                    "EXISTS(SELECT 1 FROM labels l WHERE l.message_id=m.id AND (l.label=?{index} OR l.label IN (SELECT id FROM label_names WHERE name=?{index} COLLATE NOCASE)))"
                )
            }
            Term::Date { before, millis } => {
                let index = self.parameter(Value::Integer(*millis));
                format!("m.date{}?{index}", if *before { "<" } else { ">=" })
            }
            Term::Address { field, text, exact } => {
                if *exact {
                    let index = self.parameter(Value::Text(text.to_ascii_lowercase()));
                    if field == "from" {
                        format!(
                            "COALESCE(json_extract(m.summary,'$.from.email'),'')=?{index} COLLATE NOCASE"
                        )
                    } else {
                        format!(
                            "EXISTS(SELECT 1 FROM json_each(m.summary,'$.{field}') recipient WHERE json_extract(recipient.value,'$.email')=?{index} COLLATE NOCASE)"
                        )
                    }
                } else {
                    self.contains(
                        match field.as_str() {
                            "from" => "sender",
                            "to" => "recipients",
                            _ => "copied",
                        },
                        text,
                    )
                }
            }
            Term::Filename(text) => self.contains("filenames", text),
            Term::Text {
                subject,
                text,
                prefix,
            } => {
                let term = format!(
                    "{}\"{}\"{}",
                    if *subject { "subject:" } else { "" },
                    text.replace('"', "\"\""),
                    if *prefix { "*" } else { "" }
                );
                let index = self.parameter(Value::Text(term));
                self.matches.push(index);
                format!("m.rowid IN (SELECT rowid FROM search WHERE search MATCH ?{index})")
            }
        })
    }

    fn contains(&mut self, column: &str, text: &str) -> String {
        let value = text
            .to_lowercase()
            .replace('\\', "\\\\")
            .replace('%', "\\%")
            .replace('_', "\\_");
        let index = self.parameter(Value::Text(format!("%{value}%")));
        format!("m.{column} LIKE ?{index} ESCAPE '\\'")
    }
}

enum Term {
    Unknown,
    Anywhere,
    Attachment,
    Label(String),
    Date {
        before: bool,
        millis: i64,
    },
    Address {
        field: String,
        text: String,
        exact: bool,
    },
    Filename(String),
    Text {
        subject: bool,
        text: String,
        prefix: bool,
    },
}

enum Expression {
    All,
    Term(Term),
    And(Box<Expression>, Box<Expression>),
    Or(Box<Expression>, Box<Expression>),
    Not(Box<Expression>),
}

impl Expression {
    fn includes_spam_trash(&self, negative: bool) -> bool {
        match self {
            Self::Term(Term::Anywhere) => !negative,
            Self::Term(Term::Label(label)) => {
                !negative && matches!(label.as_str(), "SPAM" | "TRASH")
            }
            Self::And(left, right) | Self::Or(left, right) => {
                left.includes_spam_trash(negative) || right.includes_spam_trash(negative)
            }
            Self::Not(inner) => inner.includes_spam_trash(!negative),
            _ => false,
        }
    }

    fn labels_match(&self, labels: &[String], names: &HashMap<String, String>) -> Option<bool> {
        match self {
            Self::All | Self::Term(Term::Anywhere) => Some(true),
            Self::Term(Term::Label(wanted)) => Some(labels.iter().any(|id| {
                id == wanted
                    || names
                        .get(id)
                        .is_some_and(|name| name.eq_ignore_ascii_case(wanted))
            })),
            Self::And(left, right) => match (
                left.labels_match(labels, names),
                right.labels_match(labels, names),
            ) {
                (Some(false), _) | (_, Some(false)) => Some(false),
                (Some(true), Some(true)) => Some(true),
                _ => None,
            },
            Self::Or(left, right) => match (
                left.labels_match(labels, names),
                right.labels_match(labels, names),
            ) {
                (Some(true), _) | (_, Some(true)) => Some(true),
                (Some(false), Some(false)) => Some(false),
                _ => None,
            },
            Self::Not(inner) => inner.labels_match(labels, names).map(|value| !value),
            _ => None,
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
enum Token {
    Word(String),
    And,
    Or,
    Not,
    Open,
    Close,
    OpenAny,
    CloseAny,
}

impl Token {
    fn starts_expression(&self) -> bool {
        matches!(self, Self::Word(_) | Self::Not | Self::Open | Self::OpenAny)
    }
}

fn tokenize(input: &str) -> Result<Vec<Token>> {
    if input.len() > 32768 {
        return Err(LENGTH);
    }
    if input.chars().any(char::is_control) {
        return Err(CONTROL);
    }
    let mut tokens = Vec::new();
    let mut chars = input.chars().peekable();
    while let Some(ch) = chars.next() {
        if ch.is_whitespace() {
            continue;
        }
        let token = match ch {
            '(' => Token::Open,
            ')' => Token::Close,
            '{' => Token::OpenAny,
            '}' => Token::CloseAny,
            '-' => Token::Not,
            _ => {
                let mut raw = String::new();
                let mut quoted = false;
                let mut url_parentheses = 0usize;
                let mut url_braces = 0usize;
                let mut current = Some(ch);
                while let Some(ch) = current {
                    raw.push(ch);
                    if ch == '\\' {
                        raw.push(chars.next().ok_or(ESCAPE)?);
                    } else if ch == '"' {
                        quoted = !quoted;
                    }
                    let uri = uri_word(&raw);
                    if uri && !quoted {
                        match ch {
                            '(' => url_parentheses += 1,
                            ')' => url_parentheses = url_parentheses.saturating_sub(1),
                            '{' => url_braces += 1,
                            '}' => url_braces = url_braces.saturating_sub(1),
                            _ => (),
                        }
                    }
                    if !quoted
                        && chars.peek().is_some_and(|next| {
                            next.is_whitespace()
                                || match next {
                                    '(' | '{' => !uri,
                                    ')' => !uri || url_parentheses == 0,
                                    '}' => !uri || url_braces == 0,
                                    _ => false,
                                }
                        })
                    {
                        break;
                    }
                    current = chars.next();
                }
                if quoted {
                    return Err(QUOTE);
                }
                match raw.as_str() {
                    "AND" => Token::And,
                    "OR" => Token::Or,
                    _ => Token::Word(raw),
                }
            }
        };
        tokens.push(token);
        if tokens.len() > MAX_TOKENS {
            return Err(COMPLEX);
        }
    }
    Ok(tokens)
}

struct Parser<'a> {
    tokens: Vec<Token>,
    position: usize,
    account_email: &'a str,
    anchor_ms: i64,
}

impl<'a> Parser<'a> {
    fn new(input: &str, account_email: &'a str, anchor_ms: i64) -> Result<Self> {
        Ok(Self {
            tokens: tokenize(input)?,
            position: 0,
            account_email,
            anchor_ms,
        })
    }

    fn parse(mut self) -> Result<Expression> {
        if self.tokens.is_empty() {
            return Ok(Expression::All);
        }
        let expression = self.disjunction("", false, 0)?;
        if self.position != self.tokens.len() {
            return Err(GROUP);
        }
        Ok(expression)
    }

    fn disjunction(&mut self, field: &str, implicit_or: bool, depth: usize) -> Result<Expression> {
        let mut result = self.conjunction(field, implicit_or, depth)?;
        loop {
            match self.tokens.get(self.position) {
                Some(Token::Or) => self.position += 1,
                Some(token) if implicit_or && token.starts_expression() => (),
                _ => break,
            }
            result = Expression::Or(
                Box::new(result),
                Box::new(self.conjunction(field, implicit_or, depth)?),
            );
        }
        Ok(result)
    }

    fn conjunction(&mut self, field: &str, implicit_or: bool, depth: usize) -> Result<Expression> {
        let mut result = self.unary(field, depth)?;
        loop {
            match self.tokens.get(self.position) {
                Some(Token::And) => self.position += 1,
                Some(token) if !implicit_or && token.starts_expression() => (),
                _ => break,
            }
            result = Expression::And(Box::new(result), Box::new(self.unary(field, depth)?));
        }
        Ok(result)
    }

    fn unary(&mut self, inherited_field: &str, depth: usize) -> Result<Expression> {
        if depth > MAX_DEPTH {
            return Err(COMPLEX);
        }
        let token = self.tokens.get(self.position).cloned().ok_or(INVALID)?;
        self.position += 1;
        match token {
            Token::Not => Ok(Expression::Not(Box::new(
                self.unary(inherited_field, depth + 1)?,
            ))),
            Token::Open | Token::OpenAny => self.group(inherited_field, token, depth + 1),
            Token::Word(raw) => {
                let (field, value) = split_field(&raw);
                let field = field.unwrap_or(inherited_field);
                if value.is_empty() && !field.is_empty() {
                    return match self.tokens.get(self.position).cloned() {
                        Some(token @ (Token::Open | Token::OpenAny)) => {
                            self.position += 1;
                            self.group(field, token, depth + 1)
                        }
                        _ => Err(VALUE),
                    };
                }
                self.term(field, value)
            }
            _ => Err(INVALID),
        }
    }

    fn group(&mut self, field: &str, opening: Token, depth: usize) -> Result<Expression> {
        let any = opening == Token::OpenAny;
        let result = self.disjunction(field, any, depth)?;
        let closing = if any { Token::CloseAny } else { Token::Close };
        if self.tokens.get(self.position) != Some(&closing) {
            return Err(GROUP);
        }
        self.position += 1;
        Ok(result)
    }

    fn term(&self, field: &str, raw: &str) -> Result<Expression> {
        let (text, quoted) = decode_word(raw)?;
        if text.is_empty() {
            return Err(VALUE);
        }
        let term = match field {
            "in" if matches!(text.as_str(), "anywhere" | "all") => Term::Anywhere,
            "is" if text.eq_ignore_ascii_case("read") => {
                return Ok(Expression::Not(Box::new(Expression::Term(Term::Label(
                    "UNREAD".into(),
                )))));
            }
            "in" | "is" | "label" => match system_label(&text) {
                Some(label) => Term::Label(label.into()),
                None if field == "label" => Term::Label(text),
                _ => Term::Unknown,
            },
            "category" => match text.to_lowercase().as_str() {
                "primary" | "personal" => Term::Label("CATEGORY_PERSONAL".into()),
                "social" | "promotions" | "updates" | "forums" => {
                    Term::Label(format!("CATEGORY_{}", text.to_uppercase()))
                }
                _ => Term::Unknown,
            },
            "has" if text == "attachment" => Term::Attachment,
            "before" | "after" => Term::Date {
                before: field == "before",
                millis: absolute_date(&text)?,
            },
            "older_than" | "newer_than" => Term::Date {
                before: field == "older_than",
                millis: relative_date(&text, self.anchor_ms)?,
            },
            "from" | "to" | "cc" => {
                let text = if text.eq_ignore_ascii_case("me") {
                    if self.account_email.is_empty() {
                        return Ok(Expression::Term(Term::Unknown));
                    }
                    self.account_email.to_owned()
                } else {
                    text
                };
                let exact = text
                    .split_once('@')
                    .is_some_and(|(name, domain)| !name.is_empty() && !domain.is_empty())
                    && !text.chars().any(char::is_whitespace);
                Term::Address {
                    field: field.into(),
                    text,
                    exact,
                }
            }
            "filename" => Term::Filename(text),
            "" | "subject" => {
                if (!quoted && (raw == "AROUND" || raw.starts_with('+'))) || proximity_query(&text)
                {
                    return Ok(Expression::Term(Term::Unknown));
                }
                let prefix = !quoted && unescaped_prefix(raw);
                let text = if prefix {
                    text[..text.len() - 1].to_owned()
                } else {
                    text
                };
                if text.is_empty() || text.contains('*') {
                    Term::Unknown
                } else {
                    Term::Text {
                        subject: field == "subject",
                        text,
                        prefix,
                    }
                }
            }
            _ => Term::Unknown,
        };
        Ok(Expression::Term(term))
    }
}

fn split_field(raw: &str) -> (Option<&str>, &str) {
    let Some((field, value)) = raw.split_once(':') else {
        return (None, raw);
    };
    if !field
        .as_bytes()
        .first()
        .is_some_and(u8::is_ascii_alphabetic)
        || !field
            .bytes()
            .all(|ch| ch.is_ascii_alphanumeric() || ch == b'_')
        || matches!(field, "http" | "https" | "ftp" | "mailto")
    {
        return (None, raw);
    }
    (Some(field), value)
}

fn uri_word(raw: &str) -> bool {
    ["http:", "https:", "ftp:", "mailto:"]
        .iter()
        .any(|prefix| raw.starts_with(prefix))
}

fn decode_word(raw: &str) -> Result<(String, bool)> {
    let mut text = String::new();
    let mut quoted = false;
    let mut chars = raw.chars();
    while let Some(ch) = chars.next() {
        match ch {
            '\\' => text.push(chars.next().ok_or(ESCAPE)?),
            '"' => quoted = true,
            _ => text.push(ch),
        }
    }
    Ok((text, quoted))
}

fn unescaped_prefix(raw: &str) -> bool {
    raw.strip_suffix('*')
        .is_some_and(|head| head.chars().rev().take_while(|ch| *ch == '\\').count() % 2 == 0)
}

fn proximity_query(text: &str) -> bool {
    let words = text.split_whitespace().collect::<Vec<_>>();
    words.windows(4).any(|parts| {
        parts[1] == "AROUND"
            && !parts[2].is_empty()
            && parts[2].bytes().all(|ch| ch.is_ascii_digit())
    })
}

fn system_label(text: &str) -> Option<&'static str> {
    match text.to_lowercase().as_str() {
        "inbox" => Some("INBOX"),
        "sent" => Some("SENT"),
        "draft" | "drafts" => Some("DRAFT"),
        "trash" => Some("TRASH"),
        "spam" => Some("SPAM"),
        "unread" => Some("UNREAD"),
        "starred" => Some("STARRED"),
        "important" => Some("IMPORTANT"),
        _ => None,
    }
}

fn absolute_date(text: &str) -> Result<i64> {
    if text.bytes().all(|ch| ch.is_ascii_digit()) {
        return text
            .parse::<i64>()
            .ok()
            .and_then(|seconds| seconds.checked_mul(1000))
            .ok_or(DATE);
    }
    let normalized = text.replace('/', "-");
    let date = NaiveDate::parse_from_str(&normalized, "%Y-%m-%d")
        .or_else(|_| NaiveDate::parse_from_str(&normalized, "%m-%d-%Y"))
        .map_err(|_| DATE)?;
    FixedOffset::west_opt(8 * 60 * 60)
        .and_then(|zone| {
            zone.from_local_datetime(&date.and_hms_opt(0, 0, 0)?)
                .single()
        })
        .map(|date| date.timestamp_millis())
        .ok_or(DATE)
}

fn relative_date(text: &str, anchor_ms: i64) -> Result<i64> {
    let (unit, number) = text.as_bytes().split_last().ok_or(PERIOD)?;
    if number.is_empty() || !number.iter().all(u8::is_ascii_digit) {
        return Err(PERIOD);
    }
    let days = match unit {
        b'd' => 1i64,
        b'm' => 30,
        b'y' => 365,
        _ => return Err(PERIOD),
    };
    let count = std::str::from_utf8(number)
        .ok()
        .and_then(|value| value.parse::<i64>().ok())
        .filter(|value| *value > 0)
        .ok_or(PERIOD)?;
    let duration = count
        .checked_mul(days)
        .and_then(|value| value.checked_mul(86_400_000))
        .ok_or(PERIOD)?;
    anchor_ms.checked_sub(duration).ok_or(PERIOD)
}

pub(super) fn parse(input: &str) -> Result<Query> {
    parse_with_context(input, "", Utc::now().timestamp_millis())
}

pub(super) fn parse_with_context(
    input: &str,
    account_email: &str,
    anchor_ms: i64,
) -> Result<Query> {
    let expression = Parser::new(input, account_email, anchor_ms)
        .and_then(Parser::parse)
        .map_err(|_| INVALID)?;
    let mut query = Query {
        sql: String::new(),
        values: Vec::new(),
        matches: Vec::new(),
    };
    query.sql = query.compile(&expression)?;
    if !expression.includes_spam_trash(false) {
        query.sql = format!(
            "({}) AND NOT EXISTS(SELECT 1 FROM labels l WHERE l.message_id=m.id AND l.label IN ('SPAM','TRASH'))",
            query.sql
        );
    }
    Ok(query)
}

pub(super) fn pending_match(
    input: &str,
    account_email: &str,
    anchor_ms: i64,
    effective_labels: &[String],
    label_names: &HashMap<String, String>,
) -> Option<bool> {
    let expression = Parser::new(input, account_email, anchor_ms)
        .ok()?
        .parse()
        .ok()?;
    if !expression.includes_spam_trash(false)
        && effective_labels
            .iter()
            .any(|label| matches!(label.as_str(), "SPAM" | "TRASH"))
    {
        return Some(false);
    }
    expression.labels_match(effective_labels, label_names)
}

pub(super) fn include_spam_trash(input: &str) -> bool {
    Parser::new(input, "", Utc::now().timestamp_millis())
        .and_then(Parser::parse)
        .is_ok_and(|expression| expression.includes_spam_trash(false))
}

pub(super) fn is_structured(input: &str) -> bool {
    match tokenize(input) {
        Ok(tokens) => tokens.iter().any(|token| match token {
            Token::Word(raw) => {
                split_field(raw).0.is_some()
                    || raw == "AROUND"
                    || raw.starts_with('+')
                    || decode_word(raw).is_ok_and(|(text, _)| proximity_query(&text))
            }
            _ => true,
        }),
        Err(_) => true,
    }
}

pub(super) fn diagnostic(input: &str, account_email: &str, anchor_ms: i64) -> Option<&'static str> {
    let error = Parser::new(input, account_email, anchor_ms)
        .and_then(Parser::parse)
        .err()?;
    Some(match error {
        LENGTH => "The search is too long. Remove some terms and try again.",
        CONTROL => "Remove line breaks and control characters from the search.",
        QUOTE => "Close the quoted phrase with a matching double quote.",
        ESCAPE => "Add a character after the final backslash, or remove the backslash.",
        GROUP => "Match each opening parenthesis or brace with its closing one.",
        VALUE => "Add a value after each filter, such as from:alice@example.com.",
        DATE => "Use a valid date such as after:2026/10/22, or a Unix timestamp in seconds.",
        PERIOD => "Use a positive whole number followed by d, m or y, such as newer_than:7d.",
        COMPLEX => "Use fewer search terms or nested groups.",
        _ => "Put a search term on both sides of AND or OR, and inside each group.",
    })
}

#[cfg(test)]
#[path = "search_tests.rs"]
mod tests;
