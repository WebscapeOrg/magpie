use base64::{Engine, engine::general_purpose::STANDARD};
use image::{ImageFormat, ImageReader, imageops::FilterType};
use serde_json::{Value, json};
use std::io::Cursor;

const MAX_INPUT: usize = 8 * 1024 * 1024;
const MAX_OUTPUT: usize = 512 * 1024;
const EDGE: u32 = 384;
static WORKERS: tokio::sync::Semaphore = tokio::sync::Semaphore::const_new(2);

fn raster(bytes: &[u8]) -> Result<String, &'static str> {
    let mut reader = ImageReader::new(Cursor::new(bytes))
        .with_guessed_format()
        .map_err(|_| "attachment_thumbnail_unavailable")?;
    if !matches!(
        reader.format(),
        Some(
            ImageFormat::Png
                | ImageFormat::Jpeg
                | ImageFormat::Gif
                | ImageFormat::WebP
                | ImageFormat::Bmp
        )
    ) {
        return Err("attachment_thumbnail_unavailable");
    }
    let mut limits = image::Limits::default();
    limits.max_image_width = Some(4096);
    limits.max_image_height = Some(4096);
    limits.max_alloc = Some(64 * 1024 * 1024);
    reader.limits(limits);
    let image = reader
        .decode()
        .map_err(|_| "attachment_thumbnail_unavailable")?;
    let image = image.resize(EDGE, EDGE, FilterType::Triangle);
    let mut output = Cursor::new(Vec::new());
    image
        .write_to(&mut output, ImageFormat::Png)
        .map_err(|_| "attachment_thumbnail_unavailable")?;
    if output.get_ref().len() > MAX_OUTPUT {
        return Err("attachment_thumbnail_unavailable");
    }
    Ok(format!(
        "data:image/png;base64,{}",
        STANDARD.encode(output.into_inner())
    ))
}

#[cfg(target_os = "linux")]
fn sandbox(program: &str, arguments: &[&str]) -> tokio::process::Command {
    let mut command = tokio::process::Command::new("/usr/bin/bwrap");
    command
        .args([
            "--unshare-all",
            "--die-with-parent",
            "--new-session",
            "--cap-drop",
            "ALL",
            "--clearenv",
            "--ro-bind",
            "/usr",
            "/usr",
            "--ro-bind",
            "/lib",
            "/lib",
            "--ro-bind-try",
            "/lib64",
            "/lib64",
            "--proc",
            "/proc",
            "--dev",
            "/dev",
            "--tmpfs",
            "/tmp",
            "--setenv",
            "HOME",
            "/tmp",
            "--chdir",
            "/tmp",
            "/usr/bin/prlimit",
            "--as=536870912",
            "--cpu=4",
            "--fsize=1048576",
            "--nproc=32",
            "--",
            program,
        ])
        .args(arguments)
        .env_clear()
        .kill_on_drop(true);
    command
}

#[cfg(target_os = "linux")]
async fn pdf(bytes: Vec<u8>) -> Result<Vec<u8>, &'static str> {
    use std::{process::Stdio, time::Duration};
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    let mut child = sandbox(
        "/usr/bin/pdftoppm",
        &[
            "-f",
            "1",
            "-l",
            "1",
            "-singlefile",
            "-scale-to",
            "384",
            "-png",
            "-hide-annotations",
            "-",
        ],
    )
    .stdin(Stdio::piped())
    .stdout(Stdio::piped())
    .stderr(Stdio::null())
    .spawn()
    .map_err(|_| "attachment_thumbnail_unavailable")?;
    let mut input = child
        .stdin
        .take()
        .ok_or("attachment_thumbnail_unavailable")?;
    let output = child
        .stdout
        .take()
        .ok_or("attachment_thumbnail_unavailable")?;
    let render = async {
        let write = async move {
            input.write_all(&bytes).await?;
            input.shutdown().await?;
            drop(input);
            Ok::<(), std::io::Error>(())
        };
        let read = async {
            let mut data = Vec::new();
            output
                .take(MAX_OUTPUT as u64 + 1)
                .read_to_end(&mut data)
                .await?;
            if data.len() > MAX_OUTPUT {
                return Err(std::io::Error::other("thumbnail too large"));
            }
            Ok(data)
        };
        let (_, data) =
            tokio::try_join!(write, read).map_err(|_| "attachment_thumbnail_unavailable")?;
        if !child
            .wait()
            .await
            .map_err(|_| "attachment_thumbnail_unavailable")?
            .success()
        {
            return Err("attachment_thumbnail_unavailable");
        }
        Ok(data)
    };
    tokio::time::timeout(Duration::from_secs(6), render)
        .await
        .map_err(|_| "attachment_thumbnail_unavailable")?
}

