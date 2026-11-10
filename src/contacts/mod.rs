//! Bounded, read-only contact discovery. No subprocesses or network access.
use serde_json::{Value, json};
#[cfg(unix)]
use std::os::unix::fs::OpenOptionsExt;
use std::{
    collections::BTreeMap,
    fs,
    io::Read,
    path::{Path, PathBuf},
};

const MAX_FILE: u64 = 16 * 1024 * 1024;
const MAX_CONTACTS: usize = 10000;
type Book = BTreeMap<String, Value>;

fn address(email: &str) -> bool {
    let Some((local, domain)) = email.split_once('@') else {
        return false;
    };
    !local.is_empty()
        && !local.chars().any(|character| {
            character.is_control() || character.is_whitespace() || "@<>,;\"\\".contains(character)
        })
        && domain.split('.').count() >= 2
        && domain.split('.').all(|part| {
            !part.is_empty()
                && part
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
        })
        && domain.rsplit('.').next().is_some_and(|part| {
            part.len() >= 2 && part.bytes().all(|byte| byte.is_ascii_alphabetic())
        })
}
fn collect(book: &mut Book, name: &str, email: &str) {
    let email = email.trim();
    if !address(email) {
        return;
    }
    let key = email.to_lowercase();
    if book.len() >= MAX_CONTACTS && !book.contains_key(&key) {
        return;
    }
    let name: String = name
        .trim()
        .chars()
        .filter(|character| !character.is_control())
        .collect();
    if !book.contains_key(&key) || (book[&key]["name"] == "" && !name.is_empty()) {
        book.insert(key, json!({"name":name,"email":email}));
    }
}
#[cfg(unix)]
fn read(path: &Path) -> Option<String> {
    let file = fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(path)
        .ok()?;
    if !file.metadata().ok()?.is_file() {
        return None;
    }
    let mut bytes = Vec::new();
    file.take(MAX_FILE + 1).read_to_end(&mut bytes).ok()?;
    (bytes.len() as u64 <= MAX_FILE).then(|| String::from_utf8_lossy(&bytes).into_owned())
}
fn json_book(book: &mut Book, raw: &Value) {
    if let Some(items) = raw.as_array() {
        for item in items {
            collect(
                book,
                item["name"].as_str().unwrap_or(""),
                item["email"].as_str().unwrap_or(""),
            );
        }
    } else if let Some(items) = raw.as_object() {
        for (key, value) in items {
            if address(key.trim()) {
                collect(book, value.as_str().unwrap_or(""), key);
            } else if let Some(email) = value.as_str() {
                collect(book, key, email);
            }
        }
    }
}
fn vcard(book: &mut Book, text: &str) {
    let text = text
        .replace("\r\n", "\n")
        .replace("\n ", "")
        .replace("\n\t", "");
    let mut name = "";
    let mut emails = Vec::new();
    for line in text.lines() {
        let line = line.trim();
        let Some((property, value)) = line.split_once(':') else {
            continue;
        };
        match property.split(';').next().unwrap_or("") {
            "BEGIN" if value == "VCARD" => {
                name = "";
                emails.clear();
            }
            "FN" => name = value.trim(),
            "EMAIL" => emails.push(value.trim()),
            "END" if value == "VCARD" => {
                for email in emails.drain(..) {
                    collect(book, name, email)
                }
            }
            _ => (),
        }
    }
}
fn paths(dir: &Path) -> Vec<PathBuf> {
    let mut result: Vec<_> = fs::read_dir(dir)
        .into_iter()
        .flatten()
        .filter_map(Result::ok)
        .take(2000)
        .map(|entry| entry.path())
        .collect();
    result.sort();
    result
}
fn message_contacts(row: &Value) -> Vec<&Value> {
    let mut people = vec![&row["from"], &row["replyTo"]];
    for field in ["to", "cc"] {
        if let Some(items) = row[field].as_array().filter(|items| items.len() <= 5) {
            people.extend(items);
        }
    }
    people
}
fn cache_contacts(query: &Value) -> impl Iterator<Item = &Value> {
    query["summaries"]
        .as_array()
        .filter(|rows| !rows.is_empty())
        .or_else(|| query["messages"].as_array())
        .into_iter()
        .flatten()
        .flat_map(message_contacts)
}
fn cache(book: &mut Book, dir: &Path) {
    let mut harvested = 0;
    for file in paths(dir).into_iter().filter(|path| {
        path.file_name().is_some_and(|name| {
            let name = name.to_string_lossy();
            name.starts_with("account-") && name.ends_with(".json")
        })
    }) {
        let Some(raw) = read(&file).and_then(|text| serde_json::from_str::<Value>(&text).ok())
        else {
            continue;
        };
        let Some(queries) = raw["queries"].as_object() else {
            continue;
        };
        for person in queries.values().flat_map(cache_contacts) {
            let email = person["email"].as_str().unwrap_or("");
            if !address(email) {
                continue;
            }
            if harvested >= 2000 {
                return;
            }
            harvested += 1;
            let name = person["name"]
                .as_str()
                .filter(|name| !name.is_empty())
                .or_else(|| person["display"].as_str())
                .unwrap_or("");
            collect(
                book,
                if email.split('@').next() == Some(name) {
                    ""
                } else {
                    name
                },
                email,
            );
        }
    }
}
fn thunderbird_profiles(root: &Path) -> Vec<PathBuf> {
    let mut profiles = paths(root);
    profiles.extend(paths(&root.join("Profiles")));
    if let Some(ini) = read(&root.join("profiles.ini")) {
        let mut section = false;
        let mut path = None;
        let mut relative = true;
        for line in ini.lines().chain(std::iter::once("[end]")) {
            let line = line.trim();
            if line.starts_with('[') {
                if section && let Some(profile) = path.take() {
                    let profile = PathBuf::from(profile);
                    profiles.push(if relative {
                        root.join(profile)
                    } else {
                        profile
                    });
                }
                section = line.to_lowercase().starts_with("[profile");
                relative = true;
            } else if let Some(value) = line.strip_prefix("Path=") {
                path = Some(value.to_string())
            } else if line == "IsRelative=0" {
                relative = false
            }
        }
    }
    profiles.sort();
    profiles.dedup();
    profiles
}

