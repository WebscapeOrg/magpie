pub mod account;
// Invariant: Detached assistant workers currently rely on Linux pidfds and private storage.
#[cfg(all(feature = "agent", unix, not(target_os = "ios")))]
pub mod agent;
pub mod attachment;
pub mod auth;
pub mod backend;
pub mod cache;
#[cfg(not(target_os = "ios"))]
pub mod cli;
pub mod compose;
pub mod contacts;
pub mod credentials;
pub mod inbox;
pub mod local_mail;
pub mod mail;
pub mod message;
pub mod outbox;
pub mod platform;
#[cfg(not(target_os = "ios"))]
pub mod process;
pub mod providers;
pub mod public_http;
pub(crate) mod raster;
pub mod sync;
pub mod tls;
