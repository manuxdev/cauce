//! A Jellyfin server, part 1: sign-in, the library, search, playback and downloads. Likes,
//! playlist edits and server lyrics come in part 2, and until then their calls say so. Playback
//! is not reported to the server yet either.

pub(crate) mod auth;
mod client;
mod lyrics;
mod playback;
mod wire;

use std::sync::Arc;

use anyhow::{Context as _, Result};
use async_trait::async_trait;

pub use client::{JellyfinClient, scrub};
pub use lyrics::JellyfinLyrics;

use crate::jellyfin::playback::Factory;
use crate::{
    Capabilities, Catalog, MusicApi as _, MusicProvider, PlaybackFactory, ProviderSession, Shape,
    SignIn,
};

/// The name the provider goes by. It is saved in settings, so it must not change.
pub(crate) const NAME: &str = "Jellyfin";

/// Everything but stations, plus converting on request. Following an artist is liking it.
const CAPABILITIES: Capabilities = Capabilities {
    radio: false,
    transcode: true,
    ..Capabilities::ALL
};

pub struct JellyfinProvider;

impl JellyfinProvider {
    pub fn new() -> Self {
        Self
    }

    fn session(client: JellyfinClient, profile: crate::UserProfile) -> ProviderSession {
        ProviderSession {
            profile,
            api: Arc::new(client.clone()),
            playback: Arc::new(Factory::new(client)),
            shape: Shape::Catalog(Catalog::Fixed),
            authenticated: true,
            capabilities: CAPABILITIES,
        }
    }

    async fn connect(
        server: String,
        username: String,
        password: String,
    ) -> Result<ProviderSession> {
        let server = auth::normalize_server(&server)?;
        let device_id = auth::device_id();
        let credentials =
            client::authenticate(&server, username.trim(), &password, &device_id).await?;
        let client = JellyfinClient::new(&credentials)?;
        let profile = client
            .profile()
            .await
            .context("cannot reach the jellyfin server")?;
        auth::store(&credentials)?;
        Ok(Self::session(client, profile))
    }

    /// The stored account, checked with the server. Only a lost connection is an error, so the
    /// app can try again once the network is back; anything else means the account is gone.
    async fn restore_from(
        remembered: Option<auth::Credentials>,
    ) -> Result<Option<ProviderSession>> {
        let Some(remembered) = remembered else {
            return Ok(None);
        };
        let client = JellyfinClient::new(&remembered)?;
        match client.profile().await {
            Ok(profile) => Ok(Some(Self::session(client, profile))),
            Err(error) if crate::trouble::offline(&format!("{error:#}")) => Err(error),
            Err(error) => {
                log::warn!("jellyfin: the stored session is no longer usable: {error:#}");
                Ok(None)
            }
        }
    }
}

impl Default for JellyfinProvider {
    fn default() -> Self {
        Self::new()
    }
}

#[async_trait]
impl MusicProvider for JellyfinProvider {
    fn name(&self) -> &'static str {
        NAME
    }

    fn slug(&self) -> &'static str {
        "jellyfin"
    }

    fn sign_in_options(&self) -> Vec<SignIn> {
        vec![SignIn::Credentials {
            server: String::new(),
            username: String::new(),
            password: String::new(),
        }]
    }

    fn stored(&self) -> bool {
        auth::load().is_some()
    }

    fn location(&self) -> Option<String> {
        auth::load().map(|credentials| credentials.server)
    }

    /// The configured server's host, since a self-hosted library has no address in common with
    /// anyone else's.
    fn reach(&self) -> Option<String> {
        let server = auth::load()?.server;
        let host = server
            .split_once("://")
            .map_or(server.as_str(), |(_, rest)| rest);
        let host = host.split(['/', ':', '?']).next()?;
        (!host.is_empty()).then(|| host.to_owned())
    }

    fn offline_playback(&self) -> Option<Arc<dyn PlaybackFactory>> {
        let client = JellyfinClient::new(&auth::load()?)
            .inspect_err(|error| log::warn!("jellyfin: cannot build an offline client: {error:#}"))
            .ok()?;
        Some(Arc::new(Factory::new(client)))
    }

    async fn restore(&self) -> Result<Option<ProviderSession>> {
        Self::restore_from(auth::load()).await
    }

    /// An empty password is allowed: Jellyfin accounts may have none, as the demo's does.
    async fn sign_in(
        &self,
        method: SignIn,
        _prompt: crate::PromptSink,
        _input: crate::InputSource,
    ) -> Result<ProviderSession> {
        let SignIn::Credentials {
            server,
            username,
            password,
        } = method
        else {
            anyhow::bail!("jellyfin signs in with a server address, username and password")
        };
        if username.trim().is_empty() {
            anyhow::bail!("the jellyfin username is empty");
        }
        Self::connect(server, username, password).await
    }

    /// Forgets the account at once and tells the server on a thread of its own, so a slow or
    /// gone server never holds up signing out.
    fn sign_out(&self) {
        let Some(credentials) = auth::load() else {
            return;
        };
        auth::forget();
        std::thread::spawn(move || client::logout(&credentials));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn no_stored_account_restores_nothing_without_a_request() {
        let runtime = tokio::runtime::Builder::new_current_thread()
            .build()
            .unwrap();
        let restored = runtime
            .block_on(JellyfinProvider::restore_from(None))
            .unwrap();
        assert!(restored.is_none());
    }
}
