//! Playback for a radio station: an endless stream, decoded as it arrives and never kept.
//!
//! [`crate::stream`] spools a whole track so it can be sought and read again, which an endless
//! stream would grow without bound. A station instead goes through a short, bounded pipe:
//! the response fills it on the engine's runtime, the decoder drains it on the audio thread,
//! and whatever has been heard is gone. Nothing reaches the vault or the disk.
//!
//! A dropped connection is retried a couple of times before the station ends. While paused the
//! pipe fills and the response stops being read; after a while it is let go, and the core loads
//! the station afresh on play, so it resumes at "now" rather than from a stale buffer.

use std::io::{self, Read, Seek, SeekFrom};
use std::sync::mpsc::{Receiver, RecvTimeoutError, SyncSender, TrySendError, sync_channel};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use anyhow::{Result, bail};
use async_trait::async_trait;
use bytes::Bytes;

use super::{AGENT, RadioBrowser};
use crate::aac::Aac;
use crate::engine::{self, Fetch};
use crate::vault::Vault;
use crate::{Encoding, PlaybackConfig, PlaybackEvents, PlaybackFactory, Player};

/// How many chunks of the response the pipe holds, about a second or two of audio each.
const CHUNKS: usize = 32;
/// How long a read waits for the stream before the decoder gives up, as a spooled track does.
const PATIENCE: Duration = Duration::from_secs(20);
/// How long a full pipe holds the connection open, as while paused, before letting it go.
const STALE: Duration = Duration::from_secs(30);
/// How often a full pipe is looked at again.
const POLL: Duration = Duration::from_millis(50);
/// How many times a dropped stream is opened again before the station ends.
const RETRIES: u32 = 2;
const RETRY_AFTER: Duration = Duration::from_secs(1);

/// What the station is playing now, by station id, as its stream's metadata names it.
type NowPlaying = Arc<Mutex<Option<(String, String)>>>;

pub struct Factory {
    browser: RadioBrowser,
    now: NowPlaying,
}

impl Factory {
    pub fn new(browser: RadioBrowser) -> Self {
        Self {
            browser,
            now: NowPlaying::default(),
        }
    }

    /// The song station `id` says it is playing, when its stream sends titles.
    pub fn now_playing(&self, id: &str) -> Option<String> {
        let now = self.now.lock().ok()?;
        now.as_ref()
            .filter(|(station, _)| station == id)
            .map(|(_, title)| title.clone())
            .filter(|title| !title.is_empty())
    }
}

impl PlaybackFactory for Factory {
    fn start(&self, config: PlaybackConfig) -> (Box<dyn Player>, Box<dyn PlaybackEvents>) {
        let radio = Radio {
            browser: self.browser.clone(),
            // Its own client, so its connections live and die with this engine's runtime.
            http: reqwest::Client::builder()
                .user_agent(AGENT)
                .connect_timeout(Duration::from_secs(10))
                .read_timeout(PATIENCE)
                .build()
                .unwrap_or_default(),
            now: self.now.clone(),
            vault: config.vault.clone(),
        };
        engine::start(radio, config)
    }
}

struct Radio {
    browser: RadioBrowser,
    http: reqwest::Client,
    now: NowPlaying,
    vault: Option<Arc<Vault>>,
}

/// A station's stream, opened and filling its pipe, for one decoder to take.
#[derive(Clone)]
pub struct Loaded {
    live: Arc<Mutex<Option<Live>>>,
    mime: Option<String>,
    encoding: Option<Encoding>,
}

#[async_trait]
impl Fetch for Radio {
    type Loaded = Loaded;
    type Source = rodio::Decoder<Live>;

