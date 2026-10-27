use std::path::{Path, PathBuf};

use anyhow::{Context as _, Result};
use serde::{Deserialize, Serialize};

use crate::credentials;

/// What a sign-in leaves on the phone. The password is never among it: the access token the
/// server handed over stands in for it until the listener signs out. No `Debug`, so the token
/// never lands in a log line by accident.
#[derive(Clone, Serialize, Deserialize)]
pub struct Credentials {
    pub server: String,
    pub user_id: String,
    pub username: String,
    pub device_id: String,
    pub token: String,
}

fn folder() -> PathBuf {
    credentials::dir("jellyfin")
}

fn path() -> PathBuf {
    folder().join(credentials::FILE)
}

/// Adds `https://` to an address with no scheme and drops the trailing slash. A base path stays,
/// since a server can live under one, as the demo does under `/stable`.
pub fn normalize_server(raw: &str) -> Result<String> {
    let trimmed = raw.trim().trim_end_matches('/');
    if trimmed.is_empty() {
        anyhow::bail!("the server address is empty");
    }
    Ok(match trimmed.contains("://") {
        true => trimmed.to_owned(),
        false => format!("https://{trimmed}"),
    })
}

/// The `Authorization` header every request carries: which app and device is asking, and once
/// signed in, the token. It is a credential once it holds the token, so it is never logged.
pub fn authorization(device_id: &str, token: Option<&str>) -> String {
    let mut header = format!(
        r#"MediaBrowser Client="Cauce", Device="{}", DeviceId="{device_id}", Version="{}""#,
        std::env::consts::OS,
        env!("CARGO_PKG_VERSION"),
    );
    if let Some(token) = token {
        header.push_str(&format!(r#", Token="{token}""#));
    }
    header
}

/// This install's device id, made once and kept beside the credentials. Signing out keeps it, so
/// the server sees one device however often the listener signs in again.
pub fn device_id() -> String {
    device_id_at(&folder().join("device"), credentials::write)
}

pub(crate) fn device_id_at(path: &Path, write: impl FnOnce(&Path, &[u8]) -> Result<()>) -> String {
    if let Ok(kept) = std::fs::read_to_string(path)
        && kept.trim().len() == 32
    {
        return kept.trim().to_owned();
    }
    let made: String = std::iter::repeat_with(|| fastrand::digit(16))
        .take(32)
        .collect();
    if let Err(error) = write(path, made.as_bytes()) {
        log::warn!("jellyfin: cannot keep the device id: {error:#}");
    }
    made
}

pub(crate) fn read(path: &Path) -> Option<Credentials> {
    let bytes = std::fs::read(path).ok()?;
    let mut credentials: Credentials = serde_json::from_slice(&bytes).ok()?;
    credentials.server = normalize_server(&credentials.server).ok()?;
    (!credentials.token.is_empty() && !credentials.user_id.is_empty()).then_some(credentials)
}

pub fn load() -> Option<Credentials> {
    read(&path())
}

pub fn store(stored: &Credentials) -> Result<()> {
    let bytes =
        serde_json::to_vec_pretty(stored).context("cannot serialize jellyfin credentials")?;
    credentials::write(&path(), &bytes).context("cannot store jellyfin credentials")
}

pub fn forget() {
    credentials::remove(&path());
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_server_without_a_scheme_gets_https_and_keeps_its_base_path() {
        assert_eq!(
            normalize_server(" demo.jellyfin.org/stable/ ").unwrap(),
            "https://demo.jellyfin.org/stable"
        );
        assert_eq!(
            normalize_server("http://192.168.1.4:8096/").unwrap(),
            "http://192.168.1.4:8096"
        );
        assert!(normalize_server("  ").is_err());
    }

    #[test]
    fn the_authorization_names_the_app_and_device_and_adds_the_token_once_signed_in() {
        let before = authorization("dev-1", None);
        assert!(before.starts_with(r#"MediaBrowser Client="Cauce", Device=""#));
        assert!(before.contains(r#", DeviceId="dev-1", Version=""#));
        assert!(!before.contains("Token="));
        let after = authorization("dev-1", Some("abc"));
        assert_eq!(after, format!(r#"{before}, Token="abc""#));
    }

    #[test]
    fn nothing_stored_reads_as_no_credentials() {
        let folder = tempfile::tempdir().unwrap();
        assert!(read(&folder.path().join(credentials::FILE)).is_none());
    }

    #[test]
    fn a_device_id_is_made_once_and_kept() {
        let folder = tempfile::tempdir().unwrap();
        let path = folder.path().join("device");
        let first = device_id_at(&path, |path, bytes| Ok(std::fs::write(path, bytes)?));
        let again = device_id_at(&path, |_, _| anyhow::bail!("must not write again"));
        assert_eq!(first.len(), 32);
        assert_eq!(first, again);
    }
}
