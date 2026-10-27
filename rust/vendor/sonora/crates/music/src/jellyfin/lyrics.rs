use std::sync::Mutex;
use std::time::Duration;

use anyhow::Result;
use async_trait::async_trait;
use serde::Deserialize;

use crate::jellyfin::auth::{self, Credentials};
use crate::jellyfin::{Flavor, JellyfinClient};
use crate::lyrics::lrc;
use crate::{Lyrics, LyricsHit, LyricsLine, LyricsProvider, LyricsQuery, Voice};

/// The same tier as lyrics read from a local file, since these are most often the user's own.
const TRUST: u32 = 100;

/// How many ticks Jellyfin counts in a second.
const TICKS_PER_SECOND: u64 = 10_000_000;

/// `/Audio/{id}/Lyrics`: the lines, each with its start in ticks when the lyrics are synced.
#[derive(Default, Deserialize)]
#[serde(rename_all = "PascalCase", default)]
pub struct Answer {
    pub lyrics: Vec<Line>,
}

#[derive(Default, Deserialize)]
#[serde(rename_all = "PascalCase", default)]
pub struct Line {
    pub text: String,
    pub start: Option<u64>,
}

/// The lyrics an answer holds: synced when every line has a start, plain otherwise.
pub fn lyrics(answer: Answer) -> Option<Lyrics> {
    if answer.lyrics.is_empty() {
        return None;
    }
    if answer.lyrics.iter().all(|line| line.start.is_some()) {
        let mut lines: Vec<LyricsLine> = answer
            .lyrics
            .iter()
            .map(|line| LyricsLine {
                start: ticks(line.start.unwrap_or(0)),
                end: None,
                text: line.text.trim().to_owned(),
                romanized: None,
                words: None,
                secondary: Vec::new(),
                voice: Voice::Lead,
            })
            .collect();
        lrc::normalize(&mut lines);
        if !lines.is_empty() {
            return Some(Lyrics::Synced {
                lines: lines.into(),
            });
        }
    }
    let text = answer
        .lyrics
        .iter()
        .map(|line| line.text.as_str())
        .collect::<Vec<_>>()
        .join("\n");
    (!text.trim().is_empty()).then(|| Lyrics::plain(text))
}

/// The lyrics in Emby's subtitle text: each block's start and its lines. Synced when a line starts
/// after zero, since lyrics with no times come with every start at zero; plain otherwise.
pub fn srt(text: &str) -> Option<Lyrics> {
    let text = text.trim_start_matches('\u{feff}').replace("\r\n", "\n");
    let blocks: Vec<(Duration, String)> = text
        .split("\n\n")
        .filter_map(|block| {
            let mut lines = block.lines().skip_while(|line| !line.contains("-->"));
            let start = srt_time(lines.next()?.split("-->").next()?)?;
            Some((start, lines.collect::<Vec<_>>().join(" ").trim().to_owned()))
        })
        .collect();
    if blocks.iter().any(|(start, _)| !start.is_zero()) {
        let mut lines: Vec<LyricsLine> = blocks
            .iter()
            .map(|(start, text)| LyricsLine {
                start: *start,
                end: None,
                text: text.clone(),
                romanized: None,
                words: None,
                secondary: Vec::new(),
                voice: Voice::Lead,
            })
            .collect();
        lrc::normalize(&mut lines);
        if !lines.is_empty() {
            return Some(Lyrics::Synced {
                lines: lines.into(),
            });
        }
    }
    let text = blocks
        .into_iter()
        .map(|(_, text)| text)
        .collect::<Vec<_>>()
        .join("\n");
    (!text.trim().is_empty()).then(|| Lyrics::plain(text))
}

/// `HH:MM:SS,mmm` as a duration.
fn srt_time(text: &str) -> Option<Duration> {
    let (clock, millis) = text.trim().split_once(',')?;
    let mut parts = clock.split(':').map(|part| part.parse::<u64>().ok());
    let (hours, minutes, seconds) = (parts.next()??, parts.next()??, parts.next()??);
    Some(
        Duration::from_secs(hours * 3600 + minutes * 60 + seconds)
            + Duration::from_millis(millis.parse().ok()?),
    )
}

fn ticks(ticks: u64) -> Duration {
    Duration::from_secs(ticks / TICKS_PER_SECOND)
        + Duration::from_nanos((ticks % TICKS_PER_SECOND) * 100)
}

type Identity = (String, String, String);

/// Asks the signed-in Jellyfin or Emby server for the lyrics of one of its tracks. Any other track, or no
/// stored sign-in, gets no answer and makes no request.
pub struct JellyfinLyrics {
    flavor: Flavor,
    client: Mutex<Option<(Identity, JellyfinClient)>>,
}

impl JellyfinLyrics {
    pub fn new() -> Self {
        Self {
            flavor: Flavor::Jellyfin,
            client: Mutex::new(None),
        }
    }

    pub fn emby() -> Self {
        Self {
            flavor: Flavor::Emby,
            client: Mutex::new(None),
        }
    }

