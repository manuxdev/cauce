//! Lyrics kept on disk for downloaded tracks, so they show offline, and the order the listener
//! puts the lyrics sources in.

use std::path::{Path, PathBuf};

use music::Lyrics;

/// The lyrics services in each group the listener orders: `.lrc` files beside local tracks, the
/// signed-in Subsonic, Jellyfin or Emby server, and LRCLIB.
const GROUPS: [(&str, &[&str]); 3] = [
    ("lrc", &[music::lyrics::LOCAL]),
    ("server", &["Subsonic", "Jellyfin", "Emby"]),
    ("lrclib", &["LrcLib"]),
];

/// The lyrics services in the order of `groups`; unknown groups are skipped.
pub fn sources(groups: &[String]) -> Vec<String> {
    groups
        .iter()
        .filter_map(|group| GROUPS.iter().find(|(name, _)| name == group))
        .flat_map(|(_, services)| services.iter().map(|service| (*service).to_owned()))
        .collect()
}

/// The lyrics to show out of every service's `hits`. Synced lyrics win over plain ones whatever
/// their source, and `priority` (from [`sources`]) only decides between two of the same kind. A
/// hit for another track, with a length off by too much, or cut well short of the track is never
/// preferred, so a poor synced hit cannot beat a good plain one.
pub fn pick(
    query: &music::LyricsQuery,
    hits: Vec<music::LyricsHit>,
    priority: &[String],
) -> Option<Lyrics> {
    let mut ranked = music::lyrics::rank_with_priority(query, hits, priority);
    music::lyrics::reshape(&mut ranked);
    ranked
        .into_iter()
        .find(|hit| !hit.instrumental)
        .map(|hit| hit.lyrics)
}

/// One file of lyrics per downloaded track.
pub struct Shelf {
    folder: PathBuf,
}

impl Shelf {
    pub fn at(folder: PathBuf) -> Self {
        Self { folder }
    }

    pub fn get(&self, source: &str, id: &str) -> Option<Lyrics> {
        let text = std::fs::read_to_string(self.path(source, id)).ok()?;
        serde_json::from_str(&text).ok()
    }

    pub fn keep(&self, source: &str, id: &str, lyrics: &Lyrics) {
        let write = || -> std::io::Result<()> {
            std::fs::create_dir_all(&self.folder)?;
            std::fs::write(self.path(source, id), serde_json::to_vec(lyrics)?)
        };
        if let Err(error) = write() {
            log::warn!("lyrics: cannot keep them for offline: {error}");
        }
    }

    pub fn drop(&self, source: &str, id: &str) {
        std::fs::remove_file(self.path(source, id)).ok();
    }

    pub fn clear(&self) {
        std::fs::remove_dir_all(&self.folder).ok();
    }