#[cfg(not(target_os = "linux"))]
async fn pdf(_bytes: Vec<u8>) -> Result<Vec<u8>, &'static str> {
    Err("attachment_thumbnail_unavailable")
}

pub async fn prepare(params: &Value) -> Result<Value, &'static str> {
    let permit = WORKERS
        .try_acquire()
        .map_err(|_| "attachment_thumbnail_unavailable")?;
    let fields = params.as_object().ok_or("invalid_params")?;
    if fields.len() != 2 || !fields.contains_key("data") || !fields.contains_key("mimeType") {
        return Err("invalid_params");
    }
    let data = params["data"].as_str().ok_or("invalid_params")?;
    let mime = params["mimeType"].as_str().ok_or("invalid_params")?;
    if data.len() > MAX_INPUT.div_ceil(3) * 4 + 1024 {
        return Err("attachment_too_large");
    }
    let bytes = super::decode(data)?;
    if bytes.len() > MAX_INPUT {
        return Err("attachment_too_large");
    }
    let bytes = if mime == "application/pdf" && bytes.starts_with(b"%PDF-") {
        pdf(bytes).await?
    } else if matches!(
        mime,
        "image/png" | "image/jpeg" | "image/gif" | "image/webp" | "image/bmp"
    ) {
        bytes
    } else {
        return Err("attachment_thumbnail_unavailable");
    };
    let data = tokio::task::spawn_blocking(move || {
        let _permit = permit;
        raster(&bytes)
    })
    .await
    .map_err(|_| "worker_failed")??;
    Ok(json!({"data":data}))
}

#[cfg(test)]
mod tests {
    use super::*;
    static LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

    fn params(bytes: &[u8], mime: &str) -> Value {
        json!({"data":STANDARD.encode(bytes),"mimeType":mime})
    }

    fn png(width: u32, height: u32) -> Vec<u8> {
        let image = image::RgbImage::from_pixel(width, height, image::Rgb([80, 120, 160]));
        let mut data = Cursor::new(Vec::new());
        image.write_to(&mut data, ImageFormat::Png).unwrap();
        data.into_inner()
    }

    #[test]
    fn round2_cancelled_preview_keeps_worker_slot_until_rendering_stops() {
        let _guard = LOCK.lock().unwrap();
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .max_blocking_threads(1)
            .build()
            .unwrap();
        let available = runtime.block_on(async {
            let (release, wait) = std::sync::mpsc::channel::<()>();
            let (started, ready) = tokio::sync::oneshot::channel();
            let blocker = tokio::task::spawn_blocking(move || {
                started.send(()).unwrap();
                let _ = wait.recv();
            });
            ready.await.unwrap();
            let input = params(&png(1, 1), "image/png");
            let preview = tokio::spawn(async move { prepare(&input).await });
            tokio::time::timeout(std::time::Duration::from_secs(2), async {
                while WORKERS.available_permits() == 2 {
                    tokio::task::yield_now().await;
                }
            })
            .await
            .unwrap();
            preview.abort();
            assert!(preview.await.unwrap_err().is_cancelled());
            let available = WORKERS.available_permits();
            drop(release);
            blocker.await.unwrap();
            available
        });
        runtime.shutdown_timeout(std::time::Duration::from_secs(2));
        assert_eq!(
            available, 1,
            "cancelling the waiter must not admit another renderer"
        );
        assert_eq!(WORKERS.available_permits(), 2);
    }

    #[tokio::test]
    async fn rasters_become_bounded_static_pngs_with_their_aspect_ratio() {
        let _guard = LOCK.lock().unwrap();
        let result = prepare(&params(&png(1200, 600), "image/png"))
            .await
            .unwrap();
        let bytes = STANDARD
            .decode(result["data"].as_str().unwrap().split_once(',').unwrap().1)
            .unwrap();
        assert!(bytes.len() <= MAX_OUTPUT);
        assert_eq!(image::load_from_memory(&bytes).unwrap().width(), EDGE);
        assert_eq!(image::load_from_memory(&bytes).unwrap().height(), EDGE / 2);
        assert!(bytes.starts_with(b"\x89PNG\r\n\x1a\n"));
    }

