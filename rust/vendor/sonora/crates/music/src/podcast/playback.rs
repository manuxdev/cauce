//! Playback for a podcast episode: an ordinary audio file on the web, streamed through
//! [`crate::stream`] as a Subsonic track is, so it seeks and starts where it was left.
//!
//! Unlike a track, an episode that only plays is never kept: it goes past the vault's cache,
//! and only a download the listener asked for is sealed into the vault, where it plays with no
//! network. The engine only knows an episode by its id, so the core registers each episode's
//! enclosure here as feeds are read; the address itself never reaches a log.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use anyhow::{Context as _, Result, bail};
use async_trait::async_trait;
use serde::{Deserialize, Serialize};

use super::{Episode, SLUG, host};
use crate::aac::Aac;
use crate::engine::{self, Fetch};
use crate::stream::{Plain, Reader, Stream};
use crate::vault::{Recording, Shelf};
use crate::{PlaybackConfig, PlaybackEvents, PlaybackFactory, Player};

/// How long a read waits for the server before an episode gives up, as a track does.
const PATIENCE: Duration = Duration::from_secs(20);

/// Where an episode's audio is, and how long its feed says it is.
#[derive(Clone, Debug)]
struct Known {
    url: String,
    duration: Option<Duration>,
}

/// The enclosures of the episodes the core has seen, by episode id, shared with every engine.
#[derive(Clone, Default)]
pub struct Episodes(Arc<Mutex<HashMap<String, Known>>>);

impl Episodes {
    pub fn register(&self, episode: &Episode) {
        self.note(&episode.id, &episode.url, episode.duration_secs);
    }

    /// Notes where episode `id` is, for one the core remembers without its feed.
    pub fn note(&self, id: &str, url: &str, duration_secs: Option<u64>) {
        if let Ok(mut known) = self.0.lock() {
            known.insert(
                id.to_owned(),
                Known {
                    url: url.to_owned(),
                    duration: duration_secs.map(Duration::from_secs),
                },
            );
        }
    }

    /// The enclosure of episode `id`, once it has been registered.
    pub fn url(&self, id: &str) -> Option<String> {
        self.get(id).map(|known| known.url)
    }

    fn get(&self, id: &str) -> Option<Known> {
        self.0.lock().ok()?.get(id).cloned()
    }
}

pub struct Factory {
    episodes: Episodes,
}

impl Factory {
    pub fn new(episodes: Episodes) -> Self {
        Self { episodes }
    }
}

impl PlaybackFactory for Factory {
    fn start(&self, config: PlaybackConfig) -> (Box<dyn Player>, Box<dyn PlaybackEvents>) {
        let fetch = Podcast {
            // Its own client, so its connections live and die with this engine's runtime. No
            // overall time limit: a long episode takes a while to arrive.
            http: reqwest::Client::builder()
                .user_agent(crate::radio::AGENT)
                .connect_timeout(Duration::from_secs(10))
                .read_timeout(PATIENCE)
                .build()
                .unwrap_or_default(),
            episodes: self.episodes.clone(),
            shelf: config.vault.as_ref().map(|vault| vault.shelf(SLUG)),
        };
        engine::start(fetch, config)
    }
}

struct Podcast {
    http: reqwest::Client,
    episodes: Episodes,
    /// Where downloaded episodes are kept.
    shelf: Option<Shelf>,
}

/// An episode arriving, and its length as the feed said.
#[derive(Clone)]
pub struct Loaded {
    stream: Stream,
    duration: Option<Duration>,
}

/// What the feed said about an episode, kept beside its download.
#[derive(Serialize, Deserialize)]
struct Facts {
    duration_ms: Option<u64>,
}

impl Podcast {
    /// The episode from its download, when it has one.
    async fn recall(&self, id: &str) -> Option<Loaded> {
        let kept = self.shelf.as_ref()?.find(id, "").await?;
        let facts = serde_json::from_slice::<Facts>(&kept.facts)
            .inspect_err(|error| log::warn!("podcast: the kept facts of {id} do not read: {error}"))
            .ok()?;
        let stream = Stream::pulling(kept.source, Some(kept.length), Plain)
            .primed()
            .await
            .inspect_err(|error| log::warn!("podcast: the download of {id} broke: {error:#}"))
            .ok()?;
        log::debug!("podcast: {id} started from its download");
        Some(Loaded {
            stream,
            duration: facts.duration_ms.map(Duration::from_millis),
        })
    }
}