    fn name(&self) -> &'static str {
        "radio"
    }

    /// Counts the play with Radio Browser, which also resolves the stream, opens it, and starts
    /// filling the pipe.
    async fn load(&self, id: &str) -> Result<Loaded> {
        if self.vault.as_ref().is_some_and(|vault| vault.offline()) {
            bail!("offline: radio needs the network");
        }
        let url = self.browser.click(id).await?;
        let response = connect(&self.http, &url).await?;
        let mime = header(&response, "content-type")
            .map(|mime| mime.split(';').next().unwrap_or_default().trim().to_lowercase());
        if mime.as_deref().is_some_and(|mime| {
            mime.starts_with("text/") || mime.contains("mpegurl") || mime.contains("x-scpls")
        }) {
            bail!("the station sent a page or a playlist, not audio");
        }
        let kbps = header(&response, "icy-br")
            .and_then(|kbps| kbps.split(',').next()?.trim().parse().ok());
        let encoding = mime.as_deref().map(|mime| encoding(mime, kbps.unwrap_or(0)));
        let (chunks, live) = Live::pipe();
        tokio::spawn(pump(
            self.http.clone(),
            url,
            response,
            chunks,
            self.now.clone(),
            id.to_owned(),
        ));
        Ok(Loaded {
            live: Arc::new(Mutex::new(Some(live))),
            mime,
            encoding,
        })
    }

    fn encoding(&self, loaded: &Loaded) -> Option<Encoding> {
        loaded.encoding
    }

    /// Never: a station never arrives whole, so nothing is preloaded behind it.
    async fn downloaded(&self, _loaded: &Loaded) {
        std::future::pending::<()>().await;
    }

    fn open(&self, id: &str, loaded: &Loaded, _at: Duration) -> Option<Self::Source> {
        let live = loaded.live.lock().ok()?.take()?;
        let mut builder = rodio::Decoder::builder()
            .with_symphonia_decoder::<Aac>()
            .with_data(live)
            .with_seekable(false);
        if let Some(mime) = &loaded.mime {
            builder = builder.with_mime_type(mime);
        }
        builder
            .build()
            .inspect_err(|error| log::warn!("playback: cannot decode the station {id}: {error}"))
            .ok()
    }

    /// A live stream starts at "now", wherever the listener left it last time.
    fn open_near(
        &self,
        id: &str,
        loaded: &Loaded,
        _at: Duration,
    ) -> Option<(Self::Source, Duration)> {
        self.open(id, loaded, Duration::ZERO)
            .map(|source| (source, Duration::ZERO))
    }
}

/// How a stream of `mime` is encoded, as far as its type and announced bitrate tell.
fn encoding(mime: &str, kbps: u32) -> Encoding {
    match mime {
        "audio/mpeg" | "audio/mp3" => Encoding::Mp3 { kbps },
        "audio/aac" | "audio/aacp" | "audio/x-aac" => Encoding::Aac { kbps },
        "audio/opus" => Encoding::Opus { kbps },
        "audio/vorbis" => Encoding::Vorbis { kbps },
        _ => Encoding::Other,
    }
}

fn header(response: &reqwest::Response, name: &str) -> Option<String> {
    response
        .headers()
        .get(name)?
        .to_str()
        .ok()
        .map(str::to_owned)
}

/// Opens the stream, asking for the song titles to be sent in it.
async fn connect(http: &reqwest::Client, url: &str) -> Result<reqwest::Response> {
    let response = http
        .get(url)
        .header("Icy-MetaData", "1")
        .send()
        .await
        .map_err(reqwest::Error::without_url)?;
    let status = response.status();
    if !status.is_success() {
        bail!("the station answered with status {status}");
    }
    Ok(response)
}

/// Pulls the stream into the pipe, taking the song titles out of it, until the decoder is gone,
/// the pipe has been full too long, or the stream cannot be opened again.
async fn pump(
    http: reqwest::Client,
    url: String,
    mut response: reqwest::Response,
    chunks: SyncSender<Bytes>,
    now: NowPlaying,
    id: String,
) {
    let mut icy = Icy::of(&response);
    let mut retries = 0;
    loop {
        let chunk = match response.chunk().await {
            Ok(Some(chunk)) => chunk,
            ended => {
                if let Err(error) = ended {
                    log::debug!("radio: the stream of {id} broke: {}", error.without_url());
                }
                if retries == RETRIES {
                    log::info!("radio: the stream of {id} ended");
                    return;
                }
                retries += 1;
                tokio::time::sleep(RETRY_AFTER).await;
                match connect(&http, &url).await {
                    Ok(again) => {
                        icy = Icy::of(&again);
                        response = again;
                    }
                    Err(error) => log::debug!("radio: cannot reopen {id}: {error:#}"),
                }
                continue;
            }
        };
        retries = 0;
        let mut audio = Vec::with_capacity(chunk.len());
        if let Some(title) = icy.feed(&chunk, &mut audio)
            && let Ok(mut now) = now.lock()
        {
            *now = Some((id.clone(), title));
        }
        if !audio.is_empty() && !send(&chunks, Bytes::from(audio)).await {
            return;
        }
    }
}

/// Puts `bytes` in the pipe, waiting while it is full. Answers whether the pump goes on: not
/// once the decoder is gone or the pipe has stayed full for [`STALE`].
async fn send(chunks: &SyncSender<Bytes>, mut bytes: Bytes) -> bool {
    let mut waited = Duration::ZERO;
    loop {
        match chunks.try_send(bytes) {
            Ok(()) => return true,
            Err(TrySendError::Disconnected(_)) => return false,
            Err(TrySendError::Full(_)) if waited >= STALE => return false,
            Err(TrySendError::Full(back)) => {
                bytes = back;
                tokio::time::sleep(POLL).await;
                waited += POLL;
            }
        }
    }
}

