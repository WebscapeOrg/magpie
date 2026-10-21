//! Async, bounded, cancellation-safe transport for official provider tools.
#[cfg(windows)]
use std::process::Stdio;
use std::time::Duration;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWriteExt};
#[cfg(windows)]
use tokio::process::{Child, Command};

#[cfg(windows)]
struct ChildReaper(Option<Child>);
#[cfg(windows)]
impl Drop for ChildReaper {
    fn drop(&mut self) {
        let Some(mut child) = self.0.take() else {
            return;
        };
        if matches!(child.try_wait(), Ok(Some(_))) {
            return;
        }
        let _ = child.start_kill();
        if let Ok(runtime) = tokio::runtime::Handle::try_current() {
            runtime.spawn(async move {
                let _ = child.wait().await;
            });
        }
    }
}

#[derive(Debug)]
pub struct Output {
    pub success: bool,
    pub stdout: Vec<u8>,
    pub stderr: Vec<u8>,
}
async fn read(mut pipe: impl AsyncRead + Unpin, limit: usize) -> Result<Vec<u8>, &'static str> {
    let mut out = Vec::new();
    let mut bytes = [0; 16384];
    loop {
        let count = pipe
            .read(&mut bytes)
            .await
            .map_err(|_| "process_output_failed")?;
        if count == 0 {
            return Ok(out);
        }
        if count > limit.saturating_sub(out.len()) {
            return Err("process_output_too_large");
        }
        out.extend_from_slice(&bytes[..count]);
    }
}
pub async fn run(
    program: &str,
    args: &[String],
    input: &[u8],
    timeout: Duration,
    limit: usize,
) -> Result<Output, &'static str> {
    run_with_stderr_limit(program, args, input, timeout, limit, limit.min(65536)).await
}
#[cfg(windows)]
pub(super) async fn run_with_stderr_limit(
    program: &str,
    args: &[String],
    input: &[u8],
    timeout: Duration,
    limit: usize,
    stderr_limit: usize,
) -> Result<Output, &'static str> {
    if input.len() > limit {
        return Err("process_input_too_large");
    }
    let mut command = Command::new(program);
    command
        .args(args)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);
    super::platform::configure(command.as_std_mut());
    let child = command.spawn().map_err(|_| "process_unavailable")?;
    let mut reaper = ChildReaper(Some(child));
    let child = reaper.0.as_mut().ok_or("process_unavailable")?;
    // Windows assigns the still-suspended process to its job before resuming it.
    // A failed attach cannot execute any child code.
    let group = super::platform::Tree::for_async_child(child)?;
    let mut stdin = child.stdin.take().ok_or("process_pipe_failed")?;
    let stdout = child.stdout.take().ok_or("process_pipe_failed")?;
    let stderr = child.stderr.take().ok_or("process_pipe_failed")?;
    let result = tokio::time::timeout(timeout, async {
        let write = async {
            stdin
                .write_all(input)
                .await
                .map_err(|_| "process_input_failed")?;
            drop(stdin);
            Ok(())
        };
        let wait = async { child.wait().await.map_err(|_| "process_wait_failed") };
        let (_, stdout, stderr, status) =
            tokio::try_join!(write, read(stdout, limit), read(stderr, stderr_limit), wait)?;
        Ok(Output {
            success: status.success(),
            stdout,
            stderr,
        })
    })
    .await
    .unwrap_or(Err("process_timed_out"));
    // Also terminate descendants retaining inherited pipes, including on cancellation.
    drop(group);
    if result.is_err() {
        let _ = child.kill().await;
        let _ = child.wait().await;
    }
    result
}

