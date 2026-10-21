//! Mail direction rules shared by summaries, rendering and outgoing MIME.
use regex::Regex;
use std::sync::LazyLock;
mod data;
pub const AUTO: &str = "Auto";
pub const LTR: &str = "ltr";
pub const RTL: &str = "rtl";
pub fn normalize_mode(mode: &str) -> &str {
    match mode {
        "Right to left" | "Left to right" => mode,
        _ => AUTO,
    }
}
pub fn forced(mode: &str) -> &'static str {
    match mode {
        "Right to left" => RTL,
        "Left to right" => LTR,
        _ => "",
    }
}
pub fn direction_of_code(code: u32) -> &'static str {
    if char::from_u32(code).is_none() {
        return "";
    }
    let index = data::RANGES.partition_point(|&(_, end, _)| end < code);
    if let Some(&(start, _, direction)) = data::RANGES.get(index)
        && start <= code
    {
        return direction;
    }
    LTR
}
pub fn strong_direction(text: &str) -> &'static str {
    let mut depth = 0usize;
    for ch in text.chars() {
        let code = ch as u32;
        match code {
            0x2066..=0x2068 => {
                depth += 1;
                continue;
            }
            0x2069 => {
                depth = depth.saturating_sub(1);
                continue;
            }
            _ => (),
        }
        if depth > 0 {
            continue;
        }
        match code {
            0x202b | 0x202e => return RTL,
            0x202a | 0x202d => return LTR,
            _ => (),
        }
        let direction = direction_of_code(code);
        if !direction.is_empty() {
            return direction;
        }
    }
    ""
}
fn js_regex(pattern: &str) -> Regex {
    Regex::new(&pattern.replace(r"\s", r"[\x{0009}-\x{000D}\x{0020}\x{00A0}\x{1680}\x{2000}-\x{200A}\x{2028}\x{2029}\x{202F}\x{205F}\x{3000}\x{FEFF}]")).unwrap()
}
static PREFIX: LazyLock<Regex> = LazyLock::new(|| {
    js_regex(
        r"(?i)^[\s\x{200E}\x{200F}]*(?:(?:re|aw|sv|vs|vl|antw|antwort|fw|fwd|wg|tr|rv|rif|res|enc|encaminhado|doorst|odp|ynt|ilt|回复|回覆|转发|轉發)\s*(?:[\[\(]\s*[0-9]+\s*[\]\)])?\s*:|\[[^\]]{0,64}\]|\((?:fwd|fw)\))[\s\x{200E}\x{200F}]*",
    )
});
pub fn without_reply_prefixes(mut text: &str) -> &str {
    for _ in 0..12 {
        let Some(prefix) = PREFIX.find(text) else {
            break;
        };
        let visible = text.trim_start_matches(|c: char| {
            c.is_whitespace() || matches!(c, '\u{feff}' | '\u{200e}' | '\u{200f}')
        });
        if visible.starts_with('[')
            && visible
                .split_once(']')
                .is_some_and(|(tag, _)| tag[1..].encode_utf16().count() > 64)
        {
            break;
        }
        text = &text[prefix.end()..];
    }
    text
}
pub fn resolve(text: &str, mode: &str) -> &'static str {
    let forced = forced(mode);
    if !forced.is_empty() {
        forced
    } else {
        strong_direction(text)
    }
}
pub fn resolve_subject(text: &str, mode: &str) -> &'static str {
    resolve(without_reply_prefixes(text), mode)
}
static IMAGES: LazyLock<Regex> = LazyLock::new(|| js_regex(r"^(?:\s*\[image(?:\s+[0-9]+)?\])+"));
pub fn without_image_markers(text: &str) -> &str {
    IMAGES.find(text).map(|m| &text[m.end()..]).unwrap_or(text)
}
pub fn resolve_body(text: &str, mode: &str) -> &'static str {
    resolve(without_image_markers(text), mode)
}
pub fn attribute_for(direction: &str) -> &'static str {
    match direction {
        LTR => " dir=\"ltr\"",
        RTL => " dir=\"rtl\"",
        _ => "",
    }
}
pub fn start_edge(direction: &str) -> &'static str {
    if direction == RTL { "right" } else { "left" }
}
pub fn end_edge(direction: &str) -> &'static str {
    if direction == RTL { "left" } else { "right" }
}
#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::{Value, json};
    #[test]
    fn unicode_classes_drive_first_strong_direction() {
        for code in [0x05b0, 0x064b, 0x037e, 0x10d40, 0x20c1] {
            let prefix = char::from_u32(code).unwrap();
            assert_eq!(direction_of_code(code), "", "non-strong U+{code:04X}");
            assert_eq!(strong_direction(&format!("{prefix}hello")), LTR);
            assert_eq!(strong_direction(&format!("{prefix}שלום")), RTL);
        }
        for code in [0x00aa, 0x2102, 0x1f1e6] {
            assert_eq!(direction_of_code(code), LTR, "strong L U+{code:04X}");
        }
        for code in [0x0590, 0x086b, 0x10ec0] {
            assert_eq!(
                direction_of_code(code),
                RTL,
                "reserved default U+{code:04X}"
            );
        }
    }

    #[test]
    fn every_scalar_matches_pinned_unicode_classes() {
        let output = std::process::Command::new("python3")
            .args(["scripts/generate-direction-data.py", "--classes"])
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "{}",
            String::from_utf8_lossy(&output.stderr)
        );
        assert_eq!(output.stdout.len(), 0x110000);
        for (code, expected) in output.stdout.into_iter().enumerate() {
            let code = code as u32;
            let direction = if char::from_u32(code).is_none() {
                ""
            } else {
                ["", LTR, RTL][usize::from(expected)]
            };
            assert_eq!(direction_of_code(code), direction, "U+{code:04X}");
        }
        assert_eq!(direction_of_code(0x110000), "");
        assert_eq!(direction_of_code(u32::MAX), "");
    }

    #[test]
    fn existing_direction_suite_is_a_live_golden_oracle() {
        let script = r#"const loader=require('./ui/tests/load');const load=loader.load;const rows=[];loader.load=function(p){const m=load(p);if(p==='message/Direction.js')for(const name of ['attributeFor','endEdge','forced','hasAnswer','isRightToLeft','normalizeMode','resolve','resolveBody','resolveSubject','startEdge','strongDirectionOf','subjectDirectionOf']){const f=m[name];m[name]=function(...args){const result=f(...args);rows.push({name,args,result});return result;};}return m;};console.log=()=>{};require('./ui/tests/test_direction');process.stdout.write(JSON.stringify(rows));"#;
        let output = std::process::Command::new("node")
            .args(["-e", script])
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "{}",
            String::from_utf8_lossy(&output.stderr)
        );
        let rows: Value = serde_json::from_slice(&output.stdout).unwrap();
        for row in rows.as_array().unwrap() {
            let first = row["args"][0].as_str().unwrap_or("");
            let second = row["args"][1].as_str().unwrap_or("");
            let value = match row["name"].as_str().unwrap() {
                "attributeFor" => json!(attribute_for(first)),
                "endEdge" => json!(end_edge(first)),
                "forced" => json!(forced(first)),
                "hasAnswer" => json!(matches!(first, LTR | RTL)),
                "isRightToLeft" => json!(first == RTL),
                "normalizeMode" => json!(normalize_mode(first)),
                "resolve" => json!(resolve(first, second)),
                "resolveBody" => json!(resolve_body(first, second)),
                "resolveSubject" => json!(resolve_subject(first, second)),
                "startEdge" => json!(start_edge(first)),
                "strongDirectionOf" => json!(strong_direction(first)),
                "subjectDirectionOf" => json!(resolve_subject(first, AUTO)),
                _ => unreachable!(),
            };
            assert_eq!(value, row["result"], "{} {first:?}", row["name"]);
        }
    }
    #[test]
    fn agrees_with_live_js_for_multilingual_prefixes_isolates_and_neutral_blocks() {
        let samples = [
            "مرحبا",
            "שלום",
            "سلام دنیا",
            "Re: مرحبا",
            "[team] Fwd: AW[2]: שלום",
            "回复: سلام",
            "Bug: שלום",
            "Re: 2024",
            "١٢٣ hello",
            "۱۲۳ hello",
            "\u{feff}hello",
            "\u{2066}hello\u{2069}سلام",
            "\u{2067}שלום\u{2069}hello",
            "\u{202e}hello",
            "[image 1][image 2] سلام",
            "🎉 שלום",
            "\u{1e900}",
            "",
            "Re: ".repeat(13).leak(),
        ];
        let cases: Vec<_> = samples
            .iter()
            .flat_map(|text| {
                ["Auto", "Left to right", "Right to left", "bad"]
                    .map(|mode| json!({"text":text,"mode":mode}))
            })
            .collect();
        let script = r#"const {load}=require('./ui/tests/load');const d=load('message/Direction.js');let s='';process.stdin.on('data',b=>s+=b);process.stdin.on('end',()=>process.stdout.write(JSON.stringify(JSON.parse(s).map(c=>[d.resolve(c.text,c.mode),d.resolveSubject(c.text,c.mode),d.resolveBody(c.text,c.mode),d.withoutReplyPrefixes(c.text)]))));"#;
        use std::io::Write;
        let mut child = std::process::Command::new("node")
            .args(["-e", script])
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .spawn()
            .unwrap();
        child
            .stdin
            .take()
            .unwrap()
            .write_all(serde_json::to_string(&cases).unwrap().as_bytes())
            .unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        let expected: Value = serde_json::from_slice(&output.stdout).unwrap();
        for (index, case) in cases.iter().enumerate() {
            let text = case["text"].as_str().unwrap();
            let mode = case["mode"].as_str().unwrap();
            assert_eq!(
                json!([
                    resolve(text, mode),
                    resolve_subject(text, mode),
                    resolve_body(text, mode),
                    without_reply_prefixes(text)
                ]),
                expected[index],
                "{text:?} {mode}"
            )
        }
    }
}
