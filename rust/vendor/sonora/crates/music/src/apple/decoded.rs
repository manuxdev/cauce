//! An Apple Music track decoded by Android's own AAC decoder.
//!
//! Android hands an app no decrypted compressed samples, so on Android the samples never go
//! through the spool's in-place decryption: each one is read out of the [`Media`] index as it
//! arrived, with its IV and subsample layout, and fed to [`widevine::Decoder`], which decrypts
//! it against the track's session and gives back PCM. Everything around it, the trim, the
//! engine and the output, is what every other track goes through.
//!
//! The codec runs on whichever thread pulls the source, which is the engine's decode thread,
//! the same one that waits on the network for every other provider's reads.

use std::num::NonZero;
use std::time::Duration;

use anyhow::{Context as _, Result};
use rodio::{ChannelCount, SampleRate, Source};
use widevine::cenc::{self, Sample};
use widevine::{Decoder, Input, Taken};

use crate::apple::progressive::{Entry, Media};

/// PCM frames in one AAC access unit at the core rate, which is all a sample's timestamp
/// needs: the decoder only wants them to rise.
const FRAMES_PER_SAMPLE: u64 = 1024;

/// How long to wait for output when the decoder will take no more input, or has had it all.
const WAIT: Duration = Duration::from_millis(10);

/// A licensed track, decoded from the fragment `open` was given onwards.
pub struct Decoded {
    media: Media,
    decoder: Decoder,
    /// The next sample to queue, and the first, which timestamps count from.
    next: usize,
    first: usize,
    /// A sample the decoder had no room for yet; `Some(None)` is the end of the stream.
    pending: Option<Option<(Vec<u8>, Sample)>>,
    /// The end of the stream has been queued.
    queued_end: bool,
    /// The end of the stream has come out, or decoding broke.
    ended: bool,
    pcm: Vec<f32>,
    at: usize,
    /// The rate timestamps are counted at, which the init segment declares.
    clock: u32,
    rate: SampleRate,
    channels: ChannelCount,
    /// Interleaved samples handed on, for the log line at the end.
    handed: u64,
}

impl Decoded {
    /// Opens a decoder over `media` that starts at `entry`, or at the top of the track, and
    /// decodes until the first audio comes out, which is what settles its rate and channels.
    pub fn open(media: &Media, entry: Option<Entry>) -> Result<Self> {
        let header = media.header().context("the init segment has not arrived")?;
        let audio = cenc::audio(&header).context("the init segment carries no aac config")?;
        let (cdm, key_id) = media.keys().context("the track has no license loaded")?;
        let decoder = Decoder::open(&cdm, &key_id, &audio)?;
        let first = media.first(entry);
        let mut decoded = Self {
            media: media.clone(),
            decoder,
            next: first,
            first,
            pending: None,
            queued_end: false,
            ended: false,
            pcm: Vec::new(),
            at: 0,
            clock: audio.rate.max(1),
            rate: NonZero::new(audio.rate).context("the init segment declares no rate")?,
            channels: NonZero::new(audio.channels)
                .context("the init segment declares no channels")?,
            handed: 0,
        };
        while decoded.pcm.is_empty() && !decoded.ended {
            decoded.step()?;
        }
        decoded.settle();
        Ok(decoded)
    }

    /// Takes the rate and channels the decoder settled on.
    fn settle(&mut self) {
        if let (Some(rate), Some(channels)) = (
            NonZero::new(self.decoder.rate()),
            NonZero::new(self.decoder.channels()),
        ) {
            self.rate = rate;
            self.channels = channels;
        }
    }

    /// Offers the decoder one sample, or the end of the stream, then takes whatever audio it
    /// has ready. Blocks on the network when the next sample has not arrived.
    fn step(&mut self) -> Result<()> {
        let mut wait = WAIT;
        if !self.queued_end {
            if self.pending.is_none() {
                self.pending = Some(self.media.sample(self.next)?);
            }
            let pts_us = (self.next - self.first) as u64 * FRAMES_PER_SAMPLE * 1_000_000
                / u64::from(self.clock);
            let input = self.pending.as_ref().and_then(|pending| {
                pending.as_ref().map(|(data, sample)| Input {
                    data,
                    iv: &sample.iv,
                    subs: &sample.subs,
                    pts_us,
                })
            });
            let end = input.is_none();
            if self.decoder.queue(input)? {
                self.pending = None;
                match end {
                    true => self.queued_end = true,
                    false => {
                        self.next += 1;
                        wait = Duration::ZERO;
                    }
                }
            }
        }
        if self.decoder.take(wait, &mut self.pcm)? == Taken::End {
            self.ended = true;
        }
        Ok(())
    }
}

impl Iterator for Decoded {
    type Item = f32;

    fn next(&mut self) -> Option<f32> {
        loop {
            if let Some(&sample) = self.pcm.get(self.at) {
                self.at += 1;
                self.handed += 1;
                return Some(sample);
            }
            if self.ended {
                return None;
            }
            self.pcm.clear();
            self.at = 0;
            if let Err(error) = self.step() {
                log::warn!("apple: android decoding stopped: {error:#}");
                self.ended = true;
            }
        }
    }
}

impl Source for Decoded {
    fn current_span_len(&self) -> Option<usize> {
        None
    }

    fn channels(&self) -> ChannelCount {
        self.channels
    }

    fn sample_rate(&self) -> SampleRate {
        self.rate
    }

    fn total_duration(&self) -> Option<Duration> {
        None
    }
}

impl Drop for Decoded {
    fn drop(&mut self) {
        log::info!(
            "apple: android decoder closed after {} of {} samples, {:.1}s of audio",
            self.next - self.first,
            self.media.samples(),
            self.handed as f64 / f64::from(self.rate.get()) / f64::from(self.channels.get())
        );
    }
}
