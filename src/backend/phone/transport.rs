use super::{Engine, storage};
use http_body_util::{BodyExt, Full, Limited};
use hyper::{
    Request, Response,
    body::{Bytes, Incoming},
    server::conn::http1,
    service::service_fn,
};
use hyper_util::rt::{TokioIo, TokioTimer};
use serde_json::{Value, json};
use std::{convert::Infallible, io, sync::Arc, time::Duration};
use tokio::sync::watch;
fn answer(status: u16, value: Value) -> Response<Full<Bytes>> {
    Response::builder()
        .status(status)
        .header("content-type", "application/json")
        .header("cache-control", "no-store")
        .body(Full::new(Bytes::from(value.to_string())))
        .unwrap()
}
async fn request(
    engine: Arc<Engine>,
    host: Arc<String>,
    request: Request<Incoming>,
) -> Result<Response<Full<Bytes>>, Infallible> {
    if request.method() != hyper::Method::POST
        || request.uri().query().is_some()
        || request.headers().contains_key("origin")
        || request.headers().get("host").and_then(|v| v.to_str().ok()) != Some(host.as_str())
        || request
            .headers()
            .get("content-type")
            .and_then(|v| v.to_str().ok())
            != Some("application/json")
    {
        return Ok(answer(400, json!({"error":"phone_invalid_request"})));
    }
    let path = request.uri().path().to_owned();
    let token = request
        .headers()
        .get("authorization")
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.strip_prefix("Bearer "))
        .unwrap_or("")
        .to_owned();
    if path != "/v1/pair" && engine.phone.paired(&token).is_err() {
        return Ok(answer(401, json!({"error":"phone_unauthorized"})));
    }
    let body = tokio::time::timeout(
        Duration::from_secs(10),
        Limited::new(request.into_body(), 2 * 1024 * 1024).collect(),
    )
    .await;
    let Ok(Ok(body)) = body else {
        return Ok(answer(413, json!({"error":"phone_request_refused"})));
    };
    let Ok(params) = serde_json::from_slice::<Value>(&body.to_bytes()) else {
        return Ok(answer(400, json!({"error":"phone_invalid_request"})));
    };
    let result = super::Service::enqueue(engine, path, token, params).await;
    Ok(match result {
        Ok(value) => answer(200, json!({"result":value})),
        Err("phone_unauthorized") => answer(401, json!({"error":"phone_unauthorized"})),
        Err(error) => answer(200, json!({"error":error})),
    })
}
pub async fn serve(engine: Arc<Engine>, mut stop: watch::Receiver<bool>) -> io::Result<()> {
    let config = storage::read("server.json").map_err(io::Error::other)?;
    let Some(address) = config["listen"].as_str() else {
        return Ok(());
    };
    let address: std::net::SocketAddr = address.parse().map_err(io::Error::other)?;
    let std::net::IpAddr::V4(ip) = address.ip() else {
        return Err(io::Error::other("phone_listen_refused"));
    };
    if !(ip.octets()[0] == 100 && (64..128).contains(&ip.octets()[1])) {
        return Err(io::Error::other("phone_listen_refused"));
    }
    let host = Arc::new(
        config["host"]
            .as_str()
            .filter(|s| s.ends_with(".ts.net:3450"))
            .ok_or_else(|| io::Error::other("phone_host_invalid"))?
            .to_owned(),
    );
    let cert = storage::bytes("server.crt", 64 * 1024)
        .map_err(io::Error::other)?
        .ok_or_else(|| io::Error::other("phone_certificate_missing"))?;
    let key = storage::bytes("server.key", 64 * 1024)
        .map_err(io::Error::other)?
        .ok_or_else(|| io::Error::other("phone_key_missing"))?;
    let certificates =
        rustls_pemfile::certs(&mut cert.as_slice()).collect::<Result<Vec<_>, _>>()?;
    let key = rustls_pemfile::private_key(&mut key.as_slice())?
        .ok_or_else(|| io::Error::other("phone_key_invalid"))?;
    let config = rustls::ServerConfig::builder_with_provider(Arc::new(
        rustls::crypto::ring::default_provider(),
    ))
    .with_safe_default_protocol_versions()
    .map_err(io::Error::other)?
    .with_no_client_auth()
    .with_single_cert(certificates, key)
    .map_err(io::Error::other)?;
    let acceptor = tokio_rustls::TlsAcceptor::from(Arc::new(config));
    let listener = tokio::net::TcpListener::bind(address).await?;
    engine
        .phone
        .active
        .store(true, std::sync::atomic::Ordering::Release);
    let mut connections = tokio::task::JoinSet::new();
    let mut failure = None;
    loop {
        tokio::select! {
            _=stop.changed()=>break,
            _=connections.join_next(),if !connections.is_empty()=>(),
            socket=listener.accept(),if connections.len()<8=>{
                let (socket,_)=match socket { Ok(socket)=>socket,Err(error)=>{failure=Some(error);break;} }; let tls=acceptor.clone();let engine=engine.clone();let host=host.clone();let mut stopped=stop.clone();
                connections.spawn_local(async move {
                    let Ok(Ok(socket))=tokio::time::timeout(Duration::from_secs(5),tls.accept(socket)).await else { return; };
                    let mut builder=http1::Builder::new();builder.keep_alive(false).max_headers(32).max_buf_size(16*1024).timer(TokioTimer::new()).header_read_timeout(Duration::from_secs(10));
                    let connection=builder.serve_connection(TokioIo::new(socket),service_fn(move |req|request(engine.clone(),host.clone(),req)));
                    tokio::pin!(connection);
                    tokio::select! {
                        _=&mut connection=>(),
                        _=tokio::time::sleep(Duration::from_secs(90))=>(),
                        _=stopped.changed()=>{ connection.as_mut().graceful_shutdown(); let _=tokio::time::timeout(Duration::from_secs(30),connection).await; }
                    }
                });
            }
        }
    }
    engine
        .phone
        .active
        .store(false, std::sync::atomic::Ordering::Release);
    while connections.join_next().await.is_some() {}
    engine.phone.drain().await;
    match failure {
        Some(error) => Err(error),
        None => Ok(()),
    }
}
