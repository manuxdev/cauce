//! The listener's scrobbling accounts and what a listen sends them. The app decides when a play
//! has earned its scrobble; this keeps the accounts and talks to the services.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use music::scrobble::{Account, Play};
use serde::{Deserialize, Serialize};

const FILE: &str = "scrobbling.json";

/// The services the settings list, by id, in order.
pub const SHOWN: [&str; 2] = ["lastfm", "listenbrainz"];

/// Every scrobbling account and whether local files are sent too. It holds session keys, so it
/// is never logged.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(default, rename_all = "kebab-case")]
pub struct Scrobbling {
    pub accounts: BTreeMap<String, Account>,
    pub local_files: bool,
}

impl Scrobbling {
    pub fn load(folder: &Path) -> Self {
        std::fs::read_to_string(path(folder))
            .ok()
            .and_then(|text| serde_json::from_str(&text).ok())
            .unwrap_or_default()
    }

    pub fn save(&self, folder: &Path) {
        let write = || -> anyhow::Result<()> {
            std::fs::write(path(folder), serde_json::to_vec_pretty(self)?)?;
            Ok(())
        };
        if let Err(error) = write() {
            log::warn!("scrobble: cannot save the accounts: {error}");
        }
    }

    /// The accounts a listen from `source` goes to: linked, switched on, and for a local file
    /// only when local files are sent.
    pub fn receivers(&self, source: &str) -> Vec<(String, Account)> {
        // A station is not a listen of any one song, and an episode is not a song.
        if crate::radio::is_live(source)
            || crate::podcasts::is_episode(source)
            || (source == crate::LOCAL && !self.local_files)
        {
            return Vec::new();
        }
        self.accounts
            .iter()
            .filter(|(_, account)| account.linked() && account.enabled)
            .map(|(id, account)| (id.clone(), account.clone()))
            .collect()
    }
}

/// A listen of `track` that started at `at`, or `None` when it lacks an artist or title to send.
pub fn play(track: &music::Track, at: std::time::SystemTime) -> Option<Play> {
    let artist = track
        .artists
        .split(", ")
        .next()
        .unwrap_or_default()
        .trim()
        .to_owned();
    let title = track.name.trim().to_owned();
    if artist.is_empty() || title.is_empty() {
        return None;
    }
    Some(Play {
        artist,
        title,
        album: Some(track.album.clone()).filter(|album| !album.is_empty()),
        duration: track.duration,
        at,
    })
}

fn path(folder: &Path) -> PathBuf {
    folder.join(FILE)
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use music::Track;

    use super::*;

    fn track(id: &str) -> Track {
        Track {
            id: Some(id.to_owned()),
            name: id.to_owned(),
            playable: true,
            artists: String::new(),
            artist_refs: Vec::new(),
            album: String::new(),
            album_id: None,
            cover: None,
            duration: Duration::ZERO,
            added_at: None,
            added_by: None,
            playcount: None,
            popularity: 0,
            explicit: false,
            track_number: 0,
            disc_number: 0,
            tags: Vec::new(),
            languages: Vec::new(),
            credits: Vec::new(),
        }
    }

    fn linked(enabled: bool) -> Account {
        Account {
            session: "session".into(),
            enabled,
            ..Account::default()
        }
    }

    #[test]
    fn only_linked_accounts_switched_on_receive_listens() {
        let mut scrobbling = Scrobbling::default();
        scrobbling.accounts.insert("lastfm".into(), linked(true));
        scrobbling
            .accounts
            .insert("listenbrainz".into(), linked(false));
        scrobbling
            .accounts
            .insert("maloja".into(), Account::default());
        let ids: Vec<_> = scrobbling
            .receivers("subsonic")
            .into_iter()
            .map(|(id, _)| id)
            .collect();
        assert_eq!(ids, ["lastfm"]);
    }

    #[test]
    fn local_files_are_sent_only_when_asked() {
        let mut scrobbling = Scrobbling::default();
        scrobbling.accounts.insert("lastfm".into(), linked(true));
        assert!(scrobbling.receivers(crate::LOCAL).is_empty());
        scrobbling.local_files = true;
        assert_eq!(scrobbling.receivers(crate::LOCAL).len(), 1);
    }

    #[test]
    fn a_station_is_never_scrobbled() {
        let mut scrobbling = Scrobbling {
            local_files: true,
            ..Scrobbling::default()
        };
        scrobbling.accounts.insert("lastfm".into(), linked(true));
        assert!(scrobbling.receivers(crate::radio::RADIO).is_empty());
    }

    #[test]
    fn an_episode_is_never_scrobbled() {
        let mut scrobbling = Scrobbling::default();
        scrobbling.accounts.insert("lastfm".into(), linked(true));
        assert!(scrobbling.receivers(crate::podcasts::PODCAST).is_empty());
    }

    #[test]
    fn accounts_read_back_as_saved() {
        let folder = std::env::temp_dir().join(format!("cauce-scrobbling-{}", std::process::id()));
        std::fs::create_dir_all(&folder).unwrap();
        let mut scrobbling = Scrobbling {
            local_files: true,
            ..Scrobbling::default()
        };
        scrobbling.accounts.insert("lastfm".into(), linked(true));
        scrobbling.save(&folder);
        assert_eq!(Scrobbling::load(&folder), scrobbling);
        std::fs::remove_dir_all(folder).ok();
    }

    #[test]
    fn a_play_needs_an_artist_and_a_title_and_sends_the_first_artist() {
        let mut track = track("");
        track.name = String::new();
        assert!(play(&track, std::time::SystemTime::now()).is_none());
        track.name = "Marea Alta".into();
        track.artists = "Lucía Ferrer, Bruma".into();
        let play = play(&track, std::time::SystemTime::now()).unwrap();
        assert_eq!((play.artist.as_str(), play.album), ("Lucía Ferrer", None));
    }
}