fn thunderbird(book: &mut Book, root: &Path) {
    for profile in thunderbird_profiles(root) {
        for database in paths(&profile).into_iter().filter(|path| {
            path.file_name().is_some_and(|name| {
                let name = name.to_string_lossy();
                (name.starts_with("abook") || name.starts_with("history"))
                    && name.ends_with(".sqlite")
            })
        }) {
            thunderbird_book(book, &database);
        }
    }
}
fn thunderbird_book(book: &mut Book, database: &Path) {
    let Ok(connection) = rusqlite::Connection::open_with_flags(
        database,
        rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY | rusqlite::OpenFlags::SQLITE_OPEN_NO_MUTEX,
    ) else {
        return;
    };
    let _ = connection.busy_timeout(std::time::Duration::from_millis(200));
    let Ok(mut query) = connection.prepare(
        "SELECT MAX(CASE WHEN name='DisplayName' THEN value ELSE '' END),
                MAX(CASE WHEN name='PrimaryEmail' THEN value ELSE '' END),
                MAX(CASE WHEN name='SecondEmail' THEN value ELSE '' END)
         FROM properties GROUP BY card LIMIT 10000",
    ) else {
        return;
    };
    let Ok(rows) = query.query_map([], |row| {
        Ok((
            row.get::<_, String>(0)?,
            row.get::<_, String>(1)?,
            row.get::<_, String>(2)?,
        ))
    }) else {
        return;
    };
    for (name, email, second) in rows.flatten() {
        collect(book, &name, &email);
        collect(book, &name, &second)
    }
}

pub fn suggest() -> Result<Value, &'static str> {
    let dirs = crate::platform::dirs::AppDirs::discover()?;
    Ok(discover(
        &crate::platform::dirs::AppDirs::home()?,
        &dirs.config,
        &dirs.cache,
    ))
}

