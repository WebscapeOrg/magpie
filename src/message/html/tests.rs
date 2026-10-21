use super::*;
#[test]
fn smoke() {
    let out = sanitize("<p>Hello <b>world</b></p>", &json!({"withReader":true})).unwrap();
    assert_eq!(out["html"], "<p>Hello <b>world</b></p>");
    assert_eq!(out["reader"]["html"], "<p>Hello <strong>world</strong></p>");
}

#[test]
fn actual_javascript_sanitizer_and_reader_corpus_matches() {
    let output = std::process::Command::new("node")
        .arg(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/src/message/html/golden.js"
        ))
        .current_dir(env!("CARGO_MANIFEST_DIR"))
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let cases: Vec<Value> = serde_json::from_slice(&output.stdout).unwrap();
    assert!(cases.len() > 200);
    let mut differences = vec![];
    for (index, case) in cases.into_iter().enumerate() {
        let actual = sanitize(case["source"].as_str().unwrap_or(""), &case["options"]).unwrap();
        for key in [
            "html",
            "blockedImages",
            "images",
            "remoteImages",
            "remoteImageSources",
            "complexity",
            "tooHeavy",
            "plainText",
        ] {
            if actual[key] != case["expected"][key] {
                differences.push(format!(
                    "case {index} {key}: actual={} expected={} source={}",
                    actual[key]
                        .to_string()
                        .chars()
                        .take(500)
                        .collect::<String>(),
                    case["expected"][key]
                        .to_string()
                        .chars()
                        .take(500)
                        .collect::<String>(),
                    case["source"]
                        .as_str()
                        .unwrap_or("")
                        .chars()
                        .take(200)
                        .collect::<String>()
                ));
            }
        }
        if case["expected"]["reader"].is_object() {
            for key in [
                "html",
                "images",
                "blockedImages",
                "complexity",
                "tooHeavy",
                "empty",
            ] {
                if actual["reader"][key] != case["expected"]["reader"][key] {
                    differences.push(format!(
                        "case {index} reader {key}: actual={} expected={} source={}",
                        actual["reader"][key]
                            .to_string()
                            .chars()
                            .take(500)
                            .collect::<String>(),
                        case["expected"]["reader"][key]
                            .to_string()
                            .chars()
                            .take(500)
                            .collect::<String>(),
                        case["source"]
                            .as_str()
                            .unwrap_or("")
                            .chars()
                            .take(200)
                            .collect::<String>()
                    ));
                }
            }
        }
    }
    assert!(differences.is_empty(), "{}", differences.join("\n"));
}

#[test]
fn malicious_resources_remain_inert_with_images_and_sender_colors_enabled() {
    let source = r#"<body background='https://tracker.example/a'><div style='background-image:&#117;rl(https://tracker.example/b);color:red'><img src='https://tracker.example/c'><input src='file:///tmp/secret'><span style='background:u\72l(https://tracker.example/d)'>safe</span></div></body>"#;
    for allow in [false, true] {
        let result = sanitize(
            source,
            &json!({"allowRemoteImages":allow,"keepColors":true,"withReader":true}),
        )
        .unwrap();
        for html in [
            result["html"].as_str().unwrap(),
            result["reader"]["html"].as_str().unwrap(),
        ] {
            assert!(!html.contains("tracker.example"), "{html}");
            assert!(!html.contains("file:"), "{html}");
            assert!(!html.contains("background="), "{html}");
        }
    }
    let result=sanitize("<img src='https://cdn.example.com/image'>",&json!({"allowRemoteImages":true,"remoteImageData":{"https://cdn.example.com/image":"data:image/png;base64,PHN2Zy8+"}})).unwrap();
    assert!(!result["html"].as_str().unwrap().contains("<img"));
}

#[test]
fn input_tree_and_expansion_have_explicit_bounds() {
    assert_eq!(
        parse(&"x".repeat(tree::MAX_INPUT + 1)).err(),
        Some("html_too_large")
    );
    assert_eq!(parse(&"<br>".repeat(tree::MAX_NODES - 1)).err(), None);
    assert_eq!(
        parse(&"<br>".repeat(tree::MAX_NODES)).err(),
        Some("html_too_complex")
    );
    let deep = format!("{}kept{}", "<div>".repeat(5000), "</div>".repeat(5000));
    let result = sanitize(&deep, &json!({"withReader":true})).unwrap();
    assert!(result["html"].as_str().unwrap().contains("kept"));
    let links = format!(
        "{}{}{}",
        "<a href='https://example.org'>".repeat(100),
        "<p>line</p>".repeat(1000),
        "</a>".repeat(100)
    );
    let result = sanitize(&links, &json!({"withReader":true})).unwrap();
    assert!(result["reader"]["complexity"]["tags"].as_u64().unwrap() < 10000);
}

