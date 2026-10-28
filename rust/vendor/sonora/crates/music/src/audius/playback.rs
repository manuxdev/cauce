//! Playback for Audius: the MP3 the stream endpoint redirects to, spooled as it arrives so it
//! seeks, as a podcast episode is.
//!
//! Audius's API terms allow only caching for the session, so nothing is kept: a track never goes
//! into the vault, is never downloaded, and its spool is an unlinked file that is gone when the
//! track is. Only a track the API says anyone may stream is asked for.

use std::sync::Arc;
use std::time::Duration;

use anyhow::{Context as _, Result, bail};
use async_trait::async_trait;

use super::client::AudiusClient;
use super::wire;
use crate::aac::Aac;
use crate::engine::{self, Fetch};
use crate::stream::{Plain, Reader, Stream};
use crate::vault::{Recording, Vault};
use crate::{PlaybackConfig, PlaybackEvents, PlaybackFactory, Player};

/// How long a read waits for a content node before a track gives up.
const PATIENCE: Duration = Duration::from_secs(20);

pub struct Factory {
    client: AudiusClient,
}

impl Factory {
    pub fn new(client: AudiusClient) -> Self {
        Self { client }
    }
}

impl PlaybackFactory for Factory {
    fn start(&self, config: PlaybackConfig) -> (Box<dyn Player>, Box<dyn PlaybackEvents>) {
        let fetch = Audius {
            // Its own client, so its connections live and die with this engine's runtime. No
            // overall limit: a long mix takes a while to arrive.
            http: reqwest::Client::builder()
                .user_agent(crate::radio::AGENT)
                .connect_timeout(Duration::from_secs(10))
                .read_timeout(PATIENCE)
                .build()
                .unwrap_or_default(),
            host: self.client.host().to_owned(),
            vault: config.vault.clone(),
        };
        engine::start(fetch, config)
    }
}

struct Audius {
    http: reqwest::Client,
    host: String,
    /// Only asked whether the app is offline: nothing is kept in it.
    vault: Option<Arc<Vault>>,
}

#[derive(Clone)]
pub struct Loaded {
    stream: Stream,
}

#[async_trait]
impl Fetch for Audius {
    type Loaded = Loaded;
    type Source = rodio::Decoder<Reader>;

    fn name(&self) -> &'static str {
        super::SLUG
    }

    async fn load(&self, id: &str) -> Result<Loaded> {
        if self.vault.as_ref().is_some_and(|vault| vault.offline()) {
            bail!("offline: audius tracks only stream");
        }
        let response = self
            .http
            .get(wire::stream_url(&self.host, id))
            .send()
            .await
            .map_err(reqwest::Error::without_url)
            .context("cannot reach audius")?;
        let status = response.status();
        if !status.is_success() {
            bail!("audius answered the stream with status {status}");
        }
        let total = response.content_length();
        let stream = Stream::pulling(Recording::through(response), total, Plain)
            .primed()
            .await?;
        Ok(Loaded { stream })
    }

    async fn downloaded(&self, loaded: &Loaded) {
        loaded.stream.finished().await;
    }

    fn progress(&self, loaded: &Loaded) -> Option<f32> {
        let total = loaded.stream.total().filter(|total| *total > 0)?;
        Some(loaded.stream.arrived() as f32 / total as f32)
    }

    /// A decoder over the stream, placed at `at`. A node that sent no length makes the decoder
    /// read forward only, which reaches any position from the start.
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
            .inspect_err(|error| log::warn!("audius: cannot decode the track {id}: {error}"))
            .ok()?;
        if !at.is_zero()
            && let Err(error) = rodio::Source::try_seek(&mut decoder, at)
        {
            log::warn!(
                "audius: cannot start the track {id} at {}s: {error}",
                at.as_secs()
            );
        }
        Some(decoder)
    }

    /// As for an episode: a decoder opened before the track was all in may only read forward,
    /// so every seek starts a fresh one.
    fn reopen_to_seek(&self) -> bool {
        true
    }
}
