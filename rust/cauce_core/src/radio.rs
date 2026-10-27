//! Internet radio as the core sees it: the source stations play through, the rules a live
//! station follows, and the stations the listener keeps as favourites.

use std::path::Path;
use std::time::Duration;

use music::Track;
use serde::{Deserialize, Serialize};

use crate::Item;

/// The source a station plays through. It needs no account and is always there.
pub const RADIO: &str = "radio";
const FILE: &str = "radio.json";

/// Whether items of `source` are live stations: never downloaded, prefetched or scrobbled, and
/// with no length to seek in.
pub fn is_live(source: &str) -> bool {
    source == RADIO
}

/// One favourite station, with what its row shows.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Favourite {
    pub id: String,
    pub name: String,
    #[serde(default)]
    pub subtitle: String,
    #[serde(default)]
    pub cover: Option<String>,
}

impl Favourite {
    pub fn of(item: &Item) -> Self {
        Self {
            id: item.id.clone(),
            name: item.track.name.clone(),
            subtitle: item.track.artists.clone(),
            cover: item.track.cover.clone(),
        }
    }

    pub fn item(&self) -> Item {
        Item {
            source: RADIO.to_owned(),
            id: self.id.clone(),
            track: Track {
                id: Some(self.id.clone()),
                name: self.name.clone(),
                playable: true,
                artists: self.subtitle.clone(),
                artist_refs: Vec::new(),
                album: String::new(),
                album_id: None,
                cover: self.cover.clone(),
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
            },
        }
    }
}

/// The favourite stations, newest first, kept in `radio.json` in the data folder.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Favourites(Vec<Favourite>);

#[derive(Serialize, Deserialize)]
struct Saved {
    #[serde(default)]
    favourites: Vec<serde_json::Value>,
}

impl Favourites {
    /// The saved favourites. A missing or unreadable file is none, and an entry that does not
    /// read is left out rather than losing the rest.
    pub fn load(folder: &Path) -> Self {
        let saved = std::fs::read_to_string(folder.join(FILE))
            .ok()
            .and_then(|text| serde_json::from_str::<Saved>(&text).ok());
        Self(
            saved
                .map(|saved| saved.favourites)
                .unwrap_or_default()
                .into_iter()
                .filter_map(|entry| serde_json::from_value(entry).ok())
                .collect(),
        )
    }

    pub fn save(&self, folder: &Path) {
        let saved = Saved {
            favourites: self
                .0
                .iter()
                .filter_map(|favourite| serde_json::to_value(favourite).ok())
                .collect(),
        };
        let written = serde_json::to_vec_pretty(&saved)
            .map_err(anyhow::Error::from)
            .and_then(|json| Ok(std::fs::write(folder.join(FILE), json)?));
        if let Err(error) = written {
            log::warn!("radio: cannot save the favourites: {error:#}");
        }
    }

    pub fn list(&self) -> &[Favourite] {
        &self.0
    }

    pub fn contains(&self, id: &str) -> bool {
        self.0.iter().any(|favourite| favourite.id == id)
    }

    /// Adds `favourite` first, or takes it away.
    pub fn set(&mut self, favourite: Favourite, on: bool) {
        self.0.retain(|kept| kept.id != favourite.id);
        if on {
            self.0.insert(0, favourite);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn folder(name: &str) -> std::path::PathBuf {
        let folder =
            std::env::temp_dir().join(format!("cauce-radio-{name}-{}", std::process::id()));
        std::fs::create_dir_all(&folder).unwrap();
        folder
    }

    fn favourite(id: &str) -> Favourite {
        Favourite {
            id: id.to_owned(),
            name: format!("{id} FM"),
            subtitle: "Spain · pop".to_owned(),
            cover: Some(format!("https://example.com/{id}.png")),
        }
    }

    #[test]
    fn favourites_read_back_as_saved_newest_first() {
        let folder = folder("saved");
        let mut favourites = Favourites::default();
        favourites.set(favourite("a"), true);
        favourites.set(favourite("b"), true);
        favourites.save(&folder);
        let loaded = Favourites::load(&folder);
        assert_eq!(loaded, favourites);
        assert_eq!(loaded.list()[0].id, "b");
        std::fs::remove_dir_all(folder).ok();
    }

    #[test]
    fn a_missing_or_corrupt_file_is_no_favourites() {
        let folder = folder("missing");
        assert!(Favourites::load(&folder).list().is_empty());
        std::fs::write(folder.join(FILE), "{not json").unwrap();
        assert!(Favourites::load(&folder).list().is_empty());
        std::fs::remove_dir_all(folder).ok();
    }

    #[test]
    fn an_old_entry_missing_fields_still_reads_and_a_broken_one_is_skipped() {
        let folder = folder("old");
        std::fs::write(
            folder.join(FILE),
            r#"{"favourites":[{"id":"a","name":"A FM"},{"name":"no id"},{"id":"b","name":"B FM","subtitle":"x","cover":null,"extra":1}]}"#,
        )
        .unwrap();
        let loaded = Favourites::load(&folder);
        let ids: Vec<&str> = loaded.list().iter().map(|kept| kept.id.as_str()).collect();
        assert_eq!(ids, ["a", "b"]);
        assert_eq!(loaded.list()[0].subtitle, "");
        assert_eq!(loaded.list()[0].cover, None);
        std::fs::remove_dir_all(folder).ok();
    }

    #[test]
    fn setting_twice_keeps_one_and_unsetting_removes_it() {
        let mut favourites = Favourites::default();
        favourites.set(favourite("a"), true);
        favourites.set(favourite("b"), true);
        favourites.set(favourite("a"), true);
        assert_eq!(favourites.list().len(), 2);
        assert_eq!(favourites.list()[0].id, "a", "set again moves it first");
        favourites.set(favourite("a"), false);
        assert!(!favourites.contains("a"));
        assert!(favourites.contains("b"));
    }

    #[test]
    fn a_favourite_plays_as_a_station_item() {
        let item = favourite("a").item();
        assert_eq!(item.source, RADIO);
        assert_eq!(item.track.duration, Duration::ZERO);
        assert_eq!(Favourite::of(&item), favourite("a"));
    }
}
