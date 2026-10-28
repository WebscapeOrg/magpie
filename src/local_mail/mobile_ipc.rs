use super::Store;
use serde_json::Value;
use std::sync::Arc;
pub(super) fn listen(_: &Arc<Store>, _: &str) -> Result<(), &'static str> {
    Ok(())
}
pub(super) async fn request(_: &str, _: &str, _: &Value) -> Result<Value, &'static str> {
    Err("local_owner_unavailable")
}
