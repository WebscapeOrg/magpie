use super::{Engine, protocol, rpc};
use crate::platform::{
    dirs::AppDirs,
    ipc::{LocalEndpoint, authenticate},
    private_fs,
};
use serde_json::{Value, json};
use std::{io, sync::Arc, time::Duration};
use tokio::{
    io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader},
    sync::mpsc,
};

fn directory() -> Result<std::fs::File, &'static str> {
    private_fs::directories(&AppDirs::discover()?.runtime, &["omamail", "engine"], true)?
        .ok_or("engine_storage_unavailable")
}

pub fn enabled() -> Result<bool, &'static str> {
    let check = || {
        let dirs = match AppDirs::discover() {
            Ok(dirs) => dirs,
            Err("home_missing") => return Ok(false),
            Err(error) => return Err(error),
        };
        let Some(dir) = private_fs::directories_readonly(&dirs.state, &["omamail"])? else {
            return Ok(false);
        };
        Ok::<_, &'static str>(private_fs::regular_readonly(&dir, "engine-enabled")?.is_some())
    };
    check()
}

pub fn proxy() -> io::Result<()> {
    let runtime = super::runtime()?;
    let result = runtime.block_on(async {
        let endpoint = LocalEndpoint::directory(directory().map_err(io::Error::other)?)
            .map_err(io::Error::other)?;
        let stream = endpoint.connect().await.map_err(io::Error::other)?;
        let (mut reader, mut writer) = stream.into_split();
        let mut input = tokio::io::stdin();
        let mut output = tokio::io::stdout();
        let sending = async {
            tokio::io::copy(&mut input, &mut writer).await?;
            writer.shutdown().await?;
            Ok::<_, io::Error>(())
        };
        let receiving = async {
            tokio::io::copy(&mut reader, &mut output).await?;
            output.flush().await?;
            Ok::<_, io::Error>(())
        };
        tokio::pin!(sending, receiving);
        tokio::select! {
            result = &mut sending => { result?; receiving.await },
            result = &mut receiving => result,
        }
    });
    runtime.shutdown_background();
    result
}

pub fn serve() -> io::Result<()> {
    let runtime = super::runtime()?;
    runtime.block_on(tokio::task::LocalSet::new().run_until(async {
        let directory = directory().map_err(io::Error::other)?;
        let _lease = private_fs::lock_exclusive(&directory, ".engine.lock").map_err(io::Error::other)?;
        let endpoint = LocalEndpoint::directory(directory).map_err(io::Error::other)?;
        let listener = endpoint.listen().map_err(io::Error::other)?;
        let engine = Arc::new(Engine::default());
        let (stop, mut maintenance_stop) = tokio::sync::watch::channel(false);
        let phone_engine=engine.clone();let phone_stop=stop.subscribe();
        let mut phone_servers=tokio::task::JoinSet::new();
        phone_servers.spawn_local(super::phone::serve(phone_engine,phone_stop));
        let mut service_error=None;
        let maintenance = engine.clone();
        let scheduler = tokio::task::spawn_local(async move {
            let mut tick = tokio::time::interval(Duration::from_secs(30));
            loop {
                tokio::select! { _ = tick.tick() => (), _ = maintenance_stop.changed() => break }
                if *maintenance_stop.borrow() { break; }
                if let Ok(accounts) = maintenance.dispatch("accounts.list", &json!({})).await {
                    for account in accounts["accounts"].as_array().into_iter().flatten() {
                        if account["id"].as_str().is_none_or(str::is_empty) { continue; }
                        let params = json!({"accountId":account["id"]});
                        let _ = maintenance.dispatch("local.watch", &params).await;
                        let _ = maintenance.dispatch("outbox.snapshot", &params).await;
                    }
                }
                let _ = maintenance.dispatch("inbox.tick", &json!({})).await;
            }
        });
        let notifications=engine.clone(); let mut notification_stop=stop.subscribe();
        let notifier=tokio::task::spawn_local(async move {
            let mut tick=tokio::time::interval(Duration::from_secs(30));
            loop {
                tokio::select! { _=tick.tick()=>(), _=notification_stop.changed()=>break }
                if *notification_stop.borrow() { break; }
                let _=notifications.phone.notify(&notifications).await;
            }
        });
        let mut clients = tokio::task::JoinSet::new();
        let mut terminate = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())?;
        loop {
            tokio::select! {
                _ = terminate.recv() => break,
                _ = tokio::signal::ctrl_c() => break,
                connection = listener.accept(), if clients.len() < 16 => {
                    let (stream, _) = match connection { Ok(value)=>value,Err(error)=>{service_error=Some(error);break;} };
                    clients.spawn_local(connection_task(stream, Arc::new(engine.frontend()), stop.subscribe()));
                },
                _ = clients.join_next(), if !clients.is_empty() => (),
                result = phone_servers.join_next(), if !phone_servers.is_empty() => { if let Some(result)=result { service_error=result.map_err(io::Error::other).and_then(|v|v).err(); if service_error.is_some() { break; } } },
            }
        }
        let _ = stop.send(true);
        let _ = scheduler.await;
        let _ = notifier.await;
        while let Some(result)=phone_servers.join_next().await { if let Err(error)=result.map_err(io::Error::other).and_then(|v|v) { service_error=Some(error); } }
        engine.phone.active.store(false, std::sync::atomic::Ordering::Release);
        engine.phone.drain().await;
        while clients.join_next().await.is_some() {}
        engine.shutdown().await.map_err(io::Error::other)?;
        match service_error { Some(error)=>Err(error),None=>Ok(()) }
    }))
}

