//! Bounded native HTML preparation. Qt receives only the sanitized tree;
//! sender-controlled network resources are replaced with approved raster bytes.
macro_rules! re {
    ($pattern:literal) => {{
        static VALUE: std::sync::OnceLock<regex::Regex> = std::sync::OnceLock::new();
        #[allow(clippy::regex_creation_in_loops)] // Performance: OnceLock compiles once outside repeated work.
        let pattern = VALUE
            .get_or_init(|| regex::Regex::new($pattern).expect("constant HTML policy pattern"));
        pattern
    }};
}
mod policy;
mod reader;
#[cfg(test)]
mod tests;
mod tree;
pub(crate) use policy::decode as decode_entities;
pub use policy::is_public_url;
use policy::*;
use serde_json::{Value, json};
use std::collections::HashSet;
pub use tree::{Attr, Node, parse, serialize};
pub(crate) use tree::{MAX_DEPTH, MAX_NODES};

pub fn dropped(name: &str) -> bool {
    matches!(
        name,
        "script"
            | "style"
            | "iframe"
            | "object"
            | "embed"
            | "applet"
            | "noscript"
            | "meta"
            | "link"
            | "base"
            | "title"
            | "textarea"
    )
}
pub fn block(name: &str) -> bool {
    matches!(
        name,
        "p" | "div"
            | "tr"
            | "li"
            | "blockquote"
            | "section"
            | "article"
            | "header"
            | "footer"
            | "table"
            | "ul"
            | "ol"
            | "h1"
            | "h2"
            | "h3"
            | "h4"
            | "h5"
            | "h6"
    )
}
pub fn table_part(name: &str) -> bool {
    matches!(
        name,
        "table" | "thead" | "tbody" | "tfoot" | "tr" | "td" | "th"
    )
}
pub fn rows<'node>(node: &'node Node, output: &mut Vec<&'node Node>) {
    for child in &node.children {
        if child.kind == "text" || child.name == "table" {
            continue;
        }
        if child.name == "tr" {
            output.push(child)
        }
        rows(child, output)
    }
}
pub fn grid(node: &Node) -> bool {
    let mut table_rows = vec![];
    rows(node, &mut table_rows);
    table_rows
        .iter()
        .filter(|row| {
            row.children
                .iter()
                .filter(|child| matches!(child.name.as_str(), "td" | "th"))
                .count()
                >= 2
        })
        .count()
        >= 2
}
fn as_block(node: &mut Node) {
    let style = node.attr("style").to_owned();
    node.name = "div".into();
    node.attrs.clear();
    if !style.is_empty() {
        node.set("style", &style)
    }
}
fn flatten_parts(node: &mut Node) {
    for child in &mut node.children {
        if child.kind == "text" || child.name == "table" {
            continue;
        }
        flatten_parts(child);
        if table_part(&child.name) {
            as_block(child)
        }
    }
}
fn flatten_tables(node: &mut Node, limit: usize, depth: usize) {
    for child in &mut node.children {
        if child.kind == "text" {
            continue;
        }
        if child.name != "table" {
            flatten_tables(child, limit, depth);
            continue;
        }
        let keep = depth < limit && grid(child);
        flatten_tables(child, limit, depth + usize::from(keep));
        if !keep {
            flatten_parts(child);
            as_block(child)
        }
    }
}
fn collapse(node: &mut Node) {
    let mut kept = vec![];
    for mut child in std::mem::take(&mut node.children) {
        collapse(&mut child);
        if !child.attrs.is_empty() {
            kept.push(child);
            continue;
        }
        if matches!(child.name.as_str(), "span" | "font" | "small" | "big") {
            kept.extend(child.children);
            continue;
        }
        if matches!(
            child.name.as_str(),
            "div" | "section" | "article" | "aside" | "header" | "footer" | "main" | "nav"
        ) {
            let meaningful: Vec<_> = child
                .children
                .iter()
                .enumerate()
                .filter(|(_, value)| value.kind != "text" || !value.text.trim().is_empty())
                .collect();
            if meaningful.len() == 1 && block(&meaningful[0].1.name) {
                let index = meaningful[0].0;
                kept.push(child.children.remove(index));
                continue;
            }
        }
        kept.push(child)
    }
    node.children = kept
}
fn colour_attr(name: &str) -> bool {
    matches!(name, "bgcolor" | "bordercolor" | "color")
}
fn colour_style(name: &str) -> bool {
    matches!(
        name,
        "color" | "background" | "background-color" | "border-color" | "outline-color"
    )
}
fn resource(name: &str) -> bool {
    matches!(
        name,
        "background"
            | "srcset"
            | "lowsrc"
            | "dynsrc"
            | "poster"
            | "data"
            | "codebase"
            | "usemap"
            | "ping"
            | "formaction"
            | "longdesc"
            | "profile"
            | "manifest"
            | "archive"
            | "cite"
    )
}
fn clean_attrs(node: &mut Node, colors: bool, styles: Vec<(String, String)>) {
    let centre = !matches!(node.name.as_str(), "td" | "th");
    let mut seen = HashSet::new();
    let is_image = node.name == "img";
    let is_link = node.name == "a";
    node.attrs.retain(|attribute| {
        re!(r"^[a-z_:][a-z0-9_.:-]*$").is_match(&attribute.name)
            && !resource(&attribute.name)
            && !(attribute.name.ends_with(":href") || (attribute.name == "href" && !is_link))
            && !(attribute.name == "src" && !is_image)
            && !(colour_attr(&attribute.name) && !colors)
            && !re!(r"^on[a-z]+$").is_match(&attribute.name)
            && !(attribute.name == "href" && !safe_href(attribute.value.as_deref().unwrap_or("")))
            && !(centre
                && attribute.name == "align"
                && re!(r"(?i)^center\b").is_match(attribute.value.as_deref().unwrap_or("")))
            && seen.insert(attribute.name.clone())
    });
    if node.has("style") {
        let kept = styles
            .into_iter()
            .filter(|(name, value)| {
                !(!colors && colour_style(name))
                    && !(centre && name == "text-align" && re!(r"(?i)^center\b").is_match(value))
                    && !value.to_ascii_lowercase().contains("url")
                    && !value.contains('\\')
            })
            .collect::<Vec<_>>();
        set_style(node, &kept)
    }
}
fn bounded_option(options: &Value, key: &str, default: usize, cap: usize) -> usize {
    let Some(value) = options.get(key) else {
        return default;
    };
    let numeric = match value {
        Value::Null => 0.0,
        Value::Bool(value) => {
            if *value {
                1.0
            } else {
                0.0
            }
        }
        Value::String(value) => value.trim().parse().unwrap_or(0.0),
        value => value.as_f64().unwrap_or(0.0),
    };
    numeric.floor().max(0.0).min(cap as f64) as usize
}
fn has_data_scheme(source: &str) -> bool {
    let scheme = re!(r"(?i)^data:");
    scheme.is_match(source) || scheme.is_match(&normalized(source))
}

