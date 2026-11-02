//! Native assistant context, durable jobs, and bounded public-answer streaming.
//!
//! The context, payload validation, prompt, event and proposal rules are pure and also build for the
//! phone's own assistant. Everything that runs a worker process is desktop only.
macro_rules! desktop {
    ($($item:item)*) => { $(#[cfg(all(feature = "agent", unix, not(target_os = "ios")))] $item)* };
}
pub mod context;
pub mod events;
pub mod payload;
pub mod prompt;
pub mod proposals;
desktop! {
    mod codex;
    mod config;
    mod history;
    pub mod jobs;
    mod launch;
    pub mod mcp;
    pub mod opencode;
    mod provider;
    mod provider_stream;
    mod storage;
    mod stream;
    pub mod worker;
    pub mod overview;
    mod vision;
}
#[cfg(all(target_os = "macos", feature = "agent"))]
mod control;
