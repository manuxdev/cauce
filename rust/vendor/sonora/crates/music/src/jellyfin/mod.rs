//! A Jellyfin or Emby server: sign-in, the library, search, playback and downloads, likes,
//! playlist edits, server lyrics, and finished listens recorded on the server. Jellyfin began as
//! a fork of Emby and the two still share most of the API, so one client speaks to both.

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

/// Which server a sign-in is with. The client follows it wherever the servers' APIs part.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum Flavor {
    #[default]
    Jellyfin,
    Emby,
}

impl Flavor {
    /// The name the provider goes by. It is saved in settings, so it must not change.
    pub fn name(self) -> &'static str {
        match self {
            Self::Jellyfin => "Jellyfin",
            Self::Emby => "Emby",
        }
    }

    /// The provider's slug, which also names its folder of credentials and its vault shelf.
    pub fn slug(self) -> &'static str {
        match self {
            Self::Jellyfin => "jellyfin",
            Self::Emby => "emby",
        }
    }
}

/// Everything but stations, plus converting on request. Following an artist is liking it.
const CAPABILITIES: Capabilities = Capabilities {
    radio: false,
    transcode: true,
    ..Capabilities::ALL
};

pub struct JellyfinProvider {
    flavor: Flavor,
}

impl JellyfinProvider {
    pub fn new() -> Self {
        Self {
            flavor: Flavor::Jellyfin,
        }
    }

    pub fn emby() -> Self {
        Self {
            flavor: Flavor::Emby,
        }
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
        flavor: Flavor,
        server: String,
        username: String,
        password: String,
    ) -> Result<ProviderSession> {
        let server = auth::normalize_server(&server)?;
        let device_id = auth::device_id(flavor);
        let credentials =
            client::authenticate(flavor, &server, username.trim(), &password, &device_id).await?;
        let client = JellyfinClient::new(&credentials)?;
        let profile = client
            .profile()
            .await
            .with_context(|| format!("cannot reach the {} server", flavor.slug()))?;
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
                log::warn!(
                    "{}: the stored session is no longer usable: {error:#}",
                    remembered.flavor.slug()
                );
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
        self.flavor.name()
    }

    fn slug(&self) -> &'static str {
        self.flavor.slug()
    }

    fn sign_in_options(&self) -> Vec<SignIn> {
        vec![SignIn::Credentials {
            server: String::new(),
            username: String::new(),
            password: String::new(),
        }]
    }

    fn stored(&self) -> bool {
        auth::load(self.flavor).is_some()
    }

    fn location(&self) -> Option<String> {
        auth::load(self.flavor).map(|credentials| credentials.server)
    }

    /// The configured server's host, since a self-hosted library has no address in common with
    /// anyone else's.
    fn reach(&self) -> Option<String> {
        let server = auth::load(self.flavor)?.server;
        let host = server
            .split_once("://")
            .map_or(server.as_str(), |(_, rest)| rest);
        let host = host.split(['/', ':', '?']).next()?;
        (!host.is_empty()).then(|| host.to_owned())
    }

    fn offline_playback(&self) -> Option<Arc<dyn PlaybackFactory>> {
        let client = JellyfinClient::new(&auth::load(self.flavor)?)
            .inspect_err(|error| {
                log::warn!(
                    "{}: cannot build an offline client: {error:#}",
                    self.flavor.slug()
                )
            })
            .ok()?;
        Some(Arc::new(Factory::new(client)))
    }

    async fn restore(&self) -> Result<Option<ProviderSession>> {
        Self::restore_from(auth::load(self.flavor)).await
    }

    /// An empty password is allowed: Jellyfin and Emby accounts may have none, as the Jellyfin
    /// demo's does.
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
            anyhow::bail!(
                "{} signs in with a server address, username and password",
                self.flavor.slug()
            )
        };
        if username.trim().is_empty() {
            anyhow::bail!("the {} username is empty", self.flavor.slug());
        }
        Self::connect(self.flavor, server, username, password).await
    }

    /// Forgets the account at once and tells the server on a thread of its own, so a slow or
    /// gone server never holds up signing out.
    fn sign_out(&self) {
        let Some(credentials) = auth::load(self.flavor) else {
            return;
        };
        auth::forget(self.flavor);
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