/// The decoder's end of the pipe. It only reads forward: a live stream has nowhere to seek to.
pub struct Live {
    chunks: Mutex<Receiver<Bytes>>,
    held: Bytes,
    at: u64,
}

impl Live {
    fn pipe() -> (SyncSender<Bytes>, Self) {
        let (chunks, arriving) = sync_channel(CHUNKS);
        let live = Self {
            chunks: Mutex::new(arriving),
            held: Bytes::new(),
            at: 0,
        };
        (chunks, live)
    }
}

impl Read for Live {
    fn read(&mut self, out: &mut [u8]) -> io::Result<usize> {
        if out.is_empty() {
            return Ok(0);
        }
        while self.held.is_empty() {
            let chunks = self
                .chunks
                .get_mut()
                .map_err(|_| io::Error::other("the station's pipe is poisoned"))?;
            match chunks.recv_timeout(PATIENCE) {
                Ok(chunk) => self.held = chunk,
                Err(RecvTimeoutError::Timeout) => {
                    return Err(io::Error::new(
                        io::ErrorKind::TimedOut,
                        "the station stopped arriving",
                    ));
                }
                // The stream ended for good: the station is over.
                Err(RecvTimeoutError::Disconnected) => return Ok(0),
            }
        }
        let taken = out.len().min(self.held.len());
        out[..taken].copy_from_slice(&self.held.split_to(taken));
        self.at += taken as u64;
        Ok(taken)
    }
}

impl Seek for Live {
    /// Only where it already is, which is all a decoder asks of a stream that is not seekable.
    fn seek(&mut self, pos: SeekFrom) -> io::Result<u64> {
        match pos {
            SeekFrom::Current(0) => Ok(self.at),
            SeekFrom::Start(at) if at == self.at => Ok(self.at),
            _ => Err(io::Error::new(
                io::ErrorKind::Unsupported,
                "a live stream cannot seek",
            )),
        }
    }
}

/// Takes the ICY metadata blocks out of a stream that interleaves them with the audio, and
/// reads the song titles in them.
///
/// Every `every` bytes of audio the server puts one length byte, in units of 16, and that many
/// bytes of `StreamTitle='…';` text.
struct Icy {
    every: Option<usize>,
    state: Part,
}

enum Part {
    /// This many bytes of audio before the next length byte.
    Audio(usize),
    Length,
    /// This many bytes of metadata still to come, and those so far.
    Meta(usize, Vec<u8>),
}

impl Icy {
    fn of(response: &reqwest::Response) -> Self {
        Self::every(header(response, "icy-metaint").and_then(|every| every.trim().parse().ok()))
    }

    fn every(every: Option<usize>) -> Self {
        let every = every.filter(|every| *every > 0);
        Self {
            every,
            state: Part::Audio(every.unwrap_or(0)),
        }
    }

    /// Appends the audio in `chunk` to `audio`, and answers the last title it carried, if any.
    fn feed(&mut self, mut chunk: &[u8], audio: &mut Vec<u8>) -> Option<String> {
        let Some(every) = self.every else {
            audio.extend_from_slice(chunk);
            return None;
        };
        let mut found = None;
        while !chunk.is_empty() {
            match &mut self.state {
                Part::Audio(left) => {
                    let taken = (*left).min(chunk.len());
                    audio.extend_from_slice(&chunk[..taken]);
                    chunk = &chunk[taken..];
                    *left -= taken;
                    if *left == 0 {
                        self.state = Part::Length;
                    }
                }
                Part::Length => {
                    let length = usize::from(chunk[0]) * 16;
                    chunk = &chunk[1..];
                    self.state = match length {
                        0 => Part::Audio(every),
                        _ => Part::Meta(length, Vec::with_capacity(length)),
                    };
                }
                Part::Meta(left, meta) => {
                    let taken = (*left).min(chunk.len());
                    meta.extend_from_slice(&chunk[..taken]);
                    chunk = &chunk[taken..];
                    *left -= taken;
                    if *left == 0 {
                        if let Some(title) = title(meta) {
                            found = Some(title);
                        }
                        self.state = Part::Audio(every);
                    }
                }
            }
        }
        found
    }
}

