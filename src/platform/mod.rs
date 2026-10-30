//! Operating-system boundaries shared by backend features.
pub mod dirs;
#[cfg(not(target_os = "ios"))]
pub(crate) mod ipc;
pub(crate) mod private_fs;
#[cfg(test)]
mod tests;

#[cfg(windows)]
mod windows_security;
#[cfg(all(test, windows))]
mod windows_tests;

pub(crate) fn http_client() -> reqwest::ClientBuilder {
    let builder = reqwest::Client::builder();
    #[cfg(not(target_os = "ios"))]
    let builder = builder.hickory_dns(true);
    builder
}
