use serde::{Deserialize, Serialize};

pub const MAX_INPUT: usize = 16 * 1024 * 1024;
pub const MAX_NODES: usize = 100_000;
pub const MAX_DEPTH: usize = 128;
pub const MAX_OUTPUT: usize = 32 * 1024 * 1024;

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Attr {
    pub name: String,
    pub value: Option<String>,
}
#[derive(Clone, Debug, Deserialize)]
pub struct Node {
    #[serde(rename = "type")]
    pub kind: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub name: String,
    #[serde(default)]
    pub attrs: Vec<Attr>,
    #[serde(default)]
    pub children: Vec<Node>,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub text: String,
    #[serde(default, rename = "selfClosing")]
    pub self_closing: bool,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub raw: bool,
}
impl Serialize for Node {
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        use serde::ser::SerializeMap;
        let mut output = serializer.serialize_map(None)?;
        output.serialize_entry("type", &self.kind)?;
        if self.kind == "text" {
            output.serialize_entry("text", &self.text)?;
            if self.raw {
                output.serialize_entry("raw", &true)?;
            }
        } else {
            if self.kind != "root" {
                output.serialize_entry("name", &self.name)?;
                output.serialize_entry("attrs", &self.attrs)?;
                output.serialize_entry("selfClosing", &self.self_closing)?;
            }
            output.serialize_entry("children", &self.children)?;
        }
        output.end()
    }
}
impl Node {
    pub fn element(name: &str) -> Self {
        Self {
            kind: "element".into(),
            name: name.into(),
            attrs: vec![],
            children: vec![],
            text: String::new(),
            self_closing: false,
            raw: false,
        }
    }
    pub fn root() -> Self {
        let mut node = Self::element("");
        node.kind = "root".into();
        node
    }
    pub fn text(text: &str) -> Self {
        let mut node = Self::element("");
        node.kind = "text".into();
        node.text = text.into();
        node
    }
    pub fn attr(&self, name: &str) -> &str {
        self.attrs
            .iter()
            .find(|attribute| attribute.name == name)
            .and_then(|attribute| attribute.value.as_deref())
            .unwrap_or("")
    }
    pub fn has(&self, name: &str) -> bool {
        self.attrs.iter().any(|attribute| attribute.name == name)
    }
    pub fn remove(&mut self, name: &str) {
        self.attrs.retain(|attribute| attribute.name != name)
    }
    pub fn set(&mut self, name: &str, value: &str) {
        if let Some(attribute) = self
            .attrs
            .iter_mut()
            .find(|attribute| attribute.name == name)
        {
            attribute.value = Some(value.into())
        } else {
            self.attrs.push(Attr {
                name: name.into(),
                value: Some(value.into()),
            })
        }
    }
}
pub fn void(name: &str) -> bool {
    matches!(
        name,
        "img"
            | "br"
            | "hr"
            | "input"
            | "meta"
            | "link"
            | "area"
            | "base"
            | "col"
            | "embed"
            | "source"
            | "track"
            | "wbr"
            | "param"
            | "keygen"
    )
}
fn space(byte: u8) -> bool {
    matches!(byte, b' ' | b'\t' | b'\r' | b'\n' | 12)
}
fn name(byte: u8) -> bool {
    byte.is_ascii_alphanumeric() || matches!(byte, b':' | b'-' | b'_' | b'.')
}
struct Tag {
    node: Node,
    closing: bool,
    end: usize,
    terminated: bool,
}

