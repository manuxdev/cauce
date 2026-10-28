//! A Plex Media Server: sign-in through plex.tv, the library, search, playback and downloads.

pub mod auth;
mod client;
pub mod pin;
mod playback;
mod wire;

use std::sync::Arc;

use anyhow::{Context as _, Result};
use async_trait::async_trait;

pub use client::PlexClient;

use crate::plex::auth::{Credentials, SLUG};
use crate::plex::playback::Factory;
use crate::{
    Capabilities, Catalog, MusicApi as _, MusicProvider, PlaybackFactory, ProviderSession, Shape,
    SignIn,
};

/// The name the provider goes by. It is saved in settings, so it must not change.
pub const NAME: &str = "Plex";
/// What plex.tv and the server are told the app is called.
pub const PRODUCT: &str = "Cauce";

/// Everything but stations and likes, plus converting on request.
const CAPABILITIES: Capabilities = Capabilities {
    follow_artists: false,
    radio: false,
    transcode: true,
    ..Capabilities::ALL
};

#[derive(Default)]
pub struct PlexProvider;

impl PlexProvider {
    pub fn new() -> Self {
        Self
    }

    fn session(client: PlexClient, profile: crate::UserProfile) -> ProviderSession {
        ProviderSession {
            profile,
            api: Arc::new(client.clone()),
            playback: Arc::new(Factory::new(client)),
            shape: Shape::Catalog(Catalog::Fixed),
            authenticated: true,
            capabilities: CAPABILITIES,
        }
    }

    /// A client for `credentials` that knows the server's music libraries.
    async fn open(credentials: &Credentials) -> Result<PlexClient> {
        let client = PlexClient::new(credentials)?;
        let sections = client.music_sections().await?;
        if sections.is_empty() {
            anyhow::bail!("the plex server has no music library");
        }
        Ok(client.with_sections(sections))
    }

    /// Picks the account's server `server_id`, reaches it on the best address that answers, and
    /// only then stores the sign-in. The account token goes no further than this.
    async fn connect(account_token: &str, server_id: &str) -> Result<ProviderSession> {
        let client_id = auth::client_id();
        let (account, servers) = tokio::join!(
            pin::account(&client_id, account_token),
            pin::servers(&client_id, account_token)
        );
        let account = account?;
        let server = servers?
            .into_iter()
            .find(|server| server.id == server_id)
            .context("the plex server is no longer shared with this account")?;
        let address = client::reach(&server.addresses, &client_id, &server.token)
            .await
            .context("cannot reach the plex server")?;
        let credentials = Credentials {
            server: address,
            addresses: server.addresses,
            server_id: server.id,
            server_name: server.name,
            user_id: account.id,
            username: match account.username.is_empty() {
                true => account.title,
                false => account.username,
            },
            client_id,
            token: server.token,
        };
        let client = Self::open(&credentials).await?;
        auth::store(&credentials)?;
        let profile = client.profile().await?;
        Ok(Self::session(client, profile))
    }

    /// The stored account, checked with the server. A server gone from the address that
    /// answered last is looked for on its others, since the phone may have left the network it
    /// was on. Only a lost connection is an error, so the app can try again once the network is
    /// back; anything else means the account is gone.
    async fn restore_from(remembered: Option<Credentials>) -> Result<Option<ProviderSession>> {
        let Some(remembered) = remembered else {
            return Ok(None);
        };
        let error = match Self::open(&remembered).await {
            Ok(client) => {
                let profile = client.profile().await?;
                return Ok(Some(Self::session(client, profile)));
            }
            Err(error) => error,
        };
        if !crate::trouble::offline(&format!("{error:#}")) {
            log::warn!("plex: the stored session is no longer usable: {error:#}");
            return Ok(None);
        }
        let moved = client::reach(
            &remembered.addresses,
            &remembered.client_id,
            &remembered.token,
        )
        .await;
        let Some(address) = moved.filter(|address| *address != remembered.server) else {
            return Err(error);
        };
        let moved = Credentials {
            server: address,
            ..remembered
        };
        let client = Self::open(&moved).await?;
        if let Err(error) = auth::store(&moved) {
            log::warn!("plex: cannot keep the address that answered: {error:#}");
        }
        let profile = client.profile().await?;
        Ok(Some(Self::session(client, profile)))
    }
}

#[async_trait]
impl MusicProvider for PlexProvider {
    fn name(&self) -> &'static str {
        NAME
    }

    fn slug(&self) -> &'static str {
        SLUG
    }

    fn sign_in_options(&self) -> Vec<SignIn> {
        vec![SignIn::Plex {
            token: String::new(),
            server: String::new(),
        }]
    }

    fn stored(&self) -> bool {
        auth::load().is_some()
    }

    fn location(&self) -> Option<String> {
        auth::load().map(|credentials| credentials.server_name)
    }

    /// The host of the address that answered last.
    fn reach(&self) -> Option<String> {
        let server = auth::load()?.server;
        let host = server
            .split_once("://")
            .map_or(server.as_str(), |(_, rest)| rest);
        let host = host.split(['/', ':', '?']).next()?;
        (!host.is_empty()).then(|| host.to_owned())
    }

    fn offline_playback(&self) -> Option<Arc<dyn PlaybackFactory>> {
        let client = PlexClient::new(&auth::load()?)
            .inspect_err(|error| log::warn!("plex: cannot build an offline client: {error:#}"))
            .ok()?;
        Some(Arc::new(Factory::new(client)))
    }

    async fn restore(&self) -> Result<Option<ProviderSession>> {
        Self::restore_from(auth::load()).await
    }

    async fn sign_in(&self, method: SignIn) -> Result<ProviderSession> {
        let SignIn::Plex { token, server } = method else {
            anyhow::bail!("plex signs in through plex.tv");
        };
        Self::connect(&token, &server).await
    }

    /// Forgets the server's token. The account's own was never kept, so nothing is left to
    /// sign out of on plex.tv.
    fn sign_out(&self) {
        auth::forget();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn runtime() -> tokio::runtime::Runtime {
        tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap()
    }

    #[test]
    fn no_stored_account_restores_nothing_without_a_request() {
        let restored = runtime()
            .block_on(PlexProvider::restore_from(None))
            .unwrap();
        assert!(restored.is_none());
    }

    #[test]
    fn a_password_sign_in_is_refused() {
        let method = SignIn::Credentials {
            server: "plex.example.com".to_owned(),
            username: "u".to_owned(),
            password: "p".to_owned(),
        };
        assert!(
            runtime()
                .block_on(PlexProvider::new().sign_in(method))
                .is_err()
        );
    }
}
