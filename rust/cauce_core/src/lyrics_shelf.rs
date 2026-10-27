//! Lyrics kept on disk for downloaded tracks, so they show offline, and the order the listener
//! puts the lyrics sources in.

use std::path::{Path, PathBuf};

use music::Lyrics;

/// The lyrics services in each group the listener orders: the providers' own, the signed-in
/// Subsonic server, LRCLIB, and `.lrc` files beside local tracks.
const GROUPS: [(&str, &[&str]); 4] = [
    (
        "provider",
        &[
            "YouTube Music",
            "Apple Music",
            "Musixmatch",
            "Kugou",
            "NetEase",
        ],
    ),
    ("server", &["Subsonic"]),
    ("lrclib", &["LrcLib"]),
    ("lrc", &[music::lyrics::LOCAL]),
];

/// The lyrics services in the order of `groups`; unknown groups are skipped.
pub fn sources(groups: &[String]) -> Vec<String> {
    groups
        .iter()
        .filter_map(|group| GROUPS.iter().find(|(name, _)| name == group))
        .flat_map(|(_, services)| services.iter().map(|service| (*service).to_owned()))
        .collect()
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

    #[test]
    fn groups_expand_in_the_order_given_and_unknown_ones_are_skipped() {
        let order = ["lrclib", "nope", "server", "lrc", "provider"].map(String::from);
        let services = sources(&order);
        assert_eq!(services[0], "LrcLib");
        assert_eq!(services[1], "Subsonic");
        assert_eq!(services[2], music::lyrics::LOCAL);
        assert_eq!(services[3], "YouTube Music");
        assert_eq!(services.len(), 8);
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
        let runtime = tokio::runtime::Builder::new_current_thread().build().unwrap();
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
        shelf.keep("youtube", "a/b?c", &lyrics);
        assert_eq!(shelf.get("youtube", "a/b?c"), Some(lyrics));
        assert_eq!(shelf.get("deezer", "a/b?c"), None);
        shelf.drop("youtube", "a/b?c");
        assert_eq!(shelf.get("youtube", "a/b?c"), None);
        std::fs::remove_dir_all(folder).ok();
    }
}