fn tag(source: &str, start: usize) -> Option<Tag> {
    let bytes = source.as_bytes();
    let mut cursor = start + 1;
    let closing = bytes.get(cursor) == Some(&b'/');
    if closing {
        cursor += 1
    }
    if !bytes.get(cursor).is_some_and(u8::is_ascii_alphabetic) {
        return None;
    }
    let token_start = cursor;
    while cursor < bytes.len() && name(bytes[cursor]) {
        cursor += 1
    }
    let mut node = Node::element(&source[token_start..cursor].to_ascii_lowercase());
    while cursor < bytes.len() {
        while cursor < bytes.len() && space(bytes[cursor]) {
            cursor += 1
        }
        if cursor == bytes.len() {
            break;
        }
        if bytes[cursor] == b'>' {
            return Some(Tag {
                node,
                closing,
                end: cursor + 1,
                terminated: true,
            });
        }
        if bytes[cursor] == b'/' {
            node.self_closing = bytes.get(cursor + 1) == Some(&b'>');
            cursor += 1;
            continue;
        }
        let token_start = cursor;
        while cursor < bytes.len()
            && !space(bytes[cursor])
            && !matches!(bytes[cursor], b'=' | b'>' | b'/')
        {
            cursor += 1
        }
        if cursor == token_start {
            cursor += 1;
            continue;
        }
        let attribute_name = source[token_start..cursor].to_ascii_lowercase();
        while cursor < bytes.len() && space(bytes[cursor]) {
            cursor += 1
        }
        let mut value = None;
        if bytes.get(cursor) == Some(&b'=') {
            cursor += 1;
            while cursor < bytes.len() && space(bytes[cursor]) {
                cursor += 1
            }
            if bytes
                .get(cursor)
                .is_some_and(|byte| matches!(byte, b'\'' | b'"'))
            {
                let quote = bytes[cursor];
                cursor += 1;
                let token_start = cursor;
                while cursor < bytes.len() && bytes[cursor] != quote {
                    cursor += 1
                }
                value = Some(source[token_start..cursor].into());
                if cursor < bytes.len() {
                    cursor += 1
                }
            } else {
                let token_start = cursor;
                while cursor < bytes.len() && !space(bytes[cursor]) && bytes[cursor] != b'>' {
                    cursor += 1
                }
                value = Some(source[token_start..cursor].into())
            }
        }
        node.attrs.push(Attr {
            name: attribute_name,
            value,
        });
        if node.attrs.len() > 1024 {
            return Some(Tag {
                node,
                closing,
                end: bytes.len(),
                terminated: false,
            });
        }
    }
    Some(Tag {
        node,
        closing,
        end: bytes.len(),
        terminated: false,
    })
}
fn implied(new: &str, old: &str) -> bool {
    match new {
        "li" => old == "li",
        "p" => old == "p",
        "dt" | "dd" => matches!(old, "dt" | "dd"),
        "tr" => matches!(old, "tr" | "td" | "th"),
        "td" | "th" => matches!(old, "td" | "th"),
        "thead" | "tbody" | "tfoot" => matches!(old, "thead" | "tbody" | "tfoot"),
        "option" => old == "option",
        _ => false,
    }
}
fn finish(stack: &mut Vec<Node>) {
    let node = stack.pop().unwrap();
    stack.last_mut().unwrap().children.push(node)
}
fn emitted(count: &mut usize, nodes: usize) -> Result<(), &'static str> {
    *count = count.checked_add(nodes).ok_or("html_too_complex")?;
    if *count > MAX_NODES {
        return Err("html_too_complex");
    }
    Ok(())
}
pub fn parse(source: &str) -> Result<Node, &'static str> {
    if source.len() > MAX_INPUT {
        return Err("html_too_large");
    }
    let mut stack = vec![Node::root()];
    let mut at = 0;
    let mut count = 1;
    while at < source.len() {
        let Some(offset) = source[at..].find('<') else {
            emitted(&mut count, 1)?;
            stack
                .last_mut()
                .unwrap()
                .children
                .push(Node::text(&source[at..]));
            break;
        };
        let open = at + offset;
        if open > at {
            emitted(&mut count, 1)?;
            stack
                .last_mut()
                .unwrap()
                .children
                .push(Node::text(&source[at..open]))
        }
        if source[open..].starts_with("<!--") {
            at = source[open + 4..]
                .find("-->")
                .map_or(source.len(), |offset| open + 4 + offset + 3);
            continue;
        }
        if source[open..].starts_with("<!") || source[open..].starts_with("<?") {
            at = source[open..]
                .find('>')
                .map_or(source.len(), |offset| open + offset + 1);
            continue;
        }
        let Some(Tag {
            node: mut node,
            closing,
            end,
            terminated,
        }) = tag(source, open)
        else {
            emitted(&mut count, 1)?;
            stack.last_mut().unwrap().children.push(Node::text("<"));
            at = open + 1;
            continue;
        };
        at = end;
        if node.attrs.len() > 1024 {
            return Err("html_too_complex");
        }
        if !terminated {
            break;
        }
        if closing {
            if let Some(index) = stack
                .iter()
                .rposition(|ancestor| ancestor.name == node.name)
            {
                while stack.len() > index && stack.len() > 1 {
                    finish(&mut stack)
                }
            }
            continue;
        }
        while stack.len() > 1 && implied(&node.name, &stack.last().unwrap().name) {
            finish(&mut stack)
        }
        if matches!(
            node.name.as_str(),
            "script" | "style" | "textarea" | "title"
        ) && !node.self_closing
        {
            let needle = format!("</{}", node.name);
            let mut search = at;
            let mut found = None;
            while let Some(off) = source[search..].find('<') {
                let pos = search + off;
                let end = pos + needle.len();
                if source
                    .as_bytes()
                    .get(pos..end)
                    .is_some_and(|candidate| candidate.eq_ignore_ascii_case(needle.as_bytes()))
                    && source
                        .as_bytes()
                        .get(end)
                        .is_some_and(|byte| space(*byte) || matches!(byte, b'/' | b'>'))
                {
                    found = Some(pos);
                    break;
                }
                search = pos + 1
            }
            let stop = found.unwrap_or(source.len());
            emitted(&mut count, 2)?;
            let mut raw = Node::text(&source[at..stop]);
            raw.raw = true;
            node.children.push(raw);
            at = found
                .and_then(|pos| tag(source, pos).map(|tag| tag.end))
                .unwrap_or(source.len());
            stack.last_mut().unwrap().children.push(node);
            continue;
        }
        emitted(&mut count, 1)?;
        if void(&node.name) || node.self_closing || stack.len() >= MAX_DEPTH {
            stack.last_mut().unwrap().children.push(node)
        } else {
            stack.push(node)
        }
    }
    while stack.len() > 1 {
        finish(&mut stack)
    }
    Ok(stack.pop().unwrap())
}
pub fn escape_text(source: &str) -> String {
    source
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
}
pub fn serialize(node: &Node) -> Result<String, &'static str> {
    let mut output = String::new();
    write(node, &mut output)?;
    Ok(output)
}
fn write(node: &Node, output: &mut String) -> Result<(), &'static str> {
    if node.kind == "text" {
        output.push_str(&node.text.replace('<', "&lt;").replace('>', "&gt;"))
    } else {
        if node.kind != "root" {
            output.push('<');
            output.push_str(&node.name);
            for attribute in &node.attrs {
                output.push(' ');
                output.push_str(&attribute.name);
                if let Some(value) = &attribute.value {
                    output.push_str("=\"");
                    output.push_str(&value.replace('"', "&quot;"));
                    output.push('"')
                }
            }
            if void(&node.name) || node.self_closing {
                output.push_str(if node.self_closing { "/>" } else { ">" });
                return if output.len() > MAX_OUTPUT {
                    Err("html_output_too_large")
                } else {
                    Ok(())
                };
            }
            output.push('>')
        }
        for child in &node.children {
            write(child, output)?
        }
        if node.kind != "root" {
            output.push_str("</");
            output.push_str(&node.name);
            output.push('>')
        }
    }
    if output.len() > MAX_OUTPUT {
        Err("html_output_too_large")
    } else {
        Ok(())
    }
}