#[cfg(unix)]
pub(super) async fn run_with_stderr_limit(
    program: &str,
    args: &[String],
    input: &[u8],
    timeout: Duration,
    limit: usize,
    stderr_limit: usize,
) -> Result<Output, &'static str> {
    use tokio::net::unix::pipe::{Receiver, Sender};
    use tokio::signal::unix::{SignalKind, signal};
    if input.len() > limit {
        return Err("process_input_too_large");
    }
    let mut exits = signal(SignalKind::child()).map_err(|_| "process_wait_failed")?;
    let mut child = super::spawn_managed(program, args)?;
    let mut stdin = Sender::from_owned_fd(child.take_stdin().ok_or("process_pipe_failed")?.into())
        .map_err(|_| "process_pipe_failed")?;
    let stdout = Receiver::from_owned_fd(child.take_stdout().ok_or("process_pipe_failed")?.into())
        .map_err(|_| "process_pipe_failed")?;
    let stderr = Receiver::from_owned_fd(child.take_stderr().ok_or("process_pipe_failed")?.into())
        .map_err(|_| "process_pipe_failed")?;
    tokio::time::timeout(timeout, async {
        let write = async {
            stdin
                .write_all(input)
                .await
                .map_err(|_| "process_input_failed")?;
            drop(stdin);
            Ok(())
        };
        let wait = async {
            loop {
                if let Some(status) = child.try_wait().map_err(|_| "process_wait_failed")? {
                    return Ok(status);
                }
                exits.recv().await.ok_or("process_wait_failed")?;
            }
        };
        let (_, stdout, stderr, status) =
            tokio::try_join!(write, read(stdout, limit), read(stderr, stderr_limit), wait)?;
        Ok(Output {
            success: status.success(),
            stdout,
            stderr,
        })
    })
    .await
    .unwrap_or(Err("process_timed_out"))
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    #[tokio::test]
    async fn full_duplex_and_deadlines() {
        let input = vec![42; 512 * 1024];
        assert_eq!(
            run("/bin/cat", &[], &input, Duration::from_secs(2), input.len())
                .await
                .unwrap()
                .stdout,
            input
        );
        let start = std::time::Instant::now();
        assert!(matches!(
            run(
                "/bin/sh",
                &["-c".into(), "sleep 20 & wait".into()],
                b"",
                Duration::from_millis(50),
                1024
            )
            .await,
            Err("process_timed_out")
        ));
        assert!(start.elapsed() < Duration::from_secs(1));
    }
    #[tokio::test]
    async fn requests_overlap_and_cancellation_kills_the_process_group() {
        let root = std::env::temp_dir().join(format!(
            "omamail-async-overlap-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir(&root).unwrap();
        let root_arg = root.to_str().unwrap().to_owned();
        // Each child announces that it started, then refuses to finish until
        // all three announcements exist. A serialized runner would deadlock
        // and time out; successful output therefore proves actual overlap
        // without relying on scheduler-sensitive elapsed time.
        let script = "import os,sys,time\nroot,name=sys.argv[1:3]\nopen(os.path.join(root,name),'x').close()\nwhile len(os.listdir(root)) < 3: time.sleep(0.01)\nsys.stdout.write('ok')";
        let a_args = vec!["-c".into(), script.into(), root_arg.clone(), "a".into()];
        let b_args = vec!["-c".into(), script.into(), root_arg.clone(), "b".into()];
        let c_args = vec!["-c".into(), script.into(), root_arg, "c".into()];
        let (a, b, c) = tokio::join!(
            run("python3", &a_args, b"", Duration::from_secs(15), 1024),
            run("python3", &b_args, b"", Duration::from_secs(15), 1024),
            run("python3", &c_args, b"", Duration::from_secs(15), 1024)
        );
        for result in [a, b, c] {
            assert_eq!(result.unwrap().stdout, b"ok");
        }
        let marker = root.join("cancel");
        let path = marker.to_str().unwrap().to_owned();
        let task = tokio::spawn(async move {
            run("python3", &["-c".into(), "import os,sys,time; open(sys.argv[1],'w').write(str(os.getpid())); time.sleep(30)".into(), path], b"", Duration::from_secs(30), 1024).await
        });
        // The file exists from open() and holds the pid only after write(),
        // so an empty read is the child mid-way, not a failure.
        let mut pid = None;
        for _ in 0..1500 {
            pid = std::fs::read_to_string(&marker)
                .ok()
                .and_then(|text| text.parse::<i32>().ok());
            if pid.is_some() {
                break;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        let pid = pid.expect("child wrote its pid");
        task.abort();
        let _ = task.await;
        for _ in 0..100 {
            if unsafe { libc::kill(pid, 0) } != 0 {
                break;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        assert_ne!(
            unsafe { libc::kill(pid, 0) },
            0,
            "cancelled child must be gone"
        );
        std::fs::remove_dir_all(root).unwrap();
    }

    #[tokio::test]
    async fn cancellation_prevents_descendant_writes() {
        let root = std::env::temp_dir().join(format!(
            "omamail-async-descendant-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir(&root).unwrap();
        let script = r#"import os,sys,time
root=sys.argv[1]
pid=os.fork()
if pid:
    os.waitpid(pid,0)
else:
    open(os.path.join(root,'ready'),'x').close()
    while not os.path.exists(os.path.join(root,'release')): time.sleep(0.01)
    open(os.path.join(root,'effect'),'x').close()
"#;
        let launch = |path: std::path::PathBuf| {
            tokio::spawn(async move {
                run(
                    "python3",
                    &["-c".into(), script.into(), path.to_str().unwrap().into()],
                    b"",
                    Duration::from_secs(15),
                    1024,
                )
                .await
            })
        };
        for cancel in [false, true] {
            let path = root.join(if cancel { "cancelled" } else { "control" });
            std::fs::create_dir(&path).unwrap();
            let task = launch(path.clone());
            tokio::time::timeout(Duration::from_secs(5), async {
                while !path.join("ready").exists() {
                    tokio::time::sleep(Duration::from_millis(10)).await;
                }
            })
            .await
            .unwrap();
            if cancel {
                task.abort();
                assert!(task.await.unwrap_err().is_cancelled());
                std::fs::write(path.join("release"), b"").unwrap();
                tokio::time::sleep(Duration::from_millis(200)).await;
                assert!(
                    !path.join("effect").exists(),
                    "cancelled descendant wrote a file"
                );
                continue;
            }
            std::fs::write(path.join("release"), b"").unwrap();
            assert!(task.await.unwrap().unwrap().success);
            assert!(
                path.join("effect").exists(),
                "control must demonstrate the forbidden write"
            );
        }
        std::fs::remove_dir_all(root).unwrap();
    }

    #[tokio::test]
    async fn output_is_bounded() {
        assert!(matches!(
            run(
                "/bin/sh",
                &["-c".into(), "while :; do printf 123456789; done".into()],
                b"",
                Duration::from_secs(2),
                64
            )
            .await,
            Err("process_output_too_large")
        ));
    }
}
