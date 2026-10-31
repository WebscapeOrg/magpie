use crate::platform::{dirs::AppDirs, ipc::LocalEndpoint, private_fs};
use clap::Subcommand;
use serde_json::{Value, json};
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};

#[derive(Subcommand)]
pub(super) enum Command {
    /// Show a new pairing code; enter it in Magpie's Enterprise settings on your iPhone
    Pair,
    /// List connected iPhones without exposing their access tokens
    List,
    /// Preview disconnecting one iPhone; add --execute to disconnect it
    Disconnect {
        #[arg(value_parser = device_id)]
        id: String,
        #[arg(long)]
        execute: bool,
    },
}

fn device_id(value: &str) -> Result<String, &'static str> {
    if value.len() == 64
        && value
            .bytes()
            .all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase())
    {
        Ok(value.to_owned())
    } else {
        Err("Use the full device ID shown by omamail phone list.")
    }
}

async fn request(method: &str, params: Value) -> Result<Value, &'static str> {
    if !crate::backend::daemon::enabled()? {
        return Err("phone_engine_not_enabled");
    }
    let mut dirs = AppDirs::discover()?;
    if std::env::var_os("XDG_RUNTIME_DIR").is_none_or(|value| value.is_empty()) {
        dirs.runtime =
            std::path::PathBuf::from(format!("/run/user/{}", unsafe { libc::geteuid() }));
    }
    let directory = private_fs::directories_readonly(&dirs.runtime, &["omamail", "engine"])?
        .ok_or("phone_engine_unavailable")?;
    let endpoint = LocalEndpoint::directory(directory)?;
    let mut stream = tokio::time::timeout(Duration::from_secs(5), endpoint.connect())
        .await
        .map_err(|_| "phone_engine_unavailable")?
        .map_err(|_| "phone_engine_unavailable")?;
    let mut bytes =
        serde_json::to_vec(&json!({"jsonrpc":"2.0","id":1,"method":method,"params":params}))
            .map_err(|_| "phone_request_failed")?;
    bytes.push(b'\n');
    let deadline = tokio::time::Instant::now() + Duration::from_secs(30);
    tokio::time::timeout_at(deadline, stream.write_all(&bytes))
        .await
        .map_err(|_| "phone_result_unknown")?
        .map_err(|_| "phone_result_unknown")?;
    reply(BufReader::new(stream), deadline).await
}

async fn reply(
    mut input: impl tokio::io::AsyncBufRead + Unpin,
    deadline: tokio::time::Instant,
) -> Result<Value, &'static str> {
    loop {
        if tokio::time::Instant::now() >= deadline {
            return Err("phone_result_unknown");
        }
        let mut frame = Vec::new();
        let count = tokio::time::timeout_at(
            deadline,
            (&mut input)
                .take(1024 * 1024 + 1)
                .read_until(b'\n', &mut frame),
        )
        .await
        .map_err(|_| "phone_result_unknown")?
        .map_err(|_| "phone_result_unknown")?;
        if count == 0 || count > 1024 * 1024 || frame.last() != Some(&b'\n') {
            return Err("phone_result_unknown");
        }
        let answer: Value = serde_json::from_slice(&frame).map_err(|_| "phone_result_unknown")?;
        if answer["id"] != 1 {
            continue;
        }
        if answer["jsonrpc"] != "2.0" {
            return Err("phone_result_unknown");
        }
        if answer.get("error").is_some() {
            return Err(match answer["error"]["message"].as_str() {
                Some("phone_account_required") => "phone_account_required",
                Some("phone_service_unavailable") => "phone_service_unavailable",
                Some("Method not found") => "phone_backend_needs_update",
                _ => "phone_request_failed",
            });
        }
        return answer.get("result").cloned().ok_or("phone_result_unknown");
    }
}

async fn perform(command: Command) -> Result<Value, &'static str> {
    if matches!(command, Command::Pair) {
        let result = request("phone.pairBegin", json!({})).await?;
        let code = result["code"]
            .as_str()
            .filter(|s| s.len() == 6 && s.bytes().all(|b| b.is_ascii_digit()))
            .ok_or("phone_result_unknown")?;
        if result["expiresInSeconds"] != 300 {
            return Err("phone_result_unknown");
        }
        return Ok(json!({"code":code,"expiresInSeconds":300}));
    }
    let result = request("phone.devices", json!({})).await?;
    let devices = result["devices"].as_array().ok_or("phone_result_unknown")?;
    let devices = devices
        .iter()
        .map(|device| {
            let id = device["id"].as_str().ok_or("phone_result_unknown")?;
            device_id(id).map_err(|_| "phone_result_unknown")?;
            let name = device["name"].as_str().ok_or("phone_result_unknown")?;
            Ok(json!({"id":id,"name":name}))
        })
        .collect::<Result<Vec<_>, &'static str>>()?;
    let Command::Disconnect { id, execute } = command else {
        return Ok(json!({"devices":devices}));
    };
    let device = devices
        .into_iter()
        .find(|device| device["id"] == id)
        .ok_or("phone_device_not_found")?;
    if execute {
        let result = request("phone.revoke", json!({"id":id})).await?;
        if result["revoked"] != true {
            return Err("phone_result_unknown");
        }
    }
    Ok(json!({"device":device,"revoked":execute,"preview":!execute}))
}

