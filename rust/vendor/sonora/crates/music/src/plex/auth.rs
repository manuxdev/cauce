use std::path::{Path, PathBuf};

use anyhow::{Context as _, Result};
use serde::{Deserialize, Serialize};

use crate::credentials;

pub const SLUG: &str = "plex";

/// What a sign-in leaves on the phone: the server picked, every address it answers on, best
/// first, and the server's own token. The plex.tv account token is not among it: it only lists
/// the servers, and is dropped once one is picked. No `Debug`, so the token never lands in a log
/// line by accident.
#[derive(Clone, Serialize, Deserialize)]
pub struct Credentials {
    /// The address that answered last, with no trailing slash.
    pub server: String,
    pub addresses: Vec<String>,
    pub server_id: String,
    pub server_name: String,
    pub user_id: String,
    pub username: String,
    /// This install, as plex.tv and the server know it.
    pub client_id: String,
    pub token: String,
}

fn folder() -> PathBuf {
    credentials::dir(SLUG)
}

fn path() -> PathBuf {
    folder().join(credentials::FILE)
}

/// This install's client identifier, made once and kept beside the credentials, so plex.tv lists
/// one device however often the listener signs in again.
pub fn client_id() -> String {
    crate::jellyfin::auth::device_id_at(&folder().join("device"), credentials::write)
}

pub(crate) fn read(path: &Path) -> Option<Credentials> {
    let bytes = std::fs::read(path).ok()?;
    let credentials: Credentials = serde_json::from_slice(&bytes).ok()?;
    let usable = !credentials.token.is_empty()
        && !credentials.server_id.is_empty()
        && credentials.server.contains("://");
    usable.then_some(credentials)
}

pub fn load() -> Option<Credentials> {
    read(&path())
}

pub fn store(stored: &Credentials) -> Result<()> {
    let bytes = serde_json::to_vec_pretty(stored).context("cannot serialize plex credentials")?;
    credentials::write(&path(), &bytes).context("cannot store plex credentials")
}

pub fn forget() {
    credentials::remove(&path());
}

#[cfg(test)]
mod tests {
    use super::*;

    fn stored(server: &str, token: &str) -> Credentials {
        Credentials {
            server: server.into(),
            addresses: vec![server.into()],
            server_id: "abc".into(),
            server_name: "Den".into(),
            user_id: "99".into(),
            username: "listener".into(),
            client_id: "c".into(),
            token: token.into(),
        }
    }

    #[test]
    fn a_stored_sign_in_reads_back_and_a_broken_one_does_not() {
        let folder = tempfile::tempdir().unwrap();
        let file = folder.path().join(credentials::FILE);
        assert!(read(&file).is_none());
        std::fs::write(
            &file,
            serde_json::to_vec(&stored("http://h:32400", "t")).unwrap(),
        )
        .unwrap();
        let back = read(&file).unwrap();
        assert_eq!(
            (back.server.as_str(), back.server_name.as_str()),
            ("http://h:32400", "Den")
        );
        std::fs::write(
            &file,
            serde_json::to_vec(&stored("http://h:32400", "")).unwrap(),
        )
        .unwrap();
        assert!(read(&file).is_none());
        std::fs::write(&file, serde_json::to_vec(&stored("", "t")).unwrap()).unwrap();
        assert!(read(&file).is_none());
    }
}