pub(super) struct Images<'a> {
    options: &'a Value,
    pub kept: usize,
    pub blocked: usize,
    loadable: usize,
    sources: Vec<String>,
    pub limit: usize,
    admitted: usize,
    embedded_bytes: usize,
    decoded_bytes: u64,
}
impl<'a> Images<'a> {
    pub fn new(options: &'a Value) -> Self {
        Self {
            options,
            kept: 0,
            blocked: 0,
            loadable: 0,
            sources: vec![],
            limit: bounded_option(options, "maxImages", 24, 256),
            admitted: 0,
            embedded_bytes: 0,
            decoded_bytes: 0,
        }
    }
    pub fn prepared(&self, source: &str) -> String {
        self.options
            .get("remoteImageData")
            .and_then(|prepared_images| prepared_images.get(source))
            .and_then(Value::as_str)
            .filter(|source| raster(source))
            .unwrap_or("")
            .into()
    }
    pub fn allowed(&self) -> bool {
        self.options.get("allowRemoteImages") == Some(&Value::Bool(true))
    }
    // Invariant: both renderers admit only measured raster bytes. Unknown CID
    // payloads and compressed images cannot bypass the shared memory budgets.
    fn admit(&mut self, source: &str) -> bool {
        const MAX_EMBEDDED_BYTES: usize = 16 * 1024 * 1024;
        const MAX_DECODED_BYTES: u64 = 128 * 1024 * 1024;
        let bytes = source.len();
        if self.admitted >= self.limit || bytes > MAX_EMBEDDED_BYTES - self.embedded_bytes {
            self.blocked += 1;
            return false;
        }
        let Some(decoded_bytes) = raster_decoded_bytes(&normalized(source)) else {
            self.blocked += 1;
            return false;
        };
        if decoded_bytes > MAX_DECODED_BYTES - self.decoded_bytes {
            self.blocked += 1;
            return false;
        }
        self.admitted += 1;
        self.embedded_bytes += bytes;
        self.decoded_bytes += decoded_bytes;
        true
    }
    fn keep(&mut self, node: &mut Node) -> bool {
        if !node.has("src") {
            return true;
        }
        let source = node.attr("src").to_owned();
        let kind = image_kind(&source);
        if matches!(kind, ImageSource::Embedded | ImageSource::Remote) && tracking(node) {
            self.blocked += 1;
            return false;
        }
        match kind {
            ImageSource::Embedded => self.admit(&source),
            ImageSource::Absent => true,
            ImageSource::Remote => {
                if self.loadable < self.limit {
                    self.loadable += 1
                }
                let prepared = self.prepared(&source);
                if !self.allowed() || prepared.is_empty() {
                    self.blocked += 1;
                    return false;
                }
                if !self.admit(&prepared) {
                    return false;
                }
                node.set("src", &prepared);
                self.kept += 1;
                true
            }
            ImageSource::Unsafe | ImageSource::Local => false,
        }
    }
}
fn clean(node: &mut Node, images: &mut Images<'_>, colors: bool) {
    let mut kept = vec![];
    for mut child in std::mem::take(&mut node.children) {
        if child.kind == "text" {
            kept.push(child);
            continue;
        }
        if dropped(&child.name) {
            continue;
        }
        if child.name == "center" {
            child.name = "div".into()
        }
        let styles = declarations(child.attr("style"));
        if child.has("hidden") {
            continue;
        }
        if (!tree::void(&child.name) || child.name == "img") && hidden(&styles) {
            continue;
        }
        if child.name == "img" && images.sources.len() < images.limit {
            let source = child.attr("src");
            if image_kind(source) == ImageSource::Remote
                && !tracking(&child)
                && !images.sources.iter().any(|candidate| candidate == source)
            {
                images.sources.push(source.into())
            }
        }
        for (key, value) in &styles {
            if child.name == "img"
                && matches!(key.as_str(), "width" | "height")
                && !child.has(key)
                && let Some(captures) = re!(r"(?i)^(\d+(?:\.\d+)?)px$").captures(value)
            {
                child.set(key, &captures[1])
            }
            if key == "direction"
                && !child.has("dir")
                && matches!(value.trim().to_ascii_lowercase().as_str(), "ltr" | "rtl")
            {
                child.set("dir", &value.trim().to_ascii_lowercase())
            }
        }
        clean_attrs(&mut child, colors, styles);
        if child.name == "img" && !images.keep(&mut child) {
            continue;
        }
        clean(&mut child, images, colors);
        if child.children.iter().any(|child| child.name == "img") {
            let styles = declarations(child.attr("style"))
                .into_iter()
                .filter(|(name, value)| {
                    !matches!(name.as_str(), "line-height" | "font-size")
                        || !re!(r"(?i)^0(?:\.0+)?(?:px|pt|%|em|rem)?$").is_match(value)
                })
                .collect::<Vec<_>>();
            set_style(&mut child, &styles)
        }
        kept.push(child)
    }
    node.children = kept
}
pub fn measure(node: &Node, html: &str) -> Value {
    fn walk(
        node: &Node,
        depth: usize,
        tags: &mut usize,
        images: &mut usize,
        tables: &mut usize,
    ) -> usize {
        let mut deepest = depth;
        for child in &node.children {
            if child.kind == "text" {
                continue;
            }
            *tags += 1;
            if child.name == "img" {
                *images += 1
            }
            let child_depth = depth + usize::from(child.name == "table");
            if child.name == "table" {
                *tables += 1
            }
            deepest = deepest.max(walk(child, child_depth, tags, images, tables))
        }
        deepest
    }
    let (mut tags, mut images, mut tables) = (0, 0, 0);
    let depth = walk(node, 0, &mut tags, &mut images, &mut tables);
    json!({"length":html.encode_utf16().count(),"tags":tags,"images":images,"tables":tables,"tableDepth":depth})
}
pub fn too_heavy(size: &Value) -> bool {
    size["length"].as_u64().unwrap_or(0) > 120000
        || size["tags"].as_u64().unwrap_or(0) > 2500
        || size["tables"].as_u64().unwrap_or(0) > 60
        || size["tableDepth"].as_u64().unwrap_or(0) > 4
}
// Invariant: embedded raster bytes do not count as layout markup; counting them previously refused small messages after images loaded.
pub fn too_heavy_to_draw(node: &Node, size: &Value) -> bool {
    fn embedded(node: &Node) -> u64 {
        node.children
            .iter()
            .filter(|child| child.kind != "text")
            .map(|child| {
                let source = child.attr("src");
                let own = if child.name == "img" && has_data_scheme(source) {
                    source.encode_utf16().count() as u64
                } else {
                    0
                };
                own + embedded(child)
            })
            .sum()
    }
    let mut drawn = size.clone();
    drawn["length"] = json!(
        size["length"]
            .as_u64()
            .unwrap_or(0)
            .saturating_sub(embedded(node))
    );
    too_heavy(&drawn)
}
pub fn read_plain(node: &Node) -> Value {
    fn walk(node: &Node, text: &mut String, images: &mut Vec<String>) {
        for child in &node.children {
            if child.kind == "text" {
                if !child.raw {
                    text.push_str(&decode(&source_space(&child.text)))
                }
                continue;
            }
            if dropped(&child.name) {
                continue;
            }
            if child.name == "img" {
                if tracking(child) {
                    continue;
                }
                images.push(child.attr("src").into());
                text.push_str(&format!("[image {}]", images.len()));
                continue;
            }
            if child.name == "br" {
                text.push('\n');
                continue;
            }
            if child.name == "li" {
                text.push_str("• ")
            }
            walk(child, text, images);
            if block(&child.name) || matches!(child.name.as_str(), "td" | "th") {
                text.push('\n')
            }
        }
    }
    let mut text = String::new();
    let mut images = vec![];
    walk(node, &mut text, &mut images);
    let text = re!(r"[^\S\n]+\n").replace_all(&text, "\n");
    let text = re!(r"\n[^\S\n]+").replace_all(&text, "\n");
    let text = re!(r"\n{3,}").replace_all(&text, "\n\n");
    json!({"text":text.trim(),"images":images,"bodyDirection":crate::message::direction::resolve_body(text.trim(),crate::message::direction::AUTO)})
}
pub fn to_text(source: &str) -> Result<String, &'static str> {
    Ok(read_plain(&parse(source)?)["text"]
        .as_str()
        .unwrap_or("")
        .into())
}
pub fn sanitize(source: &str, options: &Value) -> Result<Value, &'static str> {
    let mut root = parse(source)?;
    let plain = if options["withPlainText"] == true {
        read_plain(&root)
    } else {
        Value::Null
    };
    let reader = if options["withReader"] == true {
        reader::render(&root, options)?
    } else {
        Value::Null
    };
    let mut images = Images::new(options);
    clean(&mut root, &mut images, options["keepColors"] == true);
    if options["keepTables"] != true {
        flatten_tables(
            &mut root,
            bounded_option(options, "keepTableDepth", 2, 128),
            0,
        )
    }
    collapse(&mut root);
    let html = serialize(&root)?;
    let size = measure(&root, &html);
    let heavy = too_heavy_to_draw(&root, &size);
    Ok(
        json!({"html":html,"blockedImages":images.blocked,"images":images.kept,"remoteImages":images.loadable,"remoteImageSources":images.sources,"complexity":size,"tooHeavy":heavy,"plainText":plain,"reader":reader,"document":root}),
    )
}
pub fn request(params: &Value) -> Result<Value, &'static str> {
    let source = params["html"].as_str().ok_or("invalid_params")?;
    sanitize(source, params.get("options").unwrap_or(&Value::Null))
}
