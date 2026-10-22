use super::*;

#[derive(Default)]
struct State {
    blocks: Vec<Node>,
    inline: Vec<Node>,
    chain: Vec<Node>,
    pending: bool,
    filled: bool,
}
impl State {
    fn target(&mut self) -> &mut Vec<Node> {
        let mut output = &mut self.inline;
        for _ in 0..self.chain.len() {
            output = &mut output.last_mut().unwrap().children
        }
        output
    }
    fn space(&mut self) {
        if !self.pending || !self.filled {
            return;
        }
        let target = self.target();
        if let Some(node) = target.last_mut().filter(|node| node.kind == "text") {
            node.text.push(' ')
        } else {
            target.push(Node::text(" "))
        }
        self.pending = false
    }
    fn open(&mut self, node: Node) -> bool {
        if self.chain.len() >= 8 {
            return false;
        }
        self.space();
        self.target().push(node.clone());
        self.chain.push(node);
        true
    }
    fn text(&mut self, raw: &str) {
        let value = source_space(&undrawn(raw));
        if value.is_empty() {
            return;
        }
        let core = value.trim_matches(' ');
        if core.is_empty() {
            if self.filled {
                self.pending = true
            }
            return;
        }
        if value.starts_with(' ') && self.filled {
            self.pending = true
        }
        let lead = if self.pending && self.filled { " " } else { "" };
        let text = format!("{lead}{core}");
        let target = self.target();
        if let Some(node) = target.last_mut().filter(|node| node.kind == "text") {
            node.text.push_str(&text)
        } else {
            target.push(Node::text(&text))
        }
        self.filled = true;
        self.pending = value.ends_with(' ')
    }
    fn br(&mut self) {
        if !self.filled {
            return;
        }
        let target = self.target();
        if target.last().is_some_and(|node| node.name == "br") {
            return;
        }
        target.push(Node::element("br"));
        self.pending = false
    }
    fn flush(&mut self, name: &str) {
        let content = std::mem::take(&mut self.inline);
        self.pending = false;
        self.filled = false;
        let chain = std::mem::take(&mut self.chain);
        for node in chain {
            self.open(node);
        }
        if meaningful(&content) {
            let mut node = Node::element(name);
            node.children = trimmed(content);
            self.blocks.push(node)
        }
    }
}
fn meaningful(nodes: &[Node]) -> bool {
    nodes.iter().any(|node| {
        if node.kind == "text" {
            !decode(&node.text).trim().is_empty()
        } else if node.name == "img" {
            true
        } else if matches!(node.name.as_str(), "br" | "hr") {
            false
        } else {
            meaningful(&node.children)
        }
    })
}
fn trimmed(mut nodes: Vec<Node>) -> Vec<Node> {
    let empty = |node: &Node| {
        node.name == "br" || (node.kind == "text" && decode(&node.text).trim().is_empty())
    };
    let start = nodes
        .iter()
        .position(|node| !empty(node))
        .unwrap_or(nodes.len());
    nodes.drain(..start);
    while nodes.last().is_some_and(empty) {
        nodes.pop();
    }
    nodes
}
fn length(nodes: &[Node]) -> usize {
    nodes
        .iter()
        .map(|node| {
            if node.kind == "text" {
                decode(&node.text).encode_utf16().count()
            } else if node.name == "img" {
                8
            } else {
                length(&node.children)
            }
        })
        .sum()
}
fn drop_reader(name: &str) -> bool {
    dropped(name)
        || matches!(
            name,
            "head"
                | "input"
                | "select"
                | "option"
                | "optgroup"
                | "svg"
                | "canvas"
                | "map"
                | "area"
                | "frame"
                | "frameset"
                | "video"
                | "audio"
                | "source"
                | "track"
                | "param"
                | "template"
                | "col"
                | "colgroup"
        )
}
fn hidden_reader(node: &Node) -> bool {
    if node.has("hidden") {
        return true;
    }
    let styles = declarations(node.attr("style"));
    if hidden(&styles) {
        return true;
    }
    let leaf = node.children.iter().all(|node| node.kind == "text");
    let mut zero = false;
    let mut clip = false;
    for (name, value) in styles {
        if leaf
            && name == "font-size"
            && re!(r"(?i)^\s*[0-2](\.\d+)?\s*(px|pt)?\s*$").is_match(&value)
        {
            return true;
        }
        if name == "opacity" && re!(r"^\s*0(\.0+)?\s*$").is_match(&value) {
            return true;
        }
        if name == "max-height" && re!(r"(?i)^\s*0(\.0+)?\s*(px|pt|em|rem|%)?\s*$").is_match(&value)
        {
            zero = true
        }
        if name == "overflow" && re!(r"(?i)^\s*hidden\b").is_match(&value) {
            clip = true
        }
    }
    zero && clip
}
fn dimension(node: &Node, key: &str) -> usize {
    let raw = node.attr(key);
    let mut value = if re!(r"^\s*\d+(?:\.\d+)?\s*$").is_match(raw) {
        raw.trim().parse::<f64>().unwrap_or(0.0)
    } else {
        0.0
    };
    if value <= 0.0 {
        for (name, style_value) in declarations(node.attr("style")) {
            if name == key
                && let Some(captures) = re!(r"(?i)^\s*(\d+(?:\.\d+)?)px\s*$").captures(&style_value)
            {
                value = captures[1].parse().unwrap_or(0.0)
            }
        }
    }
    if !(2.0..=640.0).contains(&value) || value == 2.0 {
        0
    } else {
        value.round() as usize
    }
}
fn image(node: &Node, state: &mut State, images: &mut Images<'_>) {
    if tracking(node) {
        return;
    }
    let source = node.attr("src");
    let kind = if node.has("src") {
        image_kind(source)
    } else {
        ImageSource::Absent
    };
    let rendered = if kind == ImageSource::Remote {
        images.prepared(source)
    } else {
        source.into()
    };
    if (kind == ImageSource::Embedded || (kind == ImageSource::Remote && images.allowed() && !rendered.is_empty()))
        && images.admit(&rendered)
    {
        if kind == ImageSource::Remote {
            images.kept += 1
        }
        state.space();
        let mut output = Node::element("img");
        output.set("src", &rendered);
        let (width_pixels, height_pixels) = (dimension(node, "width"), dimension(node, "height"));
        if width_pixels > 0 {
            output.set("width", &width_pixels.to_string())
        }
        if height_pixels > 0 && width_pixels > 0 && width_pixels <= 96 && height_pixels <= 96 {
            output.set("height", &height_pixels.to_string())
        }
        state.target().push(output);
        state.filled = true;
        state.pending = false;
        return;
    }
    if kind == ImageSource::Remote && (!images.allowed() || rendered.is_empty()) {
        images.blocked += 1
    }
    let alt = source_space(&tree::escape_text(&decode(node.attr("alt"))));
    if !alt.trim().is_empty() {
        state.text(alt.trim())
    } else if kind == ImageSource::Remote && node.has("src") && !node.has("alt") {
        state.text("[image]")
    }
}
fn heading(node: &Node) -> String {
    let mut level = "";
    for (name, value) in declarations(node.attr("style")) {
        if name != "font-size" {
            continue;
        }
        let size = value.trim().to_ascii_lowercase();
        let number = re!(r"^[+-]?(?:\d+(?:\.\d*)?|\.\d+)")
            .find(&size)
            .and_then(|matched_number| matched_number.as_str().parse::<f64>().ok())
            .unwrap_or(0.0);
        let pixels = if size.ends_with("px") {
            number
        } else if size.ends_with("pt") {
            number * 4.0 / 3.0
        } else if size.ends_with("em") {
            number * 16.0
        } else if size.ends_with('%') {
            number * 0.16
        } else {
            0.0
        };
        level = if pixels >= 28.0 {
            "h2"
        } else if pixels >= 20.0 {
            "h3"
        } else {
            ""
        }
    }
    level.into()
}
fn build_heading(
    node: &Node,
    state: &mut State,
    images: &mut Images<'_>,
    tables: bool,
    tag: &str,
    single: bool,
) {
    state.flush("p");
    let blocks = build(node, images, tables);
    let eligible = (!single || blocks.len() <= 1) && blocks.iter().all(|node| node.name == "p");
    let mut content = vec![];
    if eligible {
        for block in &blocks {
            if !content.is_empty() {
                content.push(Node::text(" "))
            }
            content.extend(block.children.clone())
        }
    }
    if content.is_empty() || length(&content) > 120 {
        state.blocks.extend(blocks)
    } else {
        let mut output = Node::element(tag);
        output.children = content;
        state.blocks.push(output)
    }
}
fn text_of(node: &Node) -> String {
    if node.kind == "text" {
        node.text.clone()
    } else {
        node.children.iter().map(text_of).collect()
    }
}
fn contains_image(nodes: &[Node]) -> bool {
    nodes
        .iter()
        .any(|node| node.name == "img" || contains_image(&node.children))
}
fn furniture(node: &Node) -> bool {
    !contains_image(&node.children)
        && re!(r"^[\s\x{00a0}]*[|\x{00b7}\x{2022}\x{2013}\x{2014}/-]?[\s\x{00a0}]*$")
            .is_match(&text_of(node))
}
fn inline_or_blocks(mut blocks: Vec<Node>) -> Vec<Node> {
    if blocks.len() == 1 && blocks[0].name == "p" {
        blocks.remove(0).children
    } else {
        blocks
    }
}
fn visible_rows<'a>(node: &'a Node, output: &mut Vec<&'a Node>) {
    for child in &node.children {
        if child.kind == "text"
            || child.name == "table"
            || drop_reader(&child.name)
            || hidden_reader(child)
        {
            continue;
        }
        if child.name == "tr" {
            output.push(child);
            continue;
        }
        visible_rows(child, output);
    }
}
fn data_table(node: &Node, images: &mut Images<'_>) -> Option<Node> {
    let mut source = vec![];
    visible_rows(node, &mut source);
    if source.is_empty() || source.len() > 40 {
        return None;
    }
    let mut grid = vec![];
    for row_cells in source {
        let cells = row_cells
            .children
            .iter()
            .filter(|node| matches!(node.name.as_str(), "td" | "th"))
            .collect::<Vec<_>>();
        if cells.len() > 8 {
            return None;
        }
        if !cells.is_empty() {
            grid.push(cells)
        }
    }
    let columns = grid.iter().map(Vec::len).max().unwrap_or(0);
    for column_index in (0..columns).rev() {
        if grid.iter().all(|row_cells| {
            row_cells
                .get(column_index)
                .is_some_and(|node| furniture(node))
        }) {
            for row_cells in &mut grid {
                row_cells.remove(column_index);
            }
        }
    }
    if grid.iter().map(Vec::len).max().unwrap_or(0) < 2 {
        return None;
    }
    let mut output = Node::element("table");
    for row_cells in grid {
        let mut row = Node::element("tr");
        for source_cell in row_cells {
            let mut cell = Node::element(&source_cell.name);
            cell.children = inline_or_blocks(build(source_cell, images, false));
            row.children.push(cell)
        }
        output.children.push(row)
    }
    Some(output)
}
fn broken(nodes: &[Node]) -> bool {
    nodes
        .iter()
        .any(|node| node.name == "br" || broken(&node.children))
}
fn row(node: &Node, state: &mut State, images: &mut Images<'_>, tables: bool) -> bool {
    let mut cells = vec![];
    for cell in &node.children {
        if cell.kind == "text" {
            continue;
        }
        if !matches!(cell.name.as_str(), "td" | "th") || !heading(cell).is_empty() {
            return false;
        }
        if !furniture(cell) {
            cells.push(cell)
        }
    }
    let built = cells
        .into_iter()
        .map(|cell| build(cell, images, tables))
        .collect::<Vec<_>>();
    let eligible = built.iter().all(|block| {
        block.is_empty()
            || (block.len() == 1 && block[0].name == "p" && !broken(&block[0].children))
    });
    let mut line = vec![];
    if eligible {
        for block in &built {
            if block.is_empty() {
                continue;
            }
            if !line.is_empty() {
                line.push(Node::text(" "))
            }
            line.extend(block[0].children.clone())
        }
    }
    state.flush("p");
    if eligible && length(&line) <= 160 {
        if !line.is_empty() {
            let mut paragraph = Node::element("p");
            paragraph.children = trimmed(line);
            state.blocks.push(paragraph)
        }
    } else {
        for block in built {
            state.blocks.extend(block)
        }
    }
    true
}
fn list_items(node: &Node, list: &mut Node, images: &mut Images<'_>, tables: bool) {
    for child in &node.children {
        if child.kind == "text" || drop_reader(&child.name) || hidden_reader(child) {
            continue;
        }
        if child.name != "li" {
            list_items(child, list, images, tables);
            continue;
        }
        let mut item = Node::element("li");
        item.children = inline_or_blocks(build(child, images, tables));
        if !item.children.is_empty() {
            list.children.push(item)
        }
    }
}
fn pre_text(node: &Node, output: &mut String) {
    for child in &node.children {
        if child.kind == "text" {
            if !child.raw {
                output.push_str(&child.text)
            }
            continue;
        }
        if drop_reader(&child.name) || hidden_reader(child) {
            continue;
        }
        if child.name == "br" {
            output.push('\n')
        } else {
            pre_text(child, output)
        }
    }
}
fn walk(node: &Node, state: &mut State, images: &mut Images<'_>, tables: bool) {
    for child in &node.children {
        visit_node(child, state, images, tables)
    }
}
fn visit_node(node: &Node, state: &mut State, images: &mut Images<'_>, tables: bool) {
    if node.kind == "text" {
        if !node.raw {
            state.text(&node.text)
        }
        return;
    }
    let name = node.name.as_str();
    if drop_reader(name) || hidden_reader(node) {
        return;
    }
    match name {
        "br" => state.br(),
        "img" => image(node, state, images),
        "hr" => {
            state.flush("p");
            state.blocks.push(Node::element("hr"))
        }
        "a" => {
            let raw = node.attr("href");
            let normalized_url = normalized(raw);
            if !safe_href(raw)
                || !safe_href(&normalized_url)
                || (!normalized_url.to_ascii_lowercase().starts_with("mailto:")
                    && !is_public_url(raw))
            {
                walk(node, state, images, tables)
            } else {
                let mut link = Node::element("a");
                link.set("href", raw);
                let opened = state.open(link);
                walk(node, state, images, tables);
                if opened {
                    state.chain.pop();
                }
            }
        }
        "b" | "strong" | "i" | "em" | "cite" | "dfn" | "var" | "code" | "kbd" | "samp" | "tt" => {
            let tag = match name {
                "b" | "strong" => "strong",
                "code" | "kbd" | "samp" | "tt" => "code",
                _ => "em",
            };
            let opened = state.open(Node::element(tag));
            walk(node, state, images, tables);
            if opened {
                state.chain.pop();
            }
        }
        "h1" | "h2" | "h3" | "h4" | "h5" | "h6" => {
            build_heading(node, state, images, tables, name, false)
        }
        "pre" => {
            state.flush("p");
            let mut text = String::new();
            pre_text(node, &mut text);
            let text = text.trim_start_matches('\n').trim_end();
            if !text.is_empty() {
                let mut output = Node::element("pre");
                output.children.push(Node::text(text));
                state.blocks.push(output)
            }
        }
        "ul" | "ol" => {
            state.flush("p");
            let mut list = Node::element(name);
            list_items(node, &mut list, images, tables);
            if list.children.is_empty() {
                walk(node, state, images, tables);
                state.flush("p")
            } else {
                state.blocks.push(list)
            }
        }
        "blockquote" => {
            state.flush("p");
            let blocks = build(node, images, tables);
            if !blocks.is_empty() {
                let mut quote = Node::element("blockquote");
                quote.children = blocks;
                state.blocks.push(quote)
            }
        }
        "table" => {
            state.flush("p");
            if tables
                && grid(node)
                && let Some(table) = data_table(node, images)
            {
                state.blocks.push(table);
                return;
            }
            walk(node, state, images, tables);
            state.flush("p")
        }
        _ => {
            if name == "tr" && state.chain.is_empty() && row(node, state, images, tables) {
                return;
            }
            if !(table_part(name)
                || matches!(
                    name,
                    "div"
                        | "p"
                        | "section"
                        | "article"
                        | "aside"
                        | "header"
                        | "footer"
                        | "main"
                        | "nav"
                        | "center"
                        | "form"
                        | "fieldset"
                        | "figure"
                        | "figcaption"
                        | "address"
                        | "dl"
                        | "dt"
                        | "dd"
                        | "caption"
                        | "legend"
                        | "details"
                        | "summary"
                )) {
                walk(node, state, images, tables);
                return;
            }
            let inferred = if state.chain.is_empty() {
                heading(node)
            } else {
                String::new()
            };
            if !inferred.is_empty() {
                build_heading(node, state, images, tables, &inferred, true);
                return;
            }
            state.flush("p");
            walk(node, state, images, tables);
            state.flush("p")
        }
    }
}
fn build(node: &Node, images: &mut Images<'_>, tables: bool) -> Vec<Node> {
    if drop_reader(&node.name) || hidden_reader(node) {
        return vec![];
    }
    let mut state = State::default();
    walk(node, &mut state, images, tables);
    state.flush("p");
    state.blocks
}
fn small_images(nodes: &[Node]) -> usize {
    let mut count = 0;
    for node in nodes {
        if node.kind == "text" {
            if !decode(&node.text).trim().is_empty() {
                return 0;
            }
            continue;
        }
        if node.name == "img" {
            let width_pixels = node.attr("width").parse::<f64>().unwrap_or(0.0);
            let height_pixels = node.attr("height").parse::<f64>().unwrap_or(0.0);
            if width_pixels <= 2.0 || width_pixels > 96.0 || height_pixels > 96.0 {
                return 0;
            }
            count += 1
        } else if node.name == "a" {
            let child = small_images(&node.children);
            if child == 0 {
                return 0;
            }
            count += child
        } else {
            return 0;
        }
    }
    count
}
fn avatar(mut block: Node) -> Node {
    if block.name != "p" {
        return block;
    }
    let children = trimmed(block.children.clone());
    if children.len() < 2
        || small_images(&children[..1]) != 1
        || !meaningful(&children[1..])
        || contains_image(&children[1..])
    {
        return block;
    }
    block = Node::element("table");
    block.set("cellspacing", "0");
    block.set("cellpadding", "0");
    let mut row = Node::element("tr");
    let mut picture = Node::element("td");
    picture.set("valign", "middle");
    picture.set("style", "padding:0px;padding-right:6px");
    picture.children = children[..1].to_vec();
    let mut words = Node::element("td");
    words.set("valign", "middle");
    words.set("style", "padding:0px");
    words.children = children[1..].to_vec();
    row.children = vec![picture, words];
    block.children = vec![row];
    block
}
fn tidy(blocks: Vec<Node>) -> Vec<Node> {
    let mut output: Vec<Node> = vec![];
    for block in blocks {
        if block.name == "hr"
            && (output.is_empty() || output.last().is_some_and(|node| node.name == "hr"))
        {
            continue;
        }
        let block = avatar(block);
        if block.name == "p"
            && small_images(&block.children) > 0
            && output
                .last()
                .is_some_and(|node| node.name == "p" && small_images(&node.children) > 0)
        {
            let last = output.last_mut().unwrap();
            last.children.push(Node::text(" "));
            last.children.extend(block.children)
        } else {
            output.push(block)
        }
    }
    while output.last().is_some_and(|node| node.name == "hr") {
        output.pop();
    }
    output
}
pub fn render(node: &Node, options: &Value) -> Result<Value, &'static str> {
    let mut images = Images::new(options);
    let mut document = Node::root();
    document.children = tidy(build(node, &mut images, true));
    let html = serialize(&document)?;
    let size = measure(&document, &html);
    Ok(
        json!({"html":html,"empty":document.children.is_empty(),"document":document,"images":images.kept,"blockedImages":images.blocked,"tooHeavy":too_heavy_to_draw(&document, &size),"complexity":size}),
    )
}
