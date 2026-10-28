use super::Inner;
use serde_json::Value;
use std::{path::Path, sync::Arc};
pub(super) fn listen(_: &Arc<Inner>) -> Result<(), &'static str> {
    Ok(())
}
pub(super) async fn request(_: &Path, _: &str, _: &Value) -> Result<Value, &'static str> {
    Err("outbox_owner_unavailable")
}