#[async_trait]
impl Fetch for Podcast {
    type Loaded = Loaded;
    type Source = rodio::Decoder<Reader>;

    fn name(&self) -> &'static str {
        "podcast"
    }

    fn shelf(&self) -> Option<&Shelf> {
        self.shelf.as_ref()
    }

    /// A download plays from the vault. Anything else streams from its enclosure, and is only
    /// sealed into the vault when the listener asked for it to be downloaded.
    async fn load(&self, id: &str) -> Result<Loaded> {
        if let Some(loaded) = self.recall(id).await {
            return Ok(loaded);
        }
        if self.shelf.as_ref().is_some_and(Shelf::offline) {
            bail!("offline: only downloaded episodes play");
        }
        let known = self
            .episodes
            .get(id)
            .context("that episode is not listed any more")?;
        if !super::web(&known.url) {
            bail!("the episode is not on the web");
        }
        let host = host(&known.url).to_owned();
        let response = self
            .http
            .get(&known.url)
            .send()
            .await
            .map_err(reqwest::Error::without_url)
            .with_context(|| format!("cannot reach {host}"))?;
        let status = response.status();
        if !status.is_success() {
            bail!("{host} answered with status {status}");
        }
        let mime = response
            .headers()
            .get("content-type")
            .and_then(|mime| mime.to_str().ok())
            .unwrap_or_default()
            .to_lowercase();
        if mime.starts_with("text/") {
            bail!("{host} sent a page, not audio");
        }
        let total = response.content_length();
        let duration = known.duration;
        let body = match &self.shelf {
            Some(shelf) if shelf.is_wanted(id) => {
                let facts = move || {
                    serde_json::to_vec(&Facts {
                        duration_ms: duration.map(|duration| duration.as_millis() as u64),
                    })
                    .ok()
                };
                shelf.keep(id, "", facts, response)
            }
            _ => Recording::through(response),
        };
        let stream = Stream::pulling(body, total, Plain).primed().await?;
        Ok(Loaded { stream, duration })
    }

    fn length(&self, loaded: &Loaded) -> Option<Duration> {
        loaded.duration
    }

    async fn downloaded(&self, loaded: &Loaded) {
        loaded.stream.finished().await;
    }

    fn progress(&self, loaded: &Loaded) -> Option<f32> {
        let total = loaded.stream.total().filter(|total| *total > 0)?;
        Some(loaded.stream.arrived() as f32 / total as f32)
    }

    /// A decoder over the stream, placed at `at`. A server that sent no length makes the
    /// decoder read forward only, which reaches any position from the start.
    fn open(&self, id: &str, loaded: &Loaded, at: Duration) -> Option<Self::Source> {
        let total = loaded.stream.total();
        let mut builder = rodio::Decoder::builder()
            .with_symphonia_decoder::<Aac>()
            .with_data(loaded.stream.reader())
            .with_seekable(total.is_some());
        if let Some(total) = total {
            builder = builder.with_byte_len(total);
        }
        let mut decoder = builder
            .build()
            .inspect_err(|error| log::warn!("podcast: cannot decode the episode {id}: {error}"))
            .ok()?;
        if !at.is_zero()
            && let Err(error) = rodio::Source::try_seek(&mut decoder, at)
        {
            log::warn!(
                "podcast: cannot start the episode {id} at {}s: {error}",
                at.as_secs()
            );
        }
        Some(decoder)
    }

    /// As for a Subsonic track: a decoder opened before the episode was all in may only read
    /// forward, so every seek starts a fresh one.
    fn reopen_to_seek(&self) -> bool {
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_episode_is_found_by_its_id_once_registered() {
        let episodes = Episodes::default();
        assert_eq!(episodes.url("a"), None);
        episodes.register(&Episode {
            id: "a".to_owned(),
            title: "A".to_owned(),
            url: "https://cdn.example.com/a.mp3".to_owned(),
            mime: None,
            duration_secs: Some(60),
            published: None,
            artwork: None,
        });
        assert_eq!(
            episodes.url("a").as_deref(),
            Some("https://cdn.example.com/a.mp3")
        );
        assert_eq!(
            episodes.get("a").unwrap().duration,
            Some(Duration::from_secs(60))
        );
        episodes.note("a", "https://cdn.example.com/moved.mp3", None);
        assert_eq!(
            episodes.url("a").as_deref(),
            Some("https://cdn.example.com/moved.mp3")
        );
    }
}