    #[tokio::test]
    async fn active_documents_urls_bad_encodings_and_excessive_images_produce_no_preview() {
        let _guard = LOCK.lock().unwrap();
        for mime in ["image/svg+xml", "text/html", "image/png"] {
            assert!(
                prepare(&params(
                    b"<svg><image href='http://127.0.0.1/tracker'/></svg>",
                    mime
                ))
                .await
                .is_err()
            );
        }
        assert!(
            prepare(&json!({"data":"http://127.0.0.1/tracker","mimeType":"image/png"}))
                .await
                .is_err()
        );
        assert!(prepare(&params(&png(4097, 1), "image/png")).await.is_err());
        assert!(
            prepare(&params(&vec![0; MAX_INPUT + 1], "image/png"))
                .await
                .is_err()
        );
        assert!(
            prepare(&json!({"data":"", "mimeType":"image/png", "path":"/etc/passwd"}))
                .await
                .is_err()
        );
    }

    #[cfg(target_os = "linux")]
    fn pdf_fixture() -> Vec<u8> {
        let content = "BT /F1 24 Tf 24 100 Td (Synthetic report) Tj ET";
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>".to_owned(),
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>".to_owned(),
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 180] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>".to_owned(),
            format!("<< /Length {} >>\nstream\n{content}\nendstream", content.len()),
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>".to_owned(),
        ];
        let mut data = "%PDF-1.4\n".to_owned();
        let mut offsets = vec![0];
        for (index, object) in objects.iter().enumerate() {
            offsets.push(data.len());
            data.push_str(&format!("{} 0 obj\n{object}\nendobj\n", index + 1));
        }
        let xref = data.len();
        data.push_str("xref\n0 6\n0000000000 65535 f \n");
        for offset in offsets.iter().skip(1) {
            data.push_str(&format!("{offset:010} 00000 n \n"));
        }
        data.push_str(&format!(
            "trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n"
        ));
        data.into_bytes()
    }

    #[cfg(target_os = "linux")]
    #[tokio::test]
    async fn a_pdf_first_page_renders_inside_the_isolated_worker() {
        let _guard = LOCK.lock().unwrap();
        if !std::path::Path::new("/usr/bin/pdftoppm").exists()
            || !std::path::Path::new("/usr/bin/bwrap").exists()
        {
            eprintln!("PDF worker unavailable on this host; raster previews remain supported");
            return;
        }
        let result = prepare(&params(&pdf_fixture(), "application/pdf"))
            .await
            .unwrap();
        assert!(
            result["data"]
                .as_str()
                .unwrap()
                .starts_with("data:image/png;base64,")
        );
        assert!(
            prepare(&params(b"%PDF-broken", "application/pdf"))
                .await
                .is_err()
        );
    }

    #[cfg(target_os = "linux")]
    #[tokio::test]
    async fn the_pdf_worker_cannot_read_host_private_files_write_them_or_reach_host_network() {
        use std::{net::TcpListener, process::Stdio};
        if !std::path::Path::new("/usr/bin/bwrap").exists() {
            return;
        }
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        listener.set_nonblocking(true).unwrap();
        let port = listener.local_addr().unwrap().port().to_string();
        let directory =
            std::env::temp_dir().join(format!("magpie-thumbnail-boundary-{}", std::process::id()));
        std::fs::create_dir_all(&directory).unwrap();
        let secret = directory.join("private");
        let output = directory.join("unexpected-write");
        std::fs::write(&secret, "synthetic-private-sentinel").unwrap();
        let probe = "import sys,socket,json\nr=[]\nfor p,mode in [(sys.argv[1],'r'),(sys.argv[2],'w')]:\n try:\n  f=open(p,mode);f.close();r.append(True)\n except OSError:r.append(False)\ns=socket.socket();s.settimeout(.2)\ntry:s.connect(('127.0.0.1',int(sys.argv[3])));r.append(True)\nexcept OSError:r.append(False)\nprint(json.dumps(r))";
        let result = sandbox(
            "/usr/bin/python3",
            &[
                "-c",
                probe,
                secret.to_str().unwrap(),
                output.to_str().unwrap(),
                &port,
            ],
        )
        .stdin(Stdio::null())
        .output()
        .await
        .unwrap();
        assert!(result.status.success(), "the real sandbox probe must run");
        assert_eq!(
            serde_json::from_slice::<Value>(&result.stdout).unwrap(),
            json!([false, false, false])
        );
        assert!(!output.exists());
        assert_eq!(
            std::fs::read_to_string(&secret).unwrap(),
            "synthetic-private-sentinel"
        );
        assert!(
            matches!(listener.accept(), Err(error) if error.kind() == std::io::ErrorKind::WouldBlock)
        );
        std::fs::remove_dir_all(directory).unwrap();
    }
}