    /// A client for `stored`, kept until the credentials change. This provider has no session
    /// handle, so it reads the same file the session was restored from.
    fn client(&self, stored: Option<Credentials>) -> Result<Option<JellyfinClient>> {
        let Some(stored) = stored else {
            return Ok(None);
        };
        let identity = (
            stored.server.clone(),
            stored.user_id.clone(),
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
        let client = JellyfinClient::new(&stored)?;
        *held = Some((identity, client.clone()));
        Ok(Some(client))
    }

    async fn search_with(
        &self,
        query: &LyricsQuery,
        stored: impl FnOnce() -> Option<Credentials>,
    ) -> Result<Vec<LyricsHit>> {
        let Some(id) = query.id_for(self.flavor.slug()) else {
            return Ok(Vec::new());
        };
        let Some(client) = self.client(stored())? else {
            return Ok(Vec::new());
        };
        let found = client.server_lyrics(id).await?;
        Ok(found
            .into_iter()
            .map(|lyrics| LyricsHit {
                source: self.flavor.name(),
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

impl Default for JellyfinLyrics {
    fn default() -> Self {
        Self::new()
    }
}

#[async_trait]
impl LyricsProvider for JellyfinLyrics {
    fn name(&self) -> &'static str {
        self.flavor.name()
    }

    async fn search(&self, query: &LyricsQuery) -> Result<Vec<LyricsHit>> {
        self.search_with(query, || auth::load(self.flavor)).await
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::TrackKey;

    /// The demo's `/Audio/{id}/Lyrics` for "Thraximundar", trimmed.
    const SYNCED: &str = r#"{
        "Metadata": {},
        "Lyrics": [
            { "Text": "(Instrumental)", "Start": 0, "Cues": [] },
            { "Text": "Silent a coiled demon", "Start": 830000000, "Cues": [] },
            { "Text": "Trapped in a nightmare", "Start": 854000000, "Cues": [] }
        ]
    }"#;

    /// Lyrics from a plain text file come with no starts.
    const PLAIN: &str = r#"{
        "Metadata": {},
        "Lyrics": [{ "Text": "High tide" }, { "Text": "Low tide", "Start": null }]
    }"#;

    fn read(json: &str) -> Option<Lyrics> {
        lyrics(serde_json::from_str(json).unwrap())
    }

    #[test]
    fn lines_with_starts_become_synced_lyrics() {
        let Some(Lyrics::Synced { lines }) = read(SYNCED) else {
            panic!("expected synced lyrics");
        };
        assert_eq!(lines[1].text, "Silent a coiled demon");
        assert_eq!(lines[1].start, Duration::from_millis(83_000));
        assert_eq!(lines[2].start, Duration::from_millis(85_400));
    }

    #[test]
    fn lines_without_starts_become_plain_lyrics() {
        assert_eq!(read(PLAIN), Some(Lyrics::plain("High tide\nLow tide")));
        assert_eq!(read(r#"{"Metadata":{},"Lyrics":[]}"#), None);
    }

    /// Emby 4.10's `Stream.srt` of an `.lrc` file, with the byte order mark it sends.
    const EMBY_SYNCED: &str = "\u{feff}1\n00:00:01,000 --> 00:00:05,500\nHello line one\n\n2\n\
        00:00:05,500 --> 00:00:00,000\nSecond line here\n\n";

    /// The same of a `.txt` file: every line starts at zero.
    const EMBY_PLAIN: &str = "\u{feff}1\r\n00:00:00,000 --> 00:00:00,000\r\nPlain first line\r\n\r\n\
        2\r\n00:00:00,000 --> 00:00:00,000\r\nPlain second line\r\n\r\n";

    #[test]
    fn emby_subtitles_with_starts_become_synced_lyrics() {
        let Some(Lyrics::Synced { lines }) = srt(EMBY_SYNCED) else {
            panic!("expected synced lyrics");
        };
        assert_eq!(lines[0].text, "Hello line one");
        assert_eq!(lines[0].start, Duration::from_secs(1));
        assert_eq!(lines[1].text, "Second line here");
        assert_eq!(lines[1].start, Duration::from_millis(5_500));
    }

    #[test]
    fn emby_subtitles_all_at_zero_become_plain_lyrics() {
        assert_eq!(
            srt(EMBY_PLAIN),
            Some(Lyrics::plain("Plain first line\nPlain second line"))
        );
        assert_eq!(srt("\u{feff}"), None);
    }

    fn query(track: Option<TrackKey>) -> LyricsQuery {
        LyricsQuery {
            title: "High tide".into(),
            artist: "Someone".into(),
            album: None,
            duration: Duration::ZERO,
            track,
        }
    }

    fn credentials() -> Credentials {
        Credentials {
            // nothing listens here, so a request would fail the test
            server: "http://127.0.0.1:9".into(),
            user_id: "u".into(),
            username: "demo".into(),
            device_id: "d".into(),
            token: "t".into(),
            flavor: Flavor::Jellyfin,
        }
    }

    fn search(query: &LyricsQuery, stored: Option<Credentials>) -> Result<Vec<LyricsHit>> {
        tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap()
            .block_on(JellyfinLyrics::new().search_with(query, || stored))
    }

    #[test]
    fn a_track_from_elsewhere_gets_nothing_and_asks_nobody() {
        let elsewhere = query(Some(TrackKey {
            provider: "subsonic",
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
            provider: "jellyfin",
            id: "1".into(),
        }));
        assert!(search(&mine, None).unwrap().is_empty());
    }
}
