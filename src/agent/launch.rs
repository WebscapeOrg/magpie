use std::{
    os::unix::process::CommandExt,
    path::Path,
    process::{Command, Stdio},
};

pub(super) fn command(
    operation: &str,
    id: Option<&str>,
    directory: Option<&Path>,
) -> Result<Command, &'static str> {
    let executable = std::env::current_exe().map_err(|_| "agent_worker_unavailable")?;
    let supervised = cfg!(target_os = "linux")
        && std::env::var_os("MAGPIE_WORKER_SERVICES").is_some_and(|value| value == "1");
    build(
        &executable,
        operation,
        id,
        directory,
        supervised,
        std::env::vars_os(),
    )
}

fn build(
    executable: &Path,
    operation: &str,
    id: Option<&str>,
    directory: Option<&Path>,
    supervised: bool,
    environment: impl IntoIterator<Item = (std::ffi::OsString, std::ffi::OsString)>,
) -> Result<Command, &'static str> {
    let unit = match (operation, id) {
        ("agent-worker", Some(id))
            if id.len() == 32
                && id
                    .bytes()
                    .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b)) =>
        {
            format!("magpie-ai-{id}")
        }
        ("agent-opencode-server", None) => "magpie-ai-opencode".to_owned(),
        _ => return Err("agent_worker_unavailable"),
    };
    let mut command = if supervised {
        let mut command = Command::new("/usr/bin/systemd-run");
        command.args([
            "--user",
            "--quiet",
            "--no-block",
            "--collect",
            "--no-ask-password",
            "--service-type=exec",
            "--expand-environment=no",
            "--property=UMask=0077",
            "--property=NoNewPrivileges=true",
            "--property=KillMode=control-group",
            "--property=TimeoutStopSec=30",
            "--property=StandardInput=null",
            "--property=StandardOutput=null",
            "--property=StandardError=null",
        ]);
        command.arg(format!("--unit={unit}"));
        command.arg("--setenv=MAGPIE_WORKER_SERVICES=1");
        for (key, value) in environment {
            if [
                "PATH",
                "XDG_STATE_HOME",
                "XDG_DATA_HOME",
                "XDG_CONFIG_HOME",
                "XDG_CACHE_HOME",
                "XDG_RUNTIME_DIR",
            ]
            .iter()
            .any(|name| key == *name)
            {
                let mut argument = std::ffi::OsString::from("--setenv=");
                argument.push(key);
                argument.push("=");
                argument.push(value);
                command.arg(argument);
            }
        }
        if operation == "agent-worker" {
            command.arg("--property=RuntimeMaxSec=3900");
        }
        if let Some(directory) = directory {
            let mut argument = std::ffi::OsString::from("--working-directory=");
            argument.push(directory.as_os_str());
            command.arg(argument);
        }
        command.arg("--").arg(executable);
        command
    } else {
        let mut command = Command::new(executable);
        if let Some(directory) = directory {
            command.current_dir(directory);
        }
        command
    };
    command.arg(operation);
    if let Some(id) = id {
        command.arg(id);
    }
    command
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    unsafe {
        command.pre_exec(|| {
            if libc::setsid() < 0 {
                return Err(std::io::Error::last_os_error());
            }
            Ok(())
        });
    }
    Ok(command)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn supervision_keeps_literal_argv_and_does_not_copy_credentials() {
        let id = "0123456789abcdef0123456789abcdef";
        let command = build(
            Path::new("/private/bin/omamail"),
            "agent-worker",
            Some(id),
            Some(Path::new("/private/AI $literal")),
            true,
            [
                ("PATH".into(), "/safe/$literal/bin".into()),
                ("SECRET_TOKEN".into(), "must-not-leak".into()),
            ],
        )
        .unwrap();
        let args: Vec<_> = command.get_args().map(|s| s.to_str().unwrap()).collect();
        assert_eq!(command.get_program(), "/usr/bin/systemd-run");
        assert_eq!(
            &args[args.len() - 3..],
            &["/private/bin/omamail", "agent-worker", id]
        );
        assert!(args.contains(&"--expand-environment=no"));
        assert!(args.contains(&"--working-directory=/private/AI $literal"));
        assert!(args.contains(&"--setenv=PATH=/safe/$literal/bin"));
        assert!(
            !args
                .iter()
                .any(|v| v.contains("SECRET") || v.contains("must-not-leak"))
        );
        assert!(
            build(
                Path::new("/private/bin/omamail"),
                "agent-worker",
                Some("../other"),
                None,
                true,
                []
            )
            .is_err()
        );
        assert!(
            build(
                Path::new("/private/bin/omamail"),
                "arbitrary",
                None,
                None,
                true,
                []
            )
            .is_err()
        );
    }
}