/// The song in a metadata block: what `StreamTitle='…';` holds, or empty for a block that clears
/// it.
fn title(meta: &[u8]) -> Option<String> {
    const KEY: &[u8] = b"StreamTitle='";
    let start = meta.windows(KEY.len()).position(|window| window == KEY)? + KEY.len();
    let rest = &meta[start..];
    let end = rest
        .windows(2)
        .position(|window| window == b"';")
        .unwrap_or(rest.len());
    Some(String::from_utf8_lossy(&rest[..end]).trim().to_owned())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A stream with metadata every 4 bytes: audio, a length byte, then the block padded to 16.
    fn interleaved(title: &str) -> Vec<u8> {
        let mut block = format!("StreamTitle='{title}';").into_bytes();
        block.resize(block.len().div_ceil(16) * 16, 0);
        let mut stream = b"abcd".to_vec();
        stream.push((block.len() / 16) as u8);
        stream.extend(block);
        stream.extend(b"efgh");
        stream.push(0);
        stream.extend(b"ij");
        stream
    }

    #[test]
    fn metadata_is_taken_out_of_the_audio_and_its_title_read() {
        let mut icy = Icy::every(Some(4));
        let mut audio = Vec::new();
        let title = icy.feed(&interleaved("Artist - Song"), &mut audio);
        assert_eq!(audio, b"abcdefghij");
        assert_eq!(title.as_deref(), Some("Artist - Song"));
    }

    #[test]
    fn metadata_split_across_chunks_still_reads() {
        let stream = interleaved("Björk - Jóga");
        let mut icy = Icy::every(Some(4));
        let mut audio = Vec::new();
        let mut titles = Vec::new();
        for piece in stream.chunks(3) {
            titles.extend(icy.feed(piece, &mut audio));
        }
        assert_eq!(audio, b"abcdefghij");
        assert_eq!(titles, ["Björk - Jóga"]);
    }

    #[test]
    fn a_stream_without_metadata_passes_through() {
        let mut icy = Icy::every(None);
        let mut audio = Vec::new();
        assert_eq!(icy.feed(b"\x00\x05raw", &mut audio), None);
        assert_eq!(audio, b"\x00\x05raw");
    }

    #[test]
    fn titles_are_read_from_their_block() {
        assert_eq!(
            title(b"StreamTitle='It''s Me';StreamUrl='';\0\0").as_deref(),
            Some("It''s Me")
        );
        assert_eq!(title(b"StreamTitle='';\0").as_deref(), Some(""));
        assert_eq!(title(b"StreamUrl='x';"), None);
    }

    #[test]
    fn the_pipe_reads_across_chunks_and_ends_with_the_stream() {
        let (chunks, mut live) = Live::pipe();
        chunks.send(Bytes::from_static(b"abc")).unwrap();
        chunks.send(Bytes::from_static(b"de")).unwrap();
        drop(chunks);
        let mut read = Vec::new();
        live.read_to_end(&mut read).unwrap();
        assert_eq!(read, b"abcde");
        assert_eq!(live.seek(SeekFrom::Current(0)).unwrap(), 5);
    }

    #[test]
    fn the_pipe_cannot_seek() {
        let (_chunks, mut live) = Live::pipe();
        assert!(live.seek(SeekFrom::Start(10)).is_err());
        assert!(live.seek(SeekFrom::End(0)).is_err());
        assert_eq!(live.seek(SeekFrom::Start(0)).unwrap(), 0);
    }

    #[test]
    fn streams_are_named_by_their_type() {
        assert_eq!(encoding("audio/mpeg", 128), Encoding::Mp3 { kbps: 128 });
        assert_eq!(encoding("audio/aacp", 64), Encoding::Aac { kbps: 64 });
        assert_eq!(encoding("application/ogg", 0), Encoding::Other);
    }

    #[test]
    fn a_title_is_only_shown_for_its_own_station() {
        let factory = Factory::new(RadioBrowser::new());
        *factory.now.lock().unwrap() = Some(("one".to_owned(), "Song".to_owned()));
        assert_eq!(factory.now_playing("one").as_deref(), Some("Song"));
        assert_eq!(factory.now_playing("two"), None);
    }

    /// Plays a well-known station through the decoder for a moment: proves the live pipe, the
    /// codec and the titles end to end. Needs the network.
    #[tokio::test]
    #[ignore]
    async fn live_a_station_decodes_from_the_pipe() {
        use rodio::Source as _;
        let browser = RadioBrowser::new();
        let station = browser
            .search(&super::super::Query {
                name: Some("Radio Paradise".to_owned()),
                ..Default::default()
            })
            .await
            .unwrap()
            .into_iter()
            .next()
            .unwrap();
        let radio = Radio {
            browser,
            http: reqwest::Client::new(),
            now: NowPlaying::default(),
            vault: None,
        };
        let loaded = radio.load(&station.id).await.unwrap();
        let id = station.id.clone();
        let decoded = tokio::task::spawn_blocking(move || {
            let decoder = radio.open(&id, &loaded, Duration::ZERO).expect("decodes");
            let (rate, channels) = (decoder.sample_rate().get(), decoder.channels().get());
            let samples = decoder.take(rate as usize * channels as usize).count();
            (rate, channels, samples, radio.now.lock().unwrap().clone())
        })
        .await
        .unwrap();
        println!("{}: {decoded:?}", station.name);
        assert!(decoded.2 > 0);
    }
}
