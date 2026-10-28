//! Playlists of the listener's own, kept on the phone. Making a playlist on Audius takes an
//! Audius account, so Cauce keeps its own in `playlists.json`, newest first, each with the
//! tracks it holds in order. A track keeps its title and artist as they were when it went in,
//! to show it by when Audius no longer lists it.

use std::collections::{HashMap, HashSet};
use std::path::Path;

use anyhow::{Context as _, Result};
use serde::{Deserialize, Serialize};

use super::likes::{now, write};
use crate::{Playlist, Track};

const FILE: &str = "playlists.json";
/// What sets an own playlist's id apart from an Audius one, which is letters and digits only.
const PREFIX: &str = "cauce-";

/// Whether `id` names one of the listener's own playlists rather than one on Audius.
pub(crate) fn is_own(id: &str) -> bool {
    id.starts_with(PREFIX)
}

#[derive(Clone, Serialize, Deserialize)]
pub(crate) struct Own {
    pub id: String,
    pub name: String,
    #[serde(default)]
    pub modified_at: Option<i64>,
    #[serde(default)]
    pub tracks: Vec<Track>,
}

impl Own {
    /// The playlist as a list shows it, its cover the first of `tracks` that has one.
    pub fn playlist(&self, tracks: &[Track]) -> Playlist {
        Playlist {
            id: self.id.clone(),
            name: self.name.clone(),
            owner: String::new(),
            owner_id: String::new(),
            owned: true,
            collaborative: false,
            blend: false,
            public: false,
            cover: tracks.iter().find_map(|track| track.cover.clone()),
            track_count: tracks.len() as u32,
            modified_at: self.modified_at,
        }
    }
}

#[derive(Default, Serialize, Deserialize)]
pub(crate) struct Playlists {
    #[serde(default)]
    pub list: Vec<Own>,
}

impl Playlists {
    /// The playlists in `folder`, or none when there is no file or it does not read.
    pub fn load(folder: &Path) -> Self {
        let Ok(bytes) = std::fs::read(folder.join(FILE)) else {
            return Self::default();
        };
        serde_json::from_slice(&bytes)
            .inspect_err(|error| log::warn!("audius: the playlists do not read: {error}"))
            .unwrap_or_default()
    }

    pub fn save(&self, folder: &Path) -> Result<()> {
        let bytes = serde_json::to_vec(self).context("cannot serialize the audius playlists")?;
        write(folder, FILE, &bytes)
    }

    pub fn get(&self, id: &str) -> Result<&Own> {
        self.list
            .iter()
            .find(|own| own.id == id)
            .context("that playlist is gone")
    }

    fn get_mut(&mut self, id: &str) -> Result<&mut Own> {
        let own = self
            .list
            .iter_mut()
            .find(|own| own.id == id)
            .context("that playlist is gone")?;
        own.modified_at = now();
        Ok(own)
    }

    /// Makes an empty playlist called `name`, first in the list, and answers its id.
    pub fn create(&mut self, name: &str) -> String {
        let id = loop {
            let id = format!("{PREFIX}{:016x}", fastrand::u64(..));
            if self.get(&id).is_err() {
                break id;
            }
        };
        self.list.insert(
            0,
            Own {
                id: id.clone(),
                name: name.to_owned(),
                modified_at: now(),
                tracks: Vec::new(),
            },
        );
        id
    }

    pub fn rename(&mut self, id: &str, name: &str) -> Result<()> {
        self.get_mut(id)?.name = name.to_owned();
        Ok(())
    }

    pub fn delete(&mut self, id: &str) -> Result<()> {
        self.get(id)?;
        self.list.retain(|own| own.id != id);
        Ok(())
    }

    /// Adds `tracks` to the end in order, a track named twice going in twice.
    pub fn add(&mut self, id: &str, tracks: Vec<Track>) -> Result<()> {
        let added_at = now();
        let own = self.get_mut(id)?;
        own.tracks
            .extend(tracks.into_iter().map(|track| Track { added_at, ..track }));
        Ok(())
    }

    /// Takes out the `copy`-th entry of `track_id` (from 0), leaving its other copies.
    pub fn remove(&mut self, id: &str, track_id: &str, copy: usize) -> Result<()> {
        let own = self.get_mut(id)?;
        let ids = own
            .tracks
            .iter()
            .map(|track| track.id.as_deref().unwrap_or_default());
        let index =
            crate::entry_index(ids, track_id, copy).context("track is not in the playlist")?;
        own.tracks.remove(index);
        Ok(())
    }
}

