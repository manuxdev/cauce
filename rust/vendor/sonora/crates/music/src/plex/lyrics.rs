use std::sync::Mutex;

use anyhow::Result;
use async_trait::async_trait;

use crate::plex::auth::{self, Credentials, SLUG};
use crate::plex::{NAME, PlexClient};
use crate::{LyricsHit, LyricsProvider, LyricsQuery};

/// The same tier as lyrics read from a local file, since these are most often the user's own.
const TRUST: u32 = 100;

type Identity = (String, String, String);

/// Asks the signed-in Plex server for the lyrics of one of its tracks. Any other track, or no
/// stored sign-in, gets no answer and makes no request.
pub struct PlexLyrics {
    client: Mutex<Option<(Identity, PlexClient)>>,
}

impl PlexLyrics {
    pub fn new() -> Self {
        Self {
            client: Mutex::new(None),
        }
    }

    /// A client for `stored`, kept until the credentials change. This provider has no session
    /// handle, so it reads the same file the session was restored from, whose address is the one
    /// that answered last.
    fn client(&self, stored: Option<Credentials>) -> Result<Option<PlexClient>> {
        let Some(stored) = stored else {
            return Ok(None);
        };
        let identity = (
            stored.server.clone(),
            stored.server_id.clone(),
            stored.token.clone(),
        );
        let mut held = self
            .client
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if let Some((known, client)) = held.as_ref()
            && *known == identity
        {
            return Ok(Some(client.clone()));
        }
        let client = PlexClient::new(&stored)?;
        *held = Some((identity, client.clone()));
        Ok(Some(client))
    }

    async fn search_with(
        &self,
        query: &LyricsQuery,
        stored: impl FnOnce() -> Option<Credentials>,
    ) -> Result<Vec<LyricsHit>> {
        let Some(id) = query.id_for(SLUG) else {
            return Ok(Vec::new());
        };
        let Some(client) = self.client(stored())? else {
            return Ok(Vec::new());
        };
        let found = client.lyrics(id).await?;
        Ok(found
            .into_iter()
            .map(|lyrics| LyricsHit {
                source: NAME,
                trust: TRUST,
                lyrics,
                instrumental: false,
                title: query.title.clone(),
                artist: query.artist.clone(),
                album: query.album.clone(),
                duration: (!query.duration.is_zero()).then_some(query.duration),
                writers: Vec::new(),
            })
            .collect())
    }
}

impl Default for PlexLyrics {
    fn default() -> Self {
        Self::new()
    }
}

#[async_trait]
impl LyricsProvider for PlexLyrics {
    fn name(&self) -> &'static str {
        NAME
    }

    async fn search(&self, query: &LyricsQuery) -> Result<Vec<LyricsHit>> {
        self.search_with(query, auth::load).await
    }
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use super::*;
    use crate::TrackKey;

    fn query(track: Option<TrackKey>) -> LyricsQuery {
        LyricsQuery {
            title: "Tide".into(),
            artist: "Waves".into(),
            album: None,
            duration: Duration::ZERO,
            track,
        }
    }

    fn credentials() -> Credentials {
        Credentials {
            // nothing listens here, so a request would fail the test
            server: "http://127.0.0.1:9".into(),
            addresses: Vec::new(),
            server_id: "abc".into(),
            server_name: "Den".into(),
            user_id: "1".into(),
            username: "listener".into(),
            client_id: "c".into(),
            token: "t".into(),
        }
    }

    fn search(query: &LyricsQuery, stored: Option<Credentials>) -> Result<Vec<LyricsHit>> {
        tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap()
            .block_on(PlexLyrics::new().search_with(query, || stored))
    }

    #[test]
    fn a_track_from_elsewhere_gets_nothing_and_asks_nobody() {
        let elsewhere = query(Some(TrackKey {
            provider: "jellyfin",
            id: "1".into(),
        }));
        assert!(search(&elsewhere, Some(credentials())).unwrap().is_empty());
        assert!(
            search(&query(None), Some(credentials()))
                .unwrap()
                .is_empty()
        );
    }

    #[test]
    fn no_stored_sign_in_gets_nothing() {
        let mine = query(Some(TrackKey {
            provider: "plex",
            id: "1".into(),
        }));
        assert!(search(&mine, None).unwrap().is_empty());
    }
}