async fn connection_task(
    mut stream: tokio::net::UnixStream,
    engine: Arc<Engine>,
    mut stop: tokio::sync::watch::Receiver<bool>,
) -> io::Result<()> {
    tokio::time::timeout(Duration::from_secs(5), authenticate(&mut stream))
        .await
        .map_err(io::Error::other)?
        .map_err(io::Error::other)?;
    let (reader, mut writer) = stream.into_split();
    let mut input = BufReader::new(reader);
    let (sender, mut responses) = mpsc::channel::<Value>(8);
    let mut output = tokio::spawn(async move {
        while let Some(value) = responses.recv().await {
            let mut bytes = Vec::new();
            protocol::reply(&mut bytes, value)?;
            tokio::time::timeout(Duration::from_secs(25), writer.write_all(&bytes))
                .await
                .map_err(io::Error::other)??;
        }
        writer.shutdown().await
    });
    let mut watchers = tokio::task::JoinSet::new();
    for mut events in engine.notifications() {
        let sender = sender.clone();
        watchers.spawn(async move {
            loop {
                match events.recv().await {
                    Ok(event) => {
                        if sender.send(event).await.is_err() {
                            break;
                        }
                    }
                    Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => (),
                    Err(_) => break,
                }
            }
        });
    }
    let mut mail_events = engine.mail.subscribe();
    let mail_engine = engine.clone();
    let mail_sender = sender.clone();
    watchers.spawn(async move {
        while let Ok(event) = mail_events.recv().await {
            if mail_engine.mail.is_current(&event) && mail_sender.send(event.value).await.is_err() {
                break;
            }
        }
    });
    let mut jobs = tokio::task::JoinSet::new();
    let mut output_result = None;
    let read_result = async {
        loop {
            let mut frame = Vec::new();
            if *stop.borrow() {
                break;
            }
            let mut bounded = (&mut input).take((protocol::MAX_FRAME + 1) as u64);
            let count = tokio::select! {
                result = bounded.read_until(b'\n', &mut frame) => result?,
                _ = stop.changed() => break,
                result = &mut output => { output_result=Some(result); break; },
            };
            if count == 0 {
                break;
            }
            if count > protocol::MAX_FRAME || frame.last() != Some(&b'\n') {
                let (code, message) = if count > protocol::MAX_FRAME {
                    (-32001, "Frame too large")
                } else {
                    (-32700, "Truncated frame")
                };
                while jobs.join_next().await.is_some() {}
                let _ = sender.send(rpc::error(Value::Null, code, message)).await;
                break;
            }
            let quit = rpc::requests_quit(&frame);
            if quit {
                while jobs.join_next().await.is_some() {}
                let (answer, _) = rpc::handle(
                    &frame,
                    &engine,
                    tokio::time::Instant::now() + Duration::from_secs(25),
                )
                .await;
                if let Some(answer) = answer {
                    let _ = sender.send(answer).await;
                }
                break;
            }
            if jobs.len() >= 32 {
                let _ = jobs.join_next().await;
            }
            let engine = engine.clone();
            let responses = sender.clone();
            jobs.spawn_local(async move {
                let (answer, _) = rpc::handle(
                    &frame,
                    &engine,
                    tokio::time::Instant::now() + Duration::from_secs(25),
                )
                .await;
                if let Some(answer) = answer {
                    let _ = responses.send(answer).await;
                }
            });
        }
        Ok::<_, io::Error>(())
    }
    .await;
    while jobs.join_next().await.is_some() {}
    engine.auth.shutdown().await;
    engine.mail.shutdown().await;
    watchers.abort_all();
    while watchers.join_next().await.is_some() {}
    drop(sender);
    match output_result {
        Some(result) => result,
        None => output.await,
    }
    .map_err(io::Error::other)??;
    read_result
}

