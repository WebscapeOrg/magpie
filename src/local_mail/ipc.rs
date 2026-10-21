use super::{Store, execute, sync};
use crate::platform::{
    dirs::AppDirs,
    ipc::{LocalEndpoint, authenticate},
    private_fs,
};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{sync::Arc, time::Duration};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};

const INPUT: usize = 1024 * 1024;
const OUTPUT: usize = 128 * 1024 * 1024 + 4096;
const TIMEOUT: Duration = Duration::from_secs(20);
type Result<T> = std::result::Result<T, &'static str>;

pub(super) fn listen(store: &Arc<Store>, account: &str) -> Result<()> {
    let mut task = store
        .listener
        .lock()
        .map_err(|_| "local_storage_unavailable")?;
    if task.as_ref().is_some_and(|task| !task.is_finished()) {
        return Ok(());
    }
    let endpoint = LocalEndpoint::directory(
        store
            .directory()
            .try_clone()
            .map_err(|_| "local_storage_unavailable")?,
    )?;
    let listener = endpoint.listen()?;
    let weak = Arc::downgrade(store);
    let account = account.to_owned();
    *task = Some(tokio::spawn(async move {
        let mut requests = tokio::task::JoinSet::new();
        loop {
            tokio::select! {
                connection=listener.accept(), if requests.len()<2 => {
                    let Ok((mut stream,_))=connection else {break};
                    let Some(store)=weak.upgrade() else {break};
                    let account=account.clone();
                    requests.spawn(async move {
                        let _=tokio::time::timeout(TIMEOUT,async {
                            authenticate(&mut stream).await?;
                            let request=read(&mut stream,INPUT).await?;
                            let answer=serve(&store,&account,request).await;
                            let answer=match answer {Ok(value)=>json!({"result":value}),Err(error)=>json!({"error":error})};
                            write(&mut stream,&answer,OUTPUT).await
                        }).await;
                    });
                }
                _=requests.join_next(), if !requests.is_empty()=>(),
            }
        }
    }));
    Ok(())
}

async fn serve(store: &Arc<Store>, account: &str, request: Value) -> Result<Value> {
    if request["params"]["accountId"] != account {
        return Err("local_account_unknown");
    }
    let method = request["method"]
        .as_str()
        .ok_or("invalid_params")?
        .to_owned();
    if !matches!(
        method.as_str(),
        "local.list"
            | "local.status"
            | "local.edits"
            | "local.pause"
            | "local.edit"
            | "local.cancelEdit"
            | "local.resource"
            | "local.revision"
            | "local.overview"
            | "local.labelCounts"
            | "local.dismissConflict"
    ) {
        return Err("unknown_method");
    }
    let params = request["params"].clone();
    sync::disk(store, move |s| execute(s, &method, &params)).await
}

pub(super) async fn request(account: &str, method: &str, params: &Value) -> Result<Value> {
    let dirs = AppDirs::discover()?;
    let hash = format!("{:x}", Sha256::digest(account.as_bytes()));
    let directory = private_fs::directories_readonly(&dirs.state, &["omamail", "mail", &hash])?
        .ok_or("local_owner_unavailable")?;
    let endpoint = LocalEndpoint::directory(directory)?;
    exchange(&endpoint, method, params).await
}

async fn exchange(endpoint: &LocalEndpoint, method: &str, params: &Value) -> Result<Value> {
    tokio::time::timeout(TIMEOUT, async {
        let mut stream = endpoint.connect().await?;
        write(
            &mut stream,
            &json!({"method":method,"params":params}),
            INPUT,
        )
        .await?;
        let response = read(&mut stream, OUTPUT).await?;
        if let Some(error) = response["error"].as_str() {
            return Err(match error {
                "invalid_params" => "invalid_params",
                "local_search_unsupported" => "local_search_unsupported",
                "local_edit_already_started" => "local_edit_already_started",
                "local_edit_id_conflict" => "local_edit_id_conflict",
                "local_message_unavailable" => "local_message_unavailable",
                "local_storage_corrupt" => "local_storage_corrupt",
                "local_content_invalid" => "local_content_invalid",
                "local_content_missing" => "local_content_missing",
                _ => "local_storage_unavailable",
            });
        }
        response
            .get("result")
            .cloned()
            .ok_or("local_owner_unavailable")
    })
    .await
    .unwrap_or(Err("local_owner_unavailable"))
}

async fn read<S: AsyncRead + Unpin>(stream: &mut S, limit: usize) -> Result<Value> {
    let length = stream
        .read_u32()
        .await
        .map_err(|_| "local_owner_unavailable")? as usize;
    if length > limit {
        return Err("invalid_params");
    }
    let mut bytes = vec![0; length];
    stream
        .read_exact(&mut bytes)
        .await
        .map_err(|_| "local_owner_unavailable")?;
    serde_json::from_slice(&bytes).map_err(|_| "invalid_params")
}
async fn write<S: AsyncWrite + Unpin>(stream: &mut S, value: &Value, limit: usize) -> Result<()> {
    let bytes = serde_json::to_vec(value).map_err(|_| "invalid_params")?;
    if bytes.len() > limit {
        return Err("invalid_params");
    }
    stream
        .write_u32(bytes.len() as u32)
        .await
        .map_err(|_| "local_owner_unavailable")?;
    stream
        .write_all(&bytes)
        .await
        .map_err(|_| "local_owner_unavailable")
}

#[cfg(test)]
mod tests {
    use super::*;
    #[tokio::test]
    async fn dispatcher_rejects_foreign_accounts_and_unknown_parameters_without_writes() {
        let path = super::super::tests::directory();
        let store = Store::open(std::fs::File::open(&path).unwrap()).unwrap();
        let params = json!({"accountId":"other@example.org","ticket":"bad","ids":["one"],
            "addLabelIds":["STARRED"],"removeLabelIds":[]});
        assert_eq!(
            serve(
                &store,
                "owner@example.org",
                json!({"method":"local.edit","params":params})
            )
            .await,
            Err("local_account_unknown")
        );
        assert_eq!(store.status().unwrap()["pendingEdits"], 0);
        let mut params = params;
        params["accountId"] = json!("owner@example.org");
        params["path"] = json!("/tmp/forbidden");
        assert_eq!(
            serve(
                &store,
                "owner@example.org",
                json!({"method":"local.edit","params":params})
            )
            .await,
            Err("invalid_params")
        );
        assert_eq!(store.status().unwrap()["pendingEdits"], 0);
        drop(store);
        std::fs::remove_dir_all(path).unwrap();
    }
    #[tokio::test]
    async fn owner_serves_authenticated_reads_and_refuses_another_account() {
        let path = super::super::tests::directory();
        let store = Store::open(std::fs::File::open(&path).unwrap()).unwrap();
        listen(&store, "owner@example.org").unwrap();
        let endpoint = LocalEndpoint::directory(std::fs::File::open(&path).unwrap()).unwrap();
        assert_eq!(
            exchange(
                &endpoint,
                "local.status",
                &json!({"accountId":"owner@example.org"})
            )
            .await
            .unwrap()["stored"],
            0
        );
        assert!(exchange(&endpoint,"local.edit",&json!({"accountId":"other@example.org","ticket":"bad","ids":["one"],"addLabelIds":["STARRED"],"removeLabelIds":[]})).await.is_err());
        assert_eq!(store.status().unwrap()["pendingEdits"], 0);
        drop(store);
        std::fs::remove_dir_all(path).unwrap();
    }
}
