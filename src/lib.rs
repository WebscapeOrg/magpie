pub mod account;
// Invariant: Detached assistant workers rely on Linux pidfds and private storage, so agent/mod.rs builds them only for the desktop; the phone gets the pure context and safety rules.
#[cfg(any(all(feature = "agent", unix, not(target_os = "ios")), feature = "mobile"))]
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