fn rendered_node_count(node: &Value) -> usize {
    1 + node
        .get("children")
        .and_then(Value::as_array)
        .map(|children| children.iter().map(rendered_node_count).sum())
        .unwrap_or(0)
}

#[test]
fn rendered_documents_count_emitted_text_and_element_nodes() {
    let at_limit = format!("{}x", "x<br>".repeat((tree::MAX_NODES - 2) / 2));
    let rendered = sanitize(&at_limit, &json!({"withReader":true})).unwrap();
    assert_eq!(rendered_node_count(&rendered["document"]), tree::MAX_NODES);

    let over_limit = "x<br>".repeat(60_000);
    assert_eq!(
        sanitize(&over_limit, &json!({"withReader":true})).unwrap_err(),
        "html_too_complex"
    );
}

#[test]
#[ignore = "Run via make test-qml with Qt installed"]
fn native_output_cannot_trigger_qt_resource_requests() {
    use std::{
        io::{Read, Write},
        sync::{
            Arc,
            atomic::{AtomicBool, AtomicUsize, Ordering},
        },
        time::Duration,
    };
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    listener.set_nonblocking(true).unwrap();
    let url = format!("http://{}/image.png", listener.local_addr().unwrap());
    let count = Arc::new(AtomicUsize::new(0));
    let stopped = Arc::new(AtomicBool::new(false));
    let seen = count.clone();
    let stop = stopped.clone();
    let server = std::thread::spawn(move || {
        while !stop.load(Ordering::SeqCst) {
            match listener.accept() {
                Ok((mut stream, _)) => {
                    stream
                        .set_read_timeout(Some(Duration::from_secs(2)))
                        .unwrap();
                    let mut request = [0; 8192];
                    let _ = stream.read(&mut request);
                    seen.fetch_add(1, Ordering::SeqCst);
                    let _=stream.write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 8\r\nContent-Type: image/png\r\nConnection: close\r\n\r\n\x89PNG\r\n\x1a\n");
                }
                Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                    std::thread::sleep(Duration::from_millis(2))
                }
                Err(_) => break,
            }
        }
    });
    let directory = std::env::temp_dir().join(format!(
        "omamail-native-html-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    std::fs::create_dir(&directory).unwrap();
    let run = |documents: Vec<String>| {
        let qml = format!(
            "import QtQuick\nimport QtTest\nItem {{ width:400; height:200; property var documents: {}\nTextEdit {{ id: reader; width:400; height:200; textFormat: TextEdit.RichText }}\nTestCase {{ name: \"NativeHtmlResources\"; when: windowShown; function test_documents() {{ for (var i=0;i<documents.length;i++) {{ reader.text=documents[i]; wait(100); }} }} }}\n}}",
            serde_json::to_string(&documents).unwrap()
        );
        let path = directory.join("tst_native.qml");
        std::fs::write(&path, qml).unwrap();
        let output = std::process::Command::new(qml_runner())
            .arg("-input")
            .arg(path)
            .env("QT_QPA_PLATFORM", "offscreen")
            .env("QT_QUICK_BACKEND", "software")
            .env("QT_QPA_PLATFORMTHEME", "")
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "{} {}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
    };
    run(vec![format!("<img src='{url}'>")]);
    let positive = count.load(Ordering::SeqCst);
    assert!(
        positive > 0,
        "the Qt control must exercise actual network loading"
    );
    let attacks = [
        format!("<img src='{url}'>"),
        format!("<table background='{url}'><tr><td>body</td></tr></table>"),
        format!("<p style='background-image:&#117;rl({url})'>body</p>"),
        format!("<span><</span>img src='{url}'><p>body</p>"),
        format!("<span><\u{200b}img src='{url}'></span>"),
    ];
    let mut documents = vec![];
    for attack in attacks {
        let result = sanitize(
            &attack,
            &json!({"withReader":true,"keepColors":true,"allowRemoteImages":true}),
        )
        .unwrap();
        documents.push(result["html"].as_str().unwrap().into());
        documents.push(result["reader"]["html"].as_str().unwrap().into());
    }
    run(documents);
    let actual = count.load(Ordering::SeqCst);
    stopped.store(true, Ordering::SeqCst);
    server.join().unwrap();
    std::fs::remove_dir_all(directory).unwrap();
    assert_eq!(
        actual, positive,
        "native sanitized output must send no resource requests"
    );
}

fn qml_runner() -> std::path::PathBuf {
    if let Some(path) = std::env::var_os("QMLTESTRUNNER") {
        return path.into();
    }
    for candidate in ["qmltestrunner6", "qmltestrunner"] {
        if let Some(paths) = std::env::var_os("PATH") {
            for directory in std::env::split_paths(&paths) {
                let path = directory.join(candidate);
                if path.is_file() {
                    return path;
                }
            }
        }
    }
    for candidate in [
        "/usr/lib/qt6/bin/qmltestrunner",
        "/usr/lib/x86_64-linux-gnu/qt6/bin/qmltestrunner",
    ] {
        let path = std::path::PathBuf::from(candidate);
        if path.is_file() {
            return path;
        }
    }
    panic!("Qt resource verification requires qmltestrunner; set QMLTESTRUNNER to its path");
}

#[test]
fn attribute_names_and_nonanchor_urls_cannot_create_resource_markup() {
    let html=sanitize("<svg><image xlink:href='https://tracker.example/a'></image></svg><div a\"src='https://tracker.example/b' href='https://tracker.example/c'>visible</div>",&json!({"keepColors":true})).unwrap();
    let output = html["html"].as_str().unwrap();
    assert!(!output.contains("tracker.example"));
    assert!(output.contains("visible"));
    let input = format!("<div {}>body</div>", "a='x' ".repeat(1025));
    assert_eq!(parse(&input).err(), Some("html_too_complex"));
    for limit in [json!(-1), json!(0), Value::Null] {
        let result = sanitize(
            "<img src='https://cdn.example.com/a'>",
            &json!({"maxImages":limit}),
        )
        .unwrap();
        assert_eq!(result["remoteImages"], 0);
        assert_eq!(result["remoteImageSources"], json!([]));
    }
}

// A picture the reader approved arrives as a data URI in the document. Its
// bytes are not markup Qt has to lay out, so one large picture must not turn a
// small message into the plain-text refusal the moment its pictures load.
#[test]
fn approved_image_bytes_do_not_make_a_small_message_too_heavy() {
    use base64::{Engine as _, engine::general_purpose::STANDARD};
    let mut png = STANDARD
        .decode(sized_png_data(3, 3).split_once(',').unwrap().1)
        .unwrap();
    png.resize(300_000, 0);
    let data = format!("data:image/png;base64,{}", STANDARD.encode(&png));
    let source = "<p>Hello</p><img src='https://cdn.example.com/hero.png'><p>Bye</p>";
    let blocked = sanitize(
        source,
        &json!({"allowRemoteImages":false,"withReader":true}),
    )
    .unwrap();
    assert_eq!(blocked["tooHeavy"], false);
    let shown = sanitize(
        source,
        &json!({"allowRemoteImages":true,"withReader":true,
            "remoteImageData":{"https://cdn.example.com/hero.png":data}}),
    )
    .unwrap();
    assert!(shown["html"].as_str().unwrap().contains("<img"));
    assert_eq!(shown["tooHeavy"], false, "{}", shown["complexity"]);
    assert_eq!(
        shown["reader"]["tooHeavy"], false,
        "{}",
        shown["reader"]["complexity"]
    );
    // The bound on markup itself still holds.
    let markup = format!("<p>{}</p>", "x".repeat(130_000));
    assert_eq!(sanitize(&markup, &json!({})).unwrap()["tooHeavy"], true);
}

#[test]
fn inline_and_remote_images_share_the_count_budget() {
    let data = sized_png_data(3, 3).replacen("data:", "DATA:", 1);
    let source = format!(
        "<p>Body</p>{}<img src='https://cdn.example.com/remote'>",
        format!("<img src='{data}' alt='inline'>").repeat(1000)
    );
    let result = sanitize(
        &source,
        &json!({"maxImages":1,"withReader":true,
        "allowRemoteImages":true,"remoteImageData":{"https://cdn.example.com/remote":data}}),
    )
    .unwrap();
    for value in [&result, &result["reader"]] {
        let html = value["html"].as_str().unwrap();
        assert_eq!(html.matches("<img ").count(), 1);
        assert!(!html.contains("https://"));
        assert_eq!(value["blockedImages"], 1000);
    }
    let refused = sanitize(&source, &json!({"maxImages":0,"withReader":true})).unwrap();
    assert!(!refused["html"].as_str().unwrap().contains("<img"));
    assert!(!refused["reader"]["html"].as_str().unwrap().contains("<img"));
}

#[test]
fn rendered_remote_image_bytes_have_an_aggregate_budget() {
    use base64::{Engine as _, engine::general_purpose::STANDARD};
    let mut png = STANDARD
        .decode(sized_png_data(3, 3).split_once(',').unwrap().1)
        .unwrap();
    png.resize(4 * 1024 * 1024, 0);
    let data = format!("data:image/png;base64,{}", STANDARD.encode(png));
    let source = "<p>Body remains visible</p><img src='https://cdn.example.com/hero'>".to_owned()
        + &"<img src='https://cdn.example.com/hero'>".repeat(3);
    let result = sanitize(
        &source,
        &json!({"withReader":true,"allowRemoteImages":true,
        "remoteImageData":{"https://cdn.example.com/hero":data}}),
    )
    .unwrap();
    for value in [&result, &result["reader"]] {
        let html = value["html"].as_str().unwrap();
        assert_eq!(html.matches("<img ").count(), 2);
        assert!(html.contains("Body remains visible"));
        assert!(html.len() < 16 * 1024 * 1024);
        assert_eq!(value["blockedImages"], 2);
        assert_eq!(value["tooHeavy"], false);
        assert!(!html.contains("https://"));
    }
}

#[test]
fn image_policy_hidden_images_are_not_offered_for_fetch_or_rendered() {
    let source = "https://cdn.example.com/hidden.png";
    let prepared = sized_png_data(3, 3);
    for attributes in [
        "hidden",
        "hidden='false'",
        "style='display:none'",
        "style='visibility:hidden'",
    ] {
        let result = sanitize(
            &format!("<p>Visible body</p><img src='{source}' {attributes}>"),
            &json!({"withReader":true,"allowRemoteImages":true,"remoteImageData":{source:prepared}}),
        ).unwrap();
        assert_eq!(
            result["remoteImageSources"],
            json!([]),
            "{attributes} must never become a fetch candidate"
        );
        assert_eq!(result["remoteImages"], 0);
        for document in [&result, &result["reader"]] {
            assert!(
                !document["html"].as_str().unwrap().contains("<img"),
                "{attributes} must never reach Qt"
            );
            assert!(document["html"].as_str().unwrap().contains("Visible body"));
        }
    }
    for attributes in [
        "style='font-size:0'",
        "style='max-height:0'",
        "style='mso-hide:all'",
    ] {
        let result = sanitize(
            &format!("<img src='{source}' {attributes}>"),
            &json!({"allowRemoteImages":true,"remoteImageData":{source:prepared}}),
        )
        .unwrap();
        assert!(
            result["html"].as_str().unwrap().contains("<img"),
            "{attributes} alone does not hide a formatted image"
        );
    }
}

#[test]
fn image_policy_inline_trackers_never_reach_either_renderer() {
    for source in ["cid:tracking-pixel", "data:image/png;base64,iVBORw0KGgoA"] {
        for attributes in ["width='1' height='1'", "style='height:1px'"] {
            let result = sanitize(
                &format!("<p>Visible body</p><img src='{source}' {attributes}>"),
                &json!({"withReader":true}),
            )
            .unwrap();
            for document in [&result, &result["reader"]] {
                assert!(
                    !document["html"].as_str().unwrap().contains("<img"),
                    "{source} {attributes}"
                );
                assert!(document["html"].as_str().unwrap().contains("Visible body"));
            }
        }
    }
}

#[test]
fn image_policy_encoded_inline_bytes_share_the_rendered_budget() {
    use base64::{Engine as _, engine::general_purpose::STANDARD};
    let mut png = STANDARD
        .decode(sized_png_data(3, 3).split_once(',').unwrap().1)
        .unwrap();
    png.resize(4 * 1024 * 1024, 0);
    let data = format!("data:image/png;base64,{}", STANDARD.encode(png));
    let encoded = data.replacen("data:", "&#100;ata:", 1);
    let source = format!("<p>Visible body</p><img src='{encoded}'>")
        + &"<img src='https://cdn.example.com/hero'>".repeat(3);
    let result = sanitize(
        &source,
        &json!({"withReader":true,"allowRemoteImages":true,
            "remoteImageData":{"https://cdn.example.com/hero":data}}),
    )
    .unwrap();
    for document in [&result, &result["reader"]] {
        let html = document["html"].as_str().unwrap();
        assert_eq!(
            html.matches("<img ").count(),
            2,
            "the normalized inline image consumes one budget slot of bytes"
        );
        assert!(
            html.len() < 16 * 1024 * 1024,
            "refused embedded bytes must not reach Qt"
        );
        assert!(html.contains("Visible body"));
        assert_eq!(
            document["images"], 1,
            "the exposed count remains remote-only"
        );
        assert_eq!(document["blockedImages"], 2);
        assert_eq!(document["tooHeavy"], false);
    }
}

fn sized_png_data(width: u32, height: u32) -> String {
    use base64::{Engine as _, engine::general_purpose::STANDARD};
    let mut png = STANDARD.decode("iVBORw0KGgoAAAANSUhEUgAAAAMAAAADCAIAAADZSiLoAAAACXBIWXMAAA9hAAAPYQGoP6dpAAAAF0lEQVQImWM09U9nYGBgYGBgYoABBAsAGfoA8cw8ZQIAAAAASUVORK5CYII=").unwrap();
    // Invariant: only metadata changes, so exercising admission never allocates the declared pixels.
    png[16..20].copy_from_slice(&width.to_be_bytes());
    png[20..24].copy_from_slice(&height.to_be_bytes());
    let mut checksum = !0u32;
    for byte in &png[12..29] {
        checksum ^= u32::from(*byte);
        for _ in 0..8 {
            checksum = (checksum >> 1) ^ (0xedb88320 & 0u32.wrapping_sub(checksum & 1));
        }
    }
    png[29..33].copy_from_slice(&(!checksum).to_be_bytes());
    format!("data:image/png;base64,{}", STANDARD.encode(png))
}

#[test]
fn decoded_image_policy_refuses_oversized_inline_and_prepared_images_before_qt() {
    let data = sized_png_data(4096, 4096);
    let encoded = data.replacen("data:", "&#100;ata:", 1);
    let result = sanitize(
        &format!(
            "<p>Visible body</p><img src='{encoded}'><img src='https://cdn.example.com/oversized'>"
        ),
        &json!({"withReader":true,"allowRemoteImages":true,
            "remoteImageData":{"https://cdn.example.com/oversized":data}}),
    )
    .unwrap();
    for document in [&result, &result["reader"]] {
        let html = document["html"].as_str().unwrap();
        assert!(
            !html.contains("<img"),
            "oversized metadata must not reach Qt"
        );
        assert!(html.contains("Visible body"));
    }
}

#[test]
fn decoded_image_policy_inline_and_remote_images_share_the_pixel_budget() {
    let data = sized_png_data(2048, 2048);
    let source = format!(
        "<p>Visible body</p><img src='{data}'><img src='https://cdn.example.com/large'><img src='{data}'><img src='https://cdn.example.com/large'><img src='{data}'>"
    );
    let result = sanitize(
        &source,
        &json!({"withReader":true,"allowRemoteImages":true,
            "remoteImageData":{"https://cdn.example.com/large":data}}),
    )
    .unwrap();
    for document in [&result, &result["reader"]] {
        let html = document["html"].as_str().unwrap();
        assert_eq!(
            html.matches("<img ").count(),
            4,
            "the fifth image would exceed 128 MiB of decoded pixels"
        );
        assert!(html.contains("Visible body"));
        assert_eq!(document["images"], 2);
        assert_eq!(document["blockedImages"], 1);
        assert_eq!(document["tooHeavy"], false);
    }
}

#[test]
fn decoded_image_policy_unresolved_cid_never_reaches_qt() {
    let result = sanitize(
        "<p>Visible body</p><img src='cid:message-logo' alt='Logo'>",
        &json!({"withReader":true}),
    )
    .unwrap();
    for document in [&result, &result["reader"]] {
        let html = document["html"].as_str().unwrap();
        assert!(
            !html.contains("<img"),
            "unresolved bytes cannot be admitted without a pixel bound"
        );
        assert!(html.contains("Visible body"));
        assert_eq!(document["blockedImages"], 1);
    }
}