pub(crate) async fn export_backup() -> Result<Value, &'static str> {
    if !enabled()? {
        return Engine::default().local_mail.export_backup().await;
    }
    let deadline = tokio::time::Instant::now() + Duration::from_secs(10 * 60);
    let endpoint = LocalEndpoint::directory(directory()?)?;
    let mut stream = tokio::time::timeout(Duration::from_secs(5), endpoint.connect())
        .await
        .map_err(|_| "local_backup_owner_unavailable")??;
    tokio::time::timeout(
        Duration::from_secs(5),
        stream.write_all(
            b"{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"backup.export\",\"params\":{}}\n",
        ),
    )
    .await
    .map_err(|_| "local_backup_completion_unknown")?
    .map_err(|_| "local_backup_owner_unavailable")?;
    backup_reply(BufReader::new(stream), deadline).await
}

async fn backup_reply(
    mut input: impl tokio::io::AsyncBufRead + Unpin,
    deadline: tokio::time::Instant,
) -> Result<Value, &'static str> {
    loop {
        if tokio::time::Instant::now() >= deadline {
            return Err("local_backup_completion_unknown");
        }
        let mut frame = Vec::new();
        let count = tokio::time::timeout_at(
            deadline,
            (&mut input)
                .take((protocol::MAX_FRAME + 1) as u64)
                .read_until(b'\n', &mut frame),
        )
        .await
        .map_err(|_| "local_backup_completion_unknown")?
        .map_err(|_| "local_backup_owner_unavailable")?;
        if count == 0 || count > protocol::MAX_FRAME {
            return Err("local_backup_owner_unavailable");
        }
        let response: Value =
            serde_json::from_slice(&frame).map_err(|_| "local_backup_owner_unavailable")?;
        if response["id"] != 1 {
            continue;
        }
        if response["error"].is_object() {
            return Err(match response["error"]["message"].as_str() {
                Some("local_backup_completion_unknown") => "local_backup_completion_unknown",
                Some("local_backup_timed_out") => "local_backup_timed_out",
                Some("private_fs_busy" | "local_backup_busy") => "local_backup_busy",
                Some(
                    "local_content_invalid" | "local_content_missing" | "local_storage_corrupt",
                ) => "local_backup_incomplete",
                Some("Method not found") => "local_backup_backend_needs_update",
                _ => "local_backup_export_failed",
            });
        }
        return response
            .get("result")
            .filter(|result| result["complete"] == true)
            .cloned()
            .ok_or("local_backup_export_failed");
    }
}

#[cfg(test)]
mod backup_tests {
    use super::*;

    #[tokio::test]
    async fn ready_event_stream_cannot_bypass_the_backup_reply_deadline() {
        let frames = b"{\"method\":\"local.changed\"}\n{\"method\":\"local.changed\"}\n{\"id\":1,\"result\":{\"complete\":true}}\n";
        let expired = tokio::time::Instant::now() - Duration::from_secs(1);
        assert_eq!(
            backup_reply(&frames[..], expired).await,
            Err("local_backup_completion_unknown")
        );
        let current = tokio::time::Instant::now() + Duration::from_secs(1);
        assert_eq!(
            backup_reply(&frames[..], current).await.unwrap(),
            json!({"complete":true})
        );
    }
}