/// The `stored` tracks as Audius lists them now: each one `fetched` holds read afresh, and one
/// it was `asked` for but left out, as gone or withdrawn, shown by what was stored and
/// unplayable. One not asked for, as when Audius could not be reached, stays as stored.
pub(crate) fn refreshed(
    stored: &[Track],
    fetched: &HashMap<String, Track>,
    asked: &HashSet<String>,
) -> Vec<Track> {
    stored
        .iter()
        .map(|kept| {
            let id = kept.id.clone().unwrap_or_default();
            match fetched.get(&id) {
                Some(fresh) => Track {
                    added_at: kept.added_at,
                    ..fresh.clone()
                },
                None if asked.contains(&id) => Track {
                    playable: false,
                    ..kept.clone()
                },
                None => kept.clone(),
            }
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use super::*;

    fn track(id: &str) -> Track {
        Track {
            id: Some(id.to_owned()),
            name: format!("Song {id}"),
            playable: true,
            artists: format!("Artist {id}"),
            artist_refs: Vec::new(),
            album: String::new(),
            album_id: None,
            cover: Some(format!("https://art/{id}")),
            duration: Duration::from_secs(60),
            added_at: None,
            added_by: None,
            playcount: None,
            popularity: 0,
            explicit: false,
            track_number: 0,
            disc_number: 1,
            tags: Vec::new(),
            languages: Vec::new(),
            credits: Vec::new(),
        }
    }

    fn ids(own: &Own) -> Vec<&str> {
        own.tracks
            .iter()
            .map(|track| track.id.as_deref().unwrap())
            .collect()
    }

    #[test]
    fn a_new_playlist_is_empty_owned_and_listed_first() {
        let mut playlists = Playlists::default();
        let first = playlists.create("First");
        let second = playlists.create("Second");
        assert!(is_own(&first) && is_own(&second));
        assert_ne!(first, second);
        assert!(!is_own("D7KyD"));
        let names: Vec<&str> = playlists.list.iter().map(|own| own.name.as_str()).collect();
        assert_eq!(names, ["Second", "First"]);
        let shown = playlists.get(&first).unwrap().playlist(&[]);
        assert!(shown.owned);
        assert_eq!(shown.track_count, 0);
        assert_eq!(shown.cover, None);
    }

    #[test]
    fn a_playlist_made_with_a_first_track_holds_it_and_takes_its_cover() {
        let mut playlists = Playlists::default();
        let id = playlists.create("Mix");
        playlists.add(&id, vec![track("a")]).unwrap();
        let own = playlists.get(&id).unwrap();
        assert_eq!(ids(own), ["a"]);
        assert!(own.tracks[0].added_at.is_some());
        let shown = own.playlist(&own.tracks);
        assert_eq!(shown.track_count, 1);
        assert_eq!(shown.cover.as_deref(), Some("https://art/a"));
    }

    #[test]
    fn renaming_and_deleting_touch_only_that_playlist() {
        let mut playlists = Playlists::default();
        let kept = playlists.create("Kept");
        let gone = playlists.create("Gone");
        playlists.rename(&kept, "Renamed").unwrap();
        assert_eq!(playlists.get(&kept).unwrap().name, "Renamed");
        playlists.delete(&gone).unwrap();
        assert!(playlists.get(&gone).is_err());
        assert_eq!(playlists.list.len(), 1);
        assert!(playlists.rename(&gone, "Back").is_err());
        assert!(playlists.delete(&gone).is_err());
    }

    #[test]
    fn tracks_go_in_at_the_end_in_order_and_twice_when_named_twice() {
        let mut playlists = Playlists::default();
        let id = playlists.create("Mix");
        playlists.add(&id, vec![track("a"), track("b")]).unwrap();
        playlists.add(&id, vec![track("c"), track("a")]).unwrap();
        assert_eq!(ids(playlists.get(&id).unwrap()), ["a", "b", "c", "a"]);
        assert!(playlists.add("cauce-missing", vec![track("a")]).is_err());
    }

    #[test]
    fn removing_a_copy_takes_out_that_copy_only() {
        let mut playlists = Playlists::default();
        let id = playlists.create("Mix");
        let mut second_a = track("a");
        second_a.name = "Second copy".to_owned();
        playlists
            .add(&id, vec![track("a"), track("b"), second_a, track("a")])
            .unwrap();
        playlists.remove(&id, "a", 1).unwrap();
        let own = playlists.get(&id).unwrap();
        assert_eq!(ids(own), ["a", "b", "a"]);
        assert!(own.tracks.iter().all(|track| track.name != "Second copy"));
        assert!(playlists.remove(&id, "a", 5).is_err());
        assert!(playlists.remove(&id, "z", 0).is_err());
    }

    #[test]
    fn playlists_survive_a_save() {
        let folder = tempfile::tempdir().unwrap();
        let mut playlists = Playlists::default();
        let id = playlists.create("Mix");
        playlists.add(&id, vec![track("a"), track("a")]).unwrap();
        playlists.save(folder.path()).unwrap();
        let read = Playlists::load(folder.path());
        let own = read.get(&id).unwrap();
        assert_eq!(own.name, "Mix");
        assert_eq!(ids(own), ["a", "a"]);
        assert_eq!(own.tracks[0].name, "Song a");
    }

    #[test]
    fn a_missing_or_broken_file_is_no_playlists() {
        let folder = tempfile::tempdir().unwrap();
        assert!(Playlists::load(folder.path()).list.is_empty());
        std::fs::write(folder.path().join(FILE), b"{nope").unwrap();
        assert!(Playlists::load(folder.path()).list.is_empty());
    }

    #[test]
    fn a_track_audius_no_longer_lists_shows_as_stored_and_unplayable() {
        let stored = vec![track("a"), track("gone"), track("offline")];
        let mut fresh = track("a");
        fresh.name = "Renamed on Audius".to_owned();
        fresh.playable = false;
        let fetched = HashMap::from([("a".to_owned(), fresh)]);
        let asked = HashSet::from(["a".to_owned(), "gone".to_owned()]);
        let tracks = refreshed(&stored, &fetched, &asked);
        assert_eq!(tracks[0].name, "Renamed on Audius");
        assert!(!tracks[0].playable);
        assert_eq!(tracks[1].name, "Song gone");
        assert_eq!(tracks[1].artists, "Artist gone");
        assert!(!tracks[1].playable);
        assert_eq!(tracks[2].name, "Song offline");
        assert!(tracks[2].playable);
    }
}
