use crate::platform::{dirs::AppDirs, private_fs};
use serde_json::Value;
use std::{fs::File, io::Read};
pub type Result<T> = std::result::Result<T, &'static str>;
pub fn directory() -> Result<File> {
    private_fs::directories(&AppDirs::discover()?.state, &["omamail", "phone"], true)?
        .ok_or("phone_storage_unavailable")
}
pub fn bytes(name: &str, limit: usize) -> Result<Option<Vec<u8>>> {
    let Some(file) = private_fs::regular_readonly(&directory()?, name)? else {
        return Ok(None);
    };
    let mut bytes = Vec::new();
    file.take(limit as u64 + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| "phone_storage_unavailable")?;
    if bytes.len() > limit {
        return Err("phone_storage_invalid");
    }
    Ok(Some(bytes))
}
pub fn read(name: &str) -> Result<Value> {
    read_bounded(name, 2 * 1024 * 1024)
}
pub fn read_bounded(name: &str, limit: usize) -> Result<Value> {
    bytes(name, limit)?
        .map(|bytes| serde_json::from_slice(&bytes).map_err(|_| "phone_storage_invalid"))
        .unwrap_or(Ok(serde_json::json!({})))
}
pub fn write(name: &str, value: &Value) -> Result<()> {
    write_bounded(name, value, 2 * 1024 * 1024)
}
pub fn write_bounded(name: &str, value: &Value, limit: usize) -> Result<()> {
    let bytes = serde_json::to_vec(value).map_err(|_| "phone_storage_invalid")?;
    if bytes.len() > limit {
        return Err("phone_storage_full");
    }
    let dir = directory()?;
    private_fs::atomic_replace(&dir, name, &bytes)?;
    private_fs::sync_dir(&dir)
}
pub fn random() -> Result<String> {
    let mut bytes = [0; 32];
    rustls::crypto::ring::default_provider()
        .secure_random
        .fill(&mut bytes)
        .map_err(|_| "phone_random_failed")?;
    use base64::Engine;
    Ok(base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(bytes))
}
pub fn hash(value: &[u8]) -> String {
    use sha2::{Digest, Sha256};
    format!("{:x}", Sha256::digest(value))
}