fn discover(home: &Path, config: &Path, cached: &Path) -> Value {
    let mut book = Book::new();
    for name in [".thunderbird", ".betterbird"] {
        thunderbird(&mut book, &home.join(name))
    }
    cache(&mut book, &cached.join("omamail"));
    if let Some(raw) = read(&config.join("omamail/contacts.json"))
        .and_then(|s| serde_json::from_str::<Value>(&s).ok())
    {
        json_book(&mut book, &raw)
    }
    if let Some(text) = read(&config.join("omamail/contacts.vcf")) {
        vcard(&mut book, &text)
    }
    let mut values: Vec<_> = book.into_values().collect();
    values.sort_by_key(|v| {
        v["name"]
            .as_str()
            .filter(|s| !s.is_empty())
            .unwrap_or(v["email"].as_str().unwrap_or(""))
            .to_lowercase()
    });
    json!(values)
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn reads_real_sqlite_and_cache_without_writing_sources() {
        let root =
            std::env::temp_dir().join(format!("omamail-contacts-test-{}", std::process::id()));
        let profile = root.join(".thunderbird/profile");
        fs::create_dir_all(&profile).unwrap();
        let database = profile.join("abook.sqlite");
        {
            let db = rusqlite::Connection::open(&database).unwrap();
            db.execute_batch("CREATE TABLE properties(card TEXT,name TEXT,value TEXT); INSERT INTO properties VALUES ('1','DisplayName','Alice'),('1','PrimaryEmail','alice@example.com');").unwrap();
        }
        let before = fs::read(&database).unwrap();
        fs::create_dir_all(root.join("cache/omamail")).unwrap();
        let bulk: Vec<_> = (0..6)
            .map(|index| json!({"email":format!("bulk{index}@example.com")}))
            .collect();
        fs::write(root.join("cache/omamail/account-a.json"),json!({"queries":{"inbox":{"summaries":[{"from":{"email":"bob@example.com","name":"bob"},"bcc":[{"email":"hidden@example.com"}],"to":bulk}]}}}).to_string()).unwrap();
        let result = discover(&root, &root.join("config"), &root.join("cache"));
        assert_eq!(result.as_array().unwrap().len(), 2);
        assert_eq!(result[0]["name"], "Alice");
        assert_eq!(result[1]["name"], "");
        assert_eq!(before, fs::read(&database).unwrap());
        fs::remove_dir_all(root).unwrap();
    }
    #[test]
    fn validates_addresses_without_coercing_objects() {
        let mut book = Book::new();
        json_book(
            &mut book,
            &json!({"contacts":[{"email":"a@example.com"}],"Jane":"jane@example.com","bad":"a@example.com\nInjected"}),
        );
        assert_eq!(book.len(), 1);
        assert!(book.contains_key("jane@example.com"));
    }
    #[test]
    fn unfolds_cards_and_skips_malformed_lines() {
        let mut book = Book::new();
        vcard(
            &mut book,
            "BEGIN:VCARD\nFN:Jane\nEMAIL broken\nEMAIL:a@exam\n ple.com\nEND:VCARD\n",
        );
        assert_eq!(book["a@example.com"]["name"], "Jane");
    }
    #[test]
    fn contact_limit_allows_existing_address_name_updates() {
        let mut book = Book::new();
        for index in 0..MAX_CONTACTS {
            collect(&mut book, "", &format!("contact{index}@example.com"));
        }
        collect(&mut book, "Updated Name", "contact0@example.com");
        collect(&mut book, "New Contact", "overflow@example.com");
        assert_eq!(book.len(), MAX_CONTACTS);
        assert_eq!(book["contact0@example.com"]["name"], "Updated Name");
        assert!(!book.contains_key("overflow@example.com"));
    }
    #[test]
    fn named_contact_replaces_inferred_empty_name() {
        let mut book = Book::new();
        collect(&mut book, "", "A@example.com");
        collect(&mut book, "Alice", "a@example.com");
        assert_eq!(book.len(), 1);
        assert_eq!(book["a@example.com"]["name"], "Alice");
    }
}

#[cfg(windows)]
fn read(path: &Path) -> Option<String> {
    let file = crate::platform::private_fs::open_external(path).ok()?;
    if file.metadata().ok()?.len() > MAX_FILE {
        return None;
    }
    let mut bytes = Vec::new();
    file.take(MAX_FILE + 1).read_to_end(&mut bytes).ok()?;
    (bytes.len() as u64 <= MAX_FILE).then(|| String::from_utf8_lossy(&bytes).into_owned())
}

#[cfg(feature = "mobile")]
pub(crate) fn from_summaries(rows: &Value) -> Value {
    let mut book = Book::new();
    for row in rows.as_array().into_iter().flatten() {
        for person in std::iter::once(&row["from"])
            .chain(row["to"].as_array().into_iter().flatten())
            .chain(row["cc"].as_array().into_iter().flatten())
        {
            collect(
                &mut book,
                person["name"].as_str().unwrap_or(""),
                person["email"].as_str().unwrap_or(""),
            );
        }
    }
    json!(book.into_values().collect::<Vec<_>>())
}
