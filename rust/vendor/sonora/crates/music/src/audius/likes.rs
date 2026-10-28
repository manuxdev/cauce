//! Likes kept on the phone. Liking on Audius itself takes an Audius account, so Cauce keeps its
//! own: the tracks, albums, artists and playlists hearted here, newest first, in `likes.json`.

use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use anyhow::{Context as _, Result};
use serde::{Deserialize, Serialize};

use crate::{Album, Playlist, SavedArtist, Track};

#[derive(Default, Serialize, Deserialize)]
pub(crate) struct Likes {
    #[serde(default)]
    pub tracks: Vec<Track>,
    #[serde(default)]
    pub albums: Vec<Album>,
    #[serde(default)]
    pub artists: Vec<SavedArtist>,
    #[serde(default)]
    pub playlists: Vec<Playlist>,
}

fn path(folder: &Path) -> PathBuf {
    folder.join("likes.json")
}

fn now() -> Option<i64> {
    Some(SystemTime::now().duration_since(UNIX_EPOCH).ok()?.as_secs() as i64)
}

/// Puts `item` first, or takes every entry with its id out. Liking twice keeps one.
pub(crate) fn set<T>(list: &mut Vec<T>, id: &str, item: Option<T>, id_of: impl Fn(&T) -> &str) {
    list.retain(|kept| id_of(kept) != id);
    if let Some(item) = item {
        list.insert(0, item);
    }
}

impl Likes {
    /// The likes in `folder`, or none when there is no file or it does not read.
    pub fn load(folder: &Path) -> Self {
        let Ok(bytes) = std::fs::read(path(folder)) else {
            return Self::default();
        };
        serde_json::from_slice(&bytes)
            .inspect_err(|error| log::warn!("audius: the likes do not read: {error}"))
            .unwrap_or_default()
    }

    /// Writes the likes beside a temporary copy renamed over the old file, so a crash leaves
    /// one whole list.
    pub fn save(&self, folder: &Path) -> Result<()> {
        std::fs::create_dir_all(folder).context("cannot create the audius folder")?;
        let bytes = serde_json::to_vec(self).context("cannot serialize the audius likes")?;
        let temporary = folder.join(".likes.json.tmp");
        std::fs::write(&temporary, bytes).context("cannot write the audius likes")?;
        std::fs::rename(&temporary, path(folder)).context("cannot keep the audius likes")
    }

    pub fn track(&mut self, id: &str, track: Option<Track>) {
        let track = track.map(|track| Track {
            added_at: now(),
            ..track
        });
        set(&mut self.tracks, id, track, |kept| {
            kept.id.as_deref().unwrap_or_default()
        });
    }

    pub fn album(&mut self, id: &str, album: Option<Album>) {
        let album = album.map(|album| Album {
            added_at: now(),
            ..album
        });
        set(&mut self.albums, id, album, |kept| &kept.id);
    }

    pub fn artist(&mut self, id: &str, artist: Option<SavedArtist>) {
        let artist = artist.map(|artist| SavedArtist {
            added_at: now(),
            ..artist
        });
        set(&mut self.artists, id, artist, |kept| &kept.id);
    }

    pub fn playlist(&mut self, id: &str, playlist: Option<Playlist>) {
        set(&mut self.playlists, id, playlist, |kept| &kept.id);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn artist(id: &str) -> SavedArtist {
        SavedArtist {
            id: id.to_owned(),
            name: id.to_uppercase(),
            cover: None,
            added_at: None,
        }
    }

    #[test]
    fn a_like_goes_first_once_and_an_unlike_takes_it_out() {
        let mut likes = Likes::default();
        likes.artist("a", Some(artist("a")));
        likes.artist("b", Some(artist("b")));
        likes.artist("a", Some(artist("a")));
        let ids: Vec<&str> = likes.artists.iter().map(|kept| kept.id.as_str()).collect();
        assert_eq!(ids, ["a", "b"]);
        assert!(likes.artists[0].added_at.is_some());
        likes.artist("a", None);
        assert_eq!(likes.artists.len(), 1);
        assert_eq!(likes.artists[0].id, "b");
    }

    #[test]
    fn likes_survive_a_save_and_a_missing_file_is_no_likes() {
        let folder = tempfile::tempdir().unwrap();
        assert!(Likes::load(folder.path()).artists.is_empty());
        let mut likes = Likes::default();
        likes.artist("a", Some(artist("a")));
        likes.save(folder.path()).unwrap();
        assert_eq!(Likes::load(folder.path()).artists[0].id, "a");
    }

    #[test]
    fn a_broken_file_reads_as_no_likes() {
        let folder = tempfile::tempdir().unwrap();
        std::fs::write(folder.path().join("likes.json"), b"{nope").unwrap();
        assert!(Likes::load(folder.path()).tracks.is_empty());
    }
}