    /// Ids can hold any character, so the file is named after a stable hash of source and id.
    fn path(&self, source: &str, id: &str) -> PathBuf {
        // FNV-1a: unlike the std hasher, it stays the same across Rust releases.
        let hash = source
            .bytes()
            .chain([0])
            .chain(id.bytes())
            .fold(0xcbf2_9ce4_8422_2325_u64, |hash, byte| {
                (hash ^ u64::from(byte)).wrapping_mul(0x0100_0000_01b3)
            });
        Path::new(&self.folder).join(format!("{hash:016x}.json"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn query() -> music::LyricsQuery {
        music::LyricsQuery {
            title: "High tide".into(),
            artist: "Someone".into(),
            album: None,
            duration: std::time::Duration::from_secs(200),
            track: None,
        }
    }

    fn hit(source: &'static str, synced: bool) -> music::LyricsHit {
        let lyrics = match synced {
            true => Lyrics::Synced {
                lines: vec![music::LyricsLine {
                    start: std::time::Duration::ZERO,
                    end: Some(std::time::Duration::from_secs(198)),
                    text: format!("{source} sings"),
                    romanized: None,
                    words: None,
                    secondary: Vec::new(),
                    voice: music::Voice::Lead,
                }]
                .into(),
            },
            false => Lyrics::plain(format!("{source} sings")),
        };
        music::LyricsHit {
            source,
            trust: 0,
            lyrics,
            instrumental: false,
            title: "High tide".into(),
            artist: "Someone".into(),
            album: None,
            duration: Some(std::time::Duration::from_secs(200)),
            writers: Vec::new(),
        }
    }

    fn picked(hits: Vec<music::LyricsHit>) -> Option<Lyrics> {
        pick(
            &query(),
            hits,
            &sources(&["server", "lrclib"].map(String::from)),
        )
    }

    #[test]
    fn synced_lyrics_from_a_later_group_beat_plain_ones_from_an_earlier_group() {
        let found = picked(vec![hit("Subsonic", false), hit("LrcLib", true)]);
        assert_eq!(found, Some(hit("LrcLib", true).lyrics));
    }

    #[test]
    fn the_group_order_decides_between_two_synced_sheets() {
        let found = picked(vec![hit("LrcLib", true), hit("Subsonic", true)]);
        assert_eq!(found, Some(hit("Subsonic", true).lyrics));
    }

    #[test]
    fn the_group_order_decides_between_two_plain_sheets() {
        let found = picked(vec![hit("LrcLib", false), hit("Subsonic", false)]);
        assert_eq!(found, Some(hit("Subsonic", false).lyrics));
    }

    #[test]
    fn a_synced_sheet_for_another_recording_does_not_beat_a_plain_match() {
        let mut longer = hit("LrcLib", true);
        longer.duration = Some(std::time::Duration::from_secs(260));
        let found = picked(vec![hit("Subsonic", false), longer]);
        assert_eq!(found, Some(hit("Subsonic", false).lyrics));
    }

    #[test]
    fn a_synced_sheet_for_another_song_does_not_beat_a_plain_match() {
        let mut other = hit("LrcLib", true);
        other.title = "Low tide".into();
        let found = picked(vec![hit("Subsonic", false), other]);
        assert_eq!(found, Some(hit("Subsonic", false).lyrics));
    }

    #[test]
    fn a_synced_sheet_cut_short_does_not_beat_a_plain_match() {
        let mut short = hit("LrcLib", true);
        if let Lyrics::Synced { lines } = &mut short.lyrics {
            let mut cut = lines.to_vec();
            cut[0].end = Some(std::time::Duration::from_secs(60));
            *lines = cut.into();
        }
        let found = picked(vec![hit("Subsonic", false), short]);
        assert_eq!(found, Some(hit("Subsonic", false).lyrics));
    }

    #[test]
    fn groups_expand_in_the_order_given_and_unknown_ones_are_skipped() {
        let order = ["lrc", "nope", "provider", "server", "lrclib"].map(String::from);
        let services = sources(&order);
        assert_eq!(
            services,
            [
                music::lyrics::LOCAL,
                "Subsonic",
                "Jellyfin",
                "Emby",
                "LrcLib"
            ]
        );
    }

    #[test]
    fn the_server_is_not_asked_for_a_track_from_elsewhere() {
        use music::LyricsProvider as _;
        let query = music::LyricsQuery {
            title: "High tide".into(),
            artist: "Someone".into(),
            album: None,
            duration: std::time::Duration::ZERO,
            track: None,
        };
        let runtime = tokio::runtime::Builder::new_current_thread()
            .build()
            .unwrap();
        let hits = runtime.block_on(music::subsonic::SubsonicLyrics::new().search(&query));
        assert!(hits.unwrap().is_empty());
    }

    #[test]
    fn kept_lyrics_read_back_per_track_until_dropped() {
        let folder = std::env::temp_dir().join(format!("cauce-lyrics-{}", std::process::id()));
        let shelf = Shelf::at(folder.clone());
        let lyrics = Lyrics::Plain {
            text: "High tide".into(),
            romanized: None,
        };
        shelf.keep("local", "a/b?c", &lyrics);
        assert_eq!(shelf.get("local", "a/b?c"), Some(lyrics));
        assert_eq!(shelf.get("subsonic", "a/b?c"), None);
        shelf.drop("local", "a/b?c");
        assert_eq!(shelf.get("local", "a/b?c"), None);
        std::fs::remove_dir_all(folder).ok();
    }
}
