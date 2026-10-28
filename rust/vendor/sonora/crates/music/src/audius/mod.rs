//! Audius, an open catalog of independent music, read through its public API with no account.
//!
//! Connecting stores nothing secret: a marker that Audius is on, and the likes made here. Tracks
//! only stream, since the API terms allow caching for the session alone, and a track gated
//! behind a purchase or a follow is listed as unavailable rather than fetched some other way.

mod client;
mod likes;
mod playback;
mod wire;

use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use anyhow::{Context as _, Result};
use async_trait::async_trait;

pub use client::AudiusClient;

use crate::audius::playback::Factory;
use crate::{Capabilities, MusicProvider, ProviderSession, Shape, SignIn, UserProfile};

/// The name the provider goes by. It is saved in settings, so it must not change.
pub const NAME: &str = "Audius";
pub const SLUG: &str = "audius";

/// Likes are kept on the phone, so following is too. No stations, no conversion, and nothing
/// kept or downloaded, as the API terms allow only caching for the session.
const CAPABILITIES: Capabilities = Capabilities {
    follow_artists: true,
    playcounts: true,
    ..Capabilities::NONE
};

/// The file that says Audius is connected.
const MARKER: &str = "connected";

/// The host to read from, as `GET https://api.audius.co` lists them, or the default host when
/// that cannot be asked.
pub(crate) async fn select_host() -> String {
    let asked = async {
        let http = reqwest::Client::builder()
            .user_agent(crate::radio::AGENT)
            .timeout(Duration::from_secs(5))
            .build()?;
        let hosts: Vec<String> = http
            .get(wire::DEFAULT_HOST)
            .send()
            .await?
            .error_for_status()?
            .json::<serde_json::Value>()
            .await?
            .get("data")
            .and_then(|hosts| serde_json::from_value(hosts.clone()).ok())
            .unwrap_or_default();
        anyhow::Ok(hosts)
    };
    match asked.await {
        Ok(hosts) => wire::pick_host(&hosts, fastrand::usize(..)),
        Err(error) => {
            log::warn!("audius: cannot list hosts, using the default: {error:#}");
            wire::DEFAULT_HOST.to_owned()
        }
    }
}

pub struct AudiusProvider {
    /// Where the marker and the likes are kept: data the listener made, not a cache.
    folder: PathBuf,
}

impl AudiusProvider {
    pub fn new(folder: PathBuf) -> Self {
        Self { folder }
    }

    async fn session(&self) -> ProviderSession {
        let client = AudiusClient::new(select_host().await, self.folder.clone());
        ProviderSession {
            profile: UserProfile {
                id: SLUG.to_owned(),
                display_name: NAME.to_owned(),
                avatar: None,
            },
            api: Arc::new(client.clone()),
            playback: Arc::new(Factory::new(client)),
            shape: Shape::Saved,
            authenticated: false,
            capabilities: CAPABILITIES,
        }
    }
}

#[async_trait]
impl MusicProvider for AudiusProvider {
    fn name(&self) -> &'static str {
        NAME
    }

    fn slug(&self) -> &'static str {
        SLUG
    }

    /// There is nothing to sign in with: connecting takes no credentials.
    fn sign_in_options(&self) -> Vec<SignIn> {
        Vec::new()
    }

    fn stored(&self) -> bool {
        self.folder.join(MARKER).exists()
    }

    fn reach(&self) -> Option<String> {
        Some("api.audius.co".to_owned())
    }

    /// Audius artwork is public.
    fn public_art(&self) -> bool {
        true
    }

    async fn restore(&self) -> Result<Option<ProviderSession>> {
        if !self.stored() {
            return Ok(None);
        }
        Ok(Some(self.session().await))
    }

    /// Connects whatever `method` holds, since Audius asks for no account.
    async fn sign_in(&self, _method: SignIn) -> Result<ProviderSession> {
        std::fs::create_dir_all(&self.folder).context("cannot create the audius folder")?;
        std::fs::write(self.folder.join(MARKER), b"").context("cannot connect audius")?;
        Ok(self.session().await)
    }

    /// Turns Audius off. The likes stay, for when it is connected again.
    fn sign_out(&self) {
        if let Err(error) = std::fs::remove_file(self.folder.join(MARKER))
            && error.kind() != std::io::ErrorKind::NotFound
        {
            log::warn!("audius: cannot disconnect: {error}");
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn connecting_needs_no_account_and_disconnecting_keeps_the_likes() {
        let folder = tempfile::tempdir().unwrap();
        let provider = AudiusProvider::new(folder.path().join("audius"));
        assert!(!provider.stored());
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();
        assert!(runtime.block_on(provider.restore()).unwrap().is_none());
        std::fs::create_dir_all(folder.path().join("audius")).unwrap();
        std::fs::write(folder.path().join("audius/likes.json"), b"{}").unwrap();
        std::fs::write(folder.path().join("audius").join(MARKER), b"").unwrap();
        assert!(provider.stored());
        provider.sign_out();
        assert!(!provider.stored());
        assert!(folder.path().join("audius/likes.json").exists());
    }

    #[test]
    fn nothing_is_kept_or_downloaded() {
        assert!(!CAPABILITIES.keeps);
        assert!(!CAPABILITIES.downloads);
        assert!(!CAPABILITIES.radio);
    }
}