fn explanation(code: &str) -> &'static str {
    match code {
        "phone_engine_not_enabled" => {
            "Enable Magpie's Enterprise mail service before pairing an iPhone."
        }
        "phone_engine_unavailable" => {
            "Magpie's mail service is not reachable. Check that it is running on Enterprise."
        }
        "phone_account_required" => "Add a mail account to Magpie on Enterprise before pairing.",
        "phone_service_unavailable" => {
            "Magpie's iPhone service is not ready. Check its Enterprise service setup."
        }
        "phone_backend_needs_update" => {
            "Update Enterprise's running Magpie mail service before pairing."
        }
        "phone_device_not_found" => {
            "That iPhone is not connected. Run omamail phone list for current device IDs."
        }
        "phone_result_unknown" => {
            "The result could not be confirmed. Run omamail phone list to check a disconnection, or phone pair to request a new code."
        }
        _ => {
            "Magpie could not complete the request. Check the Enterprise mail service and its private file permissions."
        }
    }
}

fn human(result: &Value) -> String {
    if let Some(code) = result["code"].as_str() {
        return format!(
            "Pairing code: {code}\n\nOn your iPhone, open Magpie → Settings → Enterprise and enter this code.\nIt expires in 5 minutes. Requesting another code replaces this one.\n"
        );
    }
    if let Some(devices) = result["devices"].as_array() {
        if devices.is_empty() {
            return "No iPhones are connected. Run omamail phone pair to connect one.\n".into();
        }
        return devices
            .iter()
            .map(|device| {
                format!(
                    "{}\n  Device ID: {}\n",
                    super::output::safe(device["name"].as_str().unwrap()),
                    device["id"].as_str().unwrap()
                )
            })
            .collect::<Vec<_>>()
            .join("\n");
    }
    let name = super::output::safe(result["device"]["name"].as_str().unwrap());
    if result["revoked"] == true {
        return format!(
            "Disconnected {name} from Enterprise. Its mail on the iPhone is unchanged.\n"
        );
    }
    let id = result["device"]["id"].as_str().unwrap();
    format!(
        "Would disconnect {name} from Enterprise. Its mail on the iPhone stays unchanged.\nTo disconnect it, run:\n  omamail phone disconnect {id} --execute\n"
    )
}

pub(super) fn run(command: Command, json_output: bool) {
    if !json_output {
        eprintln!("Contacting Magpie on Enterprise…");
    }
    let result = crate::backend::runtime()
        .map_err(|_| "phone_request_failed")
        .and_then(|runtime| runtime.block_on(perform(command)));
    if json_output {
        super::output::print_result(result, true, true);
        return;
    }
    match result {
        Ok(result) => print!("{}", human(&result)),
        Err(code) => {
            eprintln!("{}", explanation(code));
            std::process::exit(1);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn ready_notifications_cannot_extend_the_deadline() {
        let frames =
            b"{\"method\":\"local.changed\"}\n{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}\n";
        assert_eq!(
            reply(
                &frames[..],
                tokio::time::Instant::now() - Duration::from_secs(1)
            )
            .await,
            Err("phone_result_unknown")
        );
        assert_eq!(
            reply(
                &frames[..],
                tokio::time::Instant::now() + Duration::from_secs(1)
            )
            .await
            .unwrap(),
            json!({})
        );
    }

    #[tokio::test]
    async fn untrusted_errors_and_truncated_frames_are_not_printed() {
        for bytes in [
            b"{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"message\":\"secret\\u001b[31m\"}}\n"
                .as_slice(),
            b"{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}",
        ] {
            let result = reply(bytes, tokio::time::Instant::now() + Duration::from_secs(1)).await;
            assert!(matches!(
                result,
                Err("phone_request_failed" | "phone_result_unknown")
            ));
        }
    }
}
