//! The list of downloaded tracks and the queue that fills it. The audio itself lives in the
//! vault, where a provider's player puts it; this only remembers which tracks were asked for, in
//! what order, and how each one went, and the albums and playlists kept downloaded.

use std::collections::VecDeque;
use std::path::{Path, PathBuf};

use music::Track;
use serde::{Deserialize, Serialize};

pub const FILE: &str = "downloads.json";

/// The albums and playlists kept downloaded. A list from before it has none.
pub const KEPT_FILE: &str = "kept.json";

/// How many downloads run side by side.
pub const AT_ONCE: usize = 2;

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum State {
    Queued,
    Running,
    Done,
    Failed,
}

/// One track asked for, by the provider it comes from.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Entry {
    pub source: String,
    pub id: String,
    pub track: Track,
    #[serde(default)]
    pub done: bool,
    /// When it last played, or finished downloading, in seconds since the epoch.
    #[serde(default)]
    pub played_at: Option<u64>,
    /// Not kept: a download that was running when the app closed starts over.
    #[serde(skip)]
    pub state: Option<State>,
}

impl Entry {
    pub fn state(&self) -> State {
        match self.done {
            true => State::Done,
            false => self.state.unwrap_or(State::Queued),
        }
    }
}

/// An album or playlist kept downloaded: what it gains is downloaded whenever it is synced.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Collection {
    pub source: String,
    pub album: bool,
    pub id: String,
    /// Its track ids at the last sync. A track that left it is no longer held back from going
    /// stale, nor is its download removed.
    pub tracks: Vec<String>,
    /// What it is called and its cover, for the downloads list. A collection kept before they
    /// were noted has none.
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub cover: Option<String>,
}

/// The downloaded tracks of one kept collection, or of none, each with the bytes it takes on
/// disk, and what they take together.
#[derive(Debug, PartialEq)]
pub struct Group {
    /// None for the tracks in no kept collection.
    pub collection: Option<Collection>,
    pub tracks: Vec<(Entry, u64)>,
    pub bytes: u64,
}

#[derive(Debug, Default)]
pub struct Downloads {
    entries: Vec<Entry>,
    queue: VecDeque<(String, String)>,
    collections: Vec<Collection>,
}

impl Downloads {
    /// The saved list under `folder`, with every unfinished download queued again.
    pub fn load(folder: &Path) -> Self {
        let entries: Vec<Entry> = std::fs::read_to_string(path(folder))
            .ok()
            .and_then(|text| serde_json::from_str(&text).ok())
            .unwrap_or_default();
        let queue = entries
            .iter()
            .filter(|entry| !entry.done)
            .map(|entry| (entry.source.clone(), entry.id.clone()))
            .collect();
        let collections = std::fs::read_to_string(folder.join(KEPT_FILE))
            .ok()
            .and_then(|text| serde_json::from_str(&text).ok())
            .unwrap_or_default();
        Self {
            entries,
            queue,
            collections,
        }
    }

    pub fn save(&self, folder: &Path) {
        write(&path(folder), &self.entries);
        write(&folder.join(KEPT_FILE), &self.collections);
    }

    pub fn entries(&self) -> &[Entry] {
        &self.entries
    }

    pub fn get(&self, source: &str, id: &str) -> Option<&Entry> {
        self.entries
            .iter()
            .find(|entry| entry.source == source && entry.id == id)
    }

    /// Asks for `track`. One already listed is left alone, unless it failed, which tries again.
    /// Whether the track is downloaded, so it plays from the vault with no account.
    pub fn kept(&self, source: &str, id: &str) -> bool {
        self.get(source, id).is_some_and(|entry| entry.done)
    }

    pub fn add(&mut self, source: &str, track: Track) {
        // A live station never arrives whole, so there is nothing to keep.
        if crate::radio::is_live(source) {
            return;
        }
        let Some(id) = track.id.clone() else {
            return;
        };
        if let Some(entry) = self.entry_mut(source, &id) {
            if entry.state() != State::Failed {
                return;
            }
            entry.state = None;
        } else {
            self.entries.push(Entry {
                source: source.to_owned(),
                id: id.clone(),
                track,
                done: false,
                played_at: None,
                state: None,
            });
        }
        self.queue.push_back((source.to_owned(), id));
    }

    /// The tracks in `tracks` that are not listed yet, as keeping likes or a collection
    /// downloaded asks for. One that failed is listed: it waits to be asked for by hand.
    pub fn missing(&self, source: &str, tracks: Vec<Track>) -> Vec<Track> {
        if crate::radio::is_live(source) {
            return Vec::new();
        }
        tracks
            .into_iter()
            .filter(|track| {
                track.playable
                    && track
                        .id
                        .as_deref()
                        .is_some_and(|id| self.get(source, id).is_none())
            })
            .collect()
    }

    pub fn collections(&self) -> &[Collection] {
        &self.collections
    }

    pub fn keeps(&self, source: &str, album: bool, id: &str) -> bool {
        self.collections
            .iter()
            .any(|kept| kept.source == source && kept.album == album && kept.id == id)
    }

    /// Keeps an album or playlist downloaded, or notes the `tracks` it has now. Its name and
    /// cover stay.
    pub fn keep(&mut self, source: &str, album: bool, id: &str, tracks: Vec<String>) {
        if let Some(kept) = self.collection_mut(source, album, id) {
            kept.tracks = tracks;
            return;
        }
        self.collections.push(Collection {
            source: source.to_owned(),
            album,
            id: id.to_owned(),
            tracks,
            name: String::new(),
            cover: None,
        });
    }

    /// Notes what a kept collection is called and its cover.
    pub fn title(&mut self, source: &str, album: bool, id: &str, name: &str, cover: Option<&str>) {
        if let Some(kept) = self.collection_mut(source, album, id) {
            kept.name = name.to_owned();
            kept.cover = cover.map(str::to_owned);
        }
    }

    /// Stops keeping a collection and takes its tracks off the list, but for those another
    /// kept collection holds, so its next sync does not fetch them again, and those `spared`
    /// names, such as likes kept downloaded. Answers the ids taken off.
    pub fn drop_collection(
        &mut self,
        source: &str,
        album: bool,
        id: &str,
        spared: &[String],
    ) -> Vec<String> {
        let Some(at) = self
            .collections
            .iter()
            .position(|kept| kept.source == source && kept.album == album && kept.id == id)
        else {
            return Vec::new();
        };
        let dropped = self.collections.remove(at);
        let gone: Vec<String> = dropped
            .tracks
            .into_iter()
            .filter(|track| {
                !spared.contains(track)
                    && !self
                        .collections
                        .iter()
                        .any(|kept| kept.source == source && kept.tracks.contains(track))
            })
            .collect();
        gone.into_iter()
            .filter(|track| self.remove(source, track))
            .collect()
    }

    /// The finished downloads by kept collection, largest first, then those in none, with what
    /// `size` says each takes. A track in two collections is listed in both and counted once in
    /// the total that comes with them.
    pub fn groups(&self, size: impl Fn(&Entry) -> u64) -> (Vec<Group>, u64) {
        let done: Vec<(&Entry, u64)> = self
            .entries
            .iter()
            .filter(|entry| entry.done)
            .map(|entry| (entry, size(entry)))
            .collect();
        let total = done.iter().map(|(_, bytes)| bytes).sum();
        let group = |collection: Option<&Collection>, tracks: Vec<(Entry, u64)>| Group {
            collection: collection.cloned(),
            bytes: tracks.iter().map(|(_, bytes)| bytes).sum(),
            tracks,
        };
        let mut groups: Vec<Group> = self
            .collections
            .iter()
            .map(|kept| {
                let tracks = kept
                    .tracks
                    .iter()
                    .filter_map(|track| {
                        done.iter()
                            .find(|(entry, _)| entry.source == kept.source && &entry.id == track)
                            .map(|(entry, bytes)| ((*entry).clone(), *bytes))
                    })
                    .collect();
                group(Some(kept), tracks)
            })
            .filter(|group| !group.tracks.is_empty())
            .collect();
        groups.sort_by(|a, b| b.bytes.cmp(&a.bytes));
        let others: Vec<(Entry, u64)> = done
            .iter()
            .filter(|(entry, _)| {
                !self
                    .collections
                    .iter()
                    .any(|kept| kept.source == entry.source && kept.tracks.contains(&entry.id))
            })
            .map(|(entry, bytes)| ((*entry).clone(), *bytes))
            .collect();
        if !others.is_empty() {
            groups.push(group(None, others));
        }
        (groups, total)
    }

    pub fn unkeep(&mut self, source: &str, album: bool, id: &str) {
        self.collections
            .retain(|kept| !(kept.source == source && kept.album == album && kept.id == id));
    }

    #[cfg(test)]
    pub fn next(&mut self) -> Option<(String, String)> {
        self.next_ready(|_| true)
    }

    /// The next queued download to start among the sources `ready` accepts, marked running, while
    /// fewer than [`AT_ONCE`] run. The others keep their place in the queue.
    pub fn next_ready(&mut self, ready: impl Fn(&str) -> bool) -> Option<(String, String)> {
        let running = self
            .entries
            .iter()
            .filter(|entry| matches!(entry.state(), State::Running))
            .count();
        if running >= AT_ONCE {
            return None;
        }
        // whatever is no longer queued, removed or already started, leaves the queue on the way
        self.queue.retain(|(source, id)| {
            self.entries.iter().any(|entry| {
                &entry.source == source && &entry.id == id && entry.state() == State::Queued
            })
        });
        let at = self.queue.iter().position(|(source, _)| ready(source))?;
        let (source, id) = self.queue.remove(at)?;
        self.entry_mut(&source, &id)?.state = Some(State::Running);
        Some((source, id))
    }

    /// Settles a running download, and answers whether it is still listed. One removed while it
    /// ran stays removed.
    pub fn finished(&mut self, source: &str, id: &str, ok: bool) -> bool {
        self.finished_at(source, id, ok, now())
    }

    fn finished_at(&mut self, source: &str, id: &str, ok: bool, now: u64) -> bool {
        let Some(entry) = self.entry_mut(source, id) else {
            return false;
        };
        entry.done = ok;
        entry.state = (!ok).then_some(State::Failed);
        if ok {
            entry.played_at = Some(now);
        }
        true
    }

    /// Notes that a downloaded track played at `now`; answers whether it is a download.
    pub fn played(&mut self, source: &str, id: &str, now: u64) -> bool {
        match self.entry_mut(source, id) {
            Some(entry) if entry.done => {
                entry.played_at = Some(now);
                true
            }
            _ => false,
        }
    }

    /// The finished downloads that have not played for longer than `max_age` seconds. One with
    /// no date, from before dates were kept, is left alone.
    pub fn stale(&self, now: u64, max_age: u64) -> Vec<(String, String)> {
        self.entries
            .iter()
            .filter(|entry| {
                entry.done
                    && entry
                        .played_at
                        .is_some_and(|at| now.saturating_sub(at) > max_age)
                    && !self
                        .collections
                        .iter()
                        .any(|kept| kept.source == entry.source && kept.tracks.contains(&entry.id))
            })
            .map(|entry| (entry.source.clone(), entry.id.clone()))
            .collect()
    }

    /// Takes a track off the list; answers whether it was there. A kept collection left with
    /// none of its tracks listed is no longer kept.
    pub fn remove(&mut self, source: &str, id: &str) -> bool {
        let before = self.entries.len();
        self.entries
            .retain(|entry| !(entry.source == source && entry.id == id));
        let entries = &self.entries;
        self.collections.retain(|kept| {
            kept.tracks.is_empty()
                || kept.tracks.iter().any(|track| {
                    entries
                        .iter()
                        .any(|entry| entry.source == kept.source && &entry.id == track)
                })
        });
        entries.len() != before
    }

    pub fn clear(&mut self) {
        self.entries.clear();
        self.queue.clear();
        self.collections.clear();
    }

    pub fn running(&self) -> bool {
        self.entries
            .iter()
            .any(|entry| matches!(entry.state(), State::Queued | State::Running))
    }

    fn collection_mut(&mut self, source: &str, album: bool, id: &str) -> Option<&mut Collection> {
        self.collections
            .iter_mut()
            .find(|kept| kept.source == source && kept.album == album && kept.id == id)
    }

    fn entry_mut(&mut self, source: &str, id: &str) -> Option<&mut Entry> {
        self.entries
            .iter_mut()
            .find(|entry| entry.source == source && entry.id == id)
    }
}

/// Seconds since the epoch.
pub fn now() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |since| since.as_secs())
}

fn path(folder: &Path) -> PathBuf {
    folder.join(FILE)
}

fn write(path: &Path, value: &impl Serialize) {
    match serde_json::to_string(value) {
        Ok(text) => {
            if let Err(error) = std::fs::write(path, text) {
                log::warn!("downloads: cannot save: {error}");
            }
        }
        Err(error) => log::warn!("downloads: cannot encode: {error}"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_a_finished_download_is_kept() {
        let mut downloads = Downloads::default();
        downloads.add("subsonic", track("a"));
        downloads.add("subsonic", track("b"));
        downloads.finished("subsonic", "a", true);
        assert!(downloads.kept("subsonic", "a"));
        assert!(!downloads.kept("subsonic", "b"));
        assert!(!downloads.kept("local", "a"));
    }
    #[test]
    fn a_station_is_never_listed_for_download() {
        let mut downloads = Downloads::default();
        downloads.add(crate::radio::RADIO, track("a"));
        assert!(downloads.entries().is_empty());
        assert!(downloads.missing(crate::radio::RADIO, vec![track("b")]).is_empty());
    }
    use std::time::Duration;

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

    #[test]
    fn a_track_is_listed_once() {
        let mut downloads = Downloads::default();
        downloads.add("subsonic", track("1"));
        downloads.add("subsonic", track("1"));
        assert_eq!(downloads.entries().len(), 1);
        assert_eq!(
            downloads.next(),
            Some(("subsonic".to_owned(), "1".to_owned()))
        );
        assert_eq!(downloads.next(), None);
    }

    #[test]
    fn no_more_than_two_run_at_once() {
        let mut downloads = Downloads::default();
        for id in ["1", "2", "3"] {
            downloads.add("subsonic", track(id));
        }
        assert!(downloads.next().is_some());
        assert!(downloads.next().is_some());
        assert_eq!(downloads.next(), None);
        downloads.finished("subsonic", "1", true);
        assert_eq!(
            downloads.next(),
            Some(("subsonic".to_owned(), "3".to_owned()))
        );
    }

    #[test]
    fn a_failed_download_can_be_asked_for_again() {
        let mut downloads = Downloads::default();
        downloads.add("subsonic", track("1"));
        downloads.next();
        downloads.finished("subsonic", "1", false);
        assert_eq!(
            downloads.get("subsonic", "1").unwrap().state(),
            State::Failed
        );
        downloads.add("subsonic", track("1"));
        assert_eq!(
            downloads.next(),
            Some(("subsonic".to_owned(), "1".to_owned()))
        );
    }

    #[test]
    fn a_provider_not_signed_in_keeps_its_place() {
        let mut downloads = Downloads::default();
        downloads.add("local", track("y"));
        downloads.add("subsonic", track("d"));
        assert_eq!(
            downloads.next_ready(|source| source == "subsonic"),
            Some(("subsonic".to_owned(), "d".to_owned()))
        );
        assert_eq!(downloads.next_ready(|source| source == "subsonic"), None);
        assert_eq!(downloads.next(), Some(("local".to_owned(), "y".to_owned())));
    }

    #[test]
    fn a_removed_track_is_skipped_in_the_queue() {
        let mut downloads = Downloads::default();
        downloads.add("subsonic", track("1"));
        assert!(downloads.remove("subsonic", "1"));
        assert_eq!(downloads.next(), None);
        assert!(!downloads.running());
    }

    const DAY: u64 = 24 * 60 * 60;

    fn downloaded(downloads: &mut Downloads, id: &str, at: u64) {
        downloads.add("subsonic", track(id));
        downloads.next();
        downloads.finished_at("subsonic", id, true, at);
    }

    #[test]
    fn a_download_left_unplayed_too_long_goes_stale() {
        let mut downloads = Downloads::default();
        downloaded(&mut downloads, "old", 0);
        downloaded(&mut downloads, "new", 80 * DAY);
        assert_eq!(
            downloads.stale(91 * DAY, 90 * DAY),
            vec![("subsonic".to_owned(), "old".to_owned())]
        );
    }

    #[test]
    fn playing_a_download_keeps_it_fresh() {
        let mut downloads = Downloads::default();
        downloaded(&mut downloads, "1", 0);
        downloads.played("subsonic", "1", 50 * DAY);
        assert!(downloads.stale(100 * DAY, 90 * DAY).is_empty());
        assert_eq!(downloads.stale(141 * DAY, 90 * DAY).len(), 1);
    }

    #[test]
    fn unfinished_or_undated_downloads_never_go_stale() {
        let mut downloads = Downloads::default();
        downloads.add("subsonic", track("queued"));
        downloaded(&mut downloads, "undated", 0);
        downloads
            .entry_mut("subsonic", "undated")
            .unwrap()
            .played_at = None;
        assert!(downloads.stale(1000 * DAY, 90 * DAY).is_empty());
    }

    fn unplayable(id: &str) -> Track {
        Track {
            playable: false,
            ..track(id)
        }
    }

    fn ids(tracks: &[Track]) -> Vec<&str> {
        tracks
            .iter()
            .filter_map(|track| track.id.as_deref())
            .collect()
    }

    #[test]
    fn only_likes_not_listed_yet_need_a_download() {
        let mut downloads = Downloads::default();
        downloaded(&mut downloads, "done", 0);
        downloads.add("subsonic", track("queued"));
        downloads.add("local", track("new"));
        let liked = vec![
            track("done"),
            track("queued"),
            track("new"),
            unplayable("gone"),
            Track {
                id: None,
                ..track("no-id")
            },
        ];
        assert_eq!(ids(&downloads.missing("subsonic", liked)), vec!["new"]);
    }

    #[test]
    fn a_kept_collection_needs_only_what_is_not_listed() {
        let mut downloads = Downloads::default();
        downloaded(&mut downloads, "1", 0);
        downloads.add("subsonic", track("2"));
        downloads.next();
        downloads.finished("subsonic", "2", false);
        downloads.keep(
            "subsonic",
            true,
            "album",
            vec!["1".into(), "2".into(), "3".into()],
        );
        let tracks = vec![track("1"), track("2"), track("3")];
        // a failed one waits to be asked for by hand, so a broken track is not fetched on every open
        assert_eq!(ids(&downloads.missing("subsonic", tracks)), vec!["3"]);
        assert!(downloads.keeps("subsonic", true, "album"));
        assert!(!downloads.keeps("subsonic", false, "album"));
    }

    #[test]
    fn keeping_again_takes_the_new_tracks() {
        let mut downloads = Downloads::default();
        downloads.keep("subsonic", false, "mix", vec!["1".into()]);
        downloads.keep("subsonic", false, "mix", vec!["2".into()]);
        assert_eq!(downloads.collections().len(), 1);
        assert_eq!(downloads.collections()[0].tracks, vec!["2".to_owned()]);
    }

    #[test]
    fn removing_every_download_of_a_collection_stops_keeping_it() {
        let mut downloads = Downloads::default();
        downloaded(&mut downloads, "1", 0);
        downloaded(&mut downloads, "2", 0);
        downloads.keep("subsonic", false, "mix", vec!["1".into(), "2".into()]);
        downloads.remove("subsonic", "1");
        assert!(downloads.keeps("subsonic", false, "mix"));
        downloads.remove("subsonic", "2");
        assert!(!downloads.keeps("subsonic", false, "mix"));
    }

    #[test]
    fn a_track_of_a_kept_collection_never_goes_stale() {
        let mut downloads = Downloads::default();
        downloaded(&mut downloads, "kept", 0);
        downloaded(&mut downloads, "left", 0);
        downloads.keep("subsonic", false, "mix", vec!["kept".into()]);
        assert_eq!(
            downloads.stale(91 * DAY, 90 * DAY),
            vec![("subsonic".to_owned(), "left".to_owned())]
        );
    }

    /// What each downloaded track takes in these tests: its id, read as a number of bytes.
    fn size(entry: &Entry) -> u64 {
        entry.id.parse().unwrap_or(0)
    }

    fn group_ids(group: &Group) -> Vec<&str> {
        group
            .tracks
            .iter()
            .map(|(entry, _)| entry.id.as_str())
            .collect()
    }

    #[test]
    fn downloads_group_into_kept_collections_then_the_others() {
        let mut downloads = Downloads::default();
        for id in ["10", "20", "30", "40"] {
            downloaded(&mut downloads, id, 0);
        }
        downloads.add("subsonic", track("50"));
        downloads.keep(
            "subsonic",
            true,
            "album",
            vec!["10".into(), "20".into(), "60".into()],
        );
        let (groups, _) = downloads.groups(size);
        assert_eq!(groups.len(), 2);
        let album = groups[0].collection.as_ref().unwrap();
        assert_eq!((album.album, album.id.as_str()), (true, "album"));
        // only what is on disk: one still queued or never listed is not shown
        assert_eq!(group_ids(&groups[0]), vec!["10", "20"]);
        assert!(groups[1].collection.is_none());
        assert_eq!(group_ids(&groups[1]), vec!["30", "40"]);
    }

    #[test]
    fn a_track_in_two_kept_collections_shows_in_both_and_counts_once() {
        let mut downloads = Downloads::default();
        downloaded(&mut downloads, "100", 0);
        downloaded(&mut downloads, "7", 0);
        downloads.keep("subsonic", true, "album", vec!["100".into(), "7".into()]);
        downloads.keep("subsonic", false, "mix", vec!["100".into()]);
        let (groups, total) = downloads.groups(size);
        assert_eq!(groups.len(), 2);
        assert_eq!(groups[0].bytes, 107);
        assert_eq!(groups[1].bytes, 100);
        assert_eq!(total, 107);
    }

    #[test]
    fn groups_and_their_tracks_carry_their_sizes_largest_group_first() {
        let mut downloads = Downloads::default();
        for id in ["1", "2", "300", "4000"] {
            downloaded(&mut downloads, id, 0);
        }
        downloads.keep("subsonic", false, "small", vec!["1".into(), "2".into()]);
        downloads.keep("subsonic", true, "big", vec!["300".into()]);
        let (groups, total) = downloads.groups(size);
        let names: Vec<_> = groups
            .iter()
            .map(|group| group.collection.as_ref().map(|kept| kept.id.as_str()))
            .collect();
        // the others come last whatever they take
        assert_eq!(names, vec![Some("big"), Some("small"), None]);
        assert_eq!(
            groups[1]
                .tracks
                .iter()
                .map(|(_, bytes)| *bytes)
                .collect::<Vec<_>>(),
            vec![1, 2]
        );
        assert_eq!(groups[2].bytes, 4000);
        assert_eq!(total, 4303);
    }

    #[test]
    fn a_kept_collection_with_nothing_downloaded_is_not_a_group() {
        let mut downloads = Downloads::default();
        downloads.add("subsonic", track("1"));
        downloads.keep("subsonic", true, "album", vec!["1".into()]);
        assert_eq!(downloads.groups(size), (Vec::new(), 0));
    }

    #[test]
    fn dropping_a_collection_spares_tracks_kept_otherwise() {
        let mut downloads = Downloads::default();
        for id in ["only", "shared", "liked"] {
            downloaded(&mut downloads, id, 0);
        }
        downloads.keep(
            "subsonic",
            true,
            "album",
            vec!["only".into(), "shared".into(), "liked".into()],
        );
        downloads.keep("subsonic", false, "mix", vec!["shared".into()]);
        let removed = downloads.drop_collection("subsonic", true, "album", &["liked".to_owned()]);
        assert_eq!(removed, vec!["only".to_owned()]);
        assert!(!downloads.keeps("subsonic", true, "album"));
        assert!(downloads.keeps("subsonic", false, "mix"));
        assert!(downloads.kept("subsonic", "shared"));
        assert!(downloads.kept("subsonic", "liked"));
        assert!(!downloads.kept("subsonic", "only"));
    }

    #[test]
    fn a_kept_collection_keeps_its_name_when_kept_again() {
        let mut downloads = Downloads::default();
        downloads.keep("subsonic", true, "album", vec!["1".into()]);
        downloads.title("subsonic", true, "album", "Blue", Some("cover.jpg"));
        downloads.keep("subsonic", true, "album", vec!["1".into(), "2".into()]);
        let kept = &downloads.collections()[0];
        assert_eq!(
            (kept.name.as_str(), kept.cover.as_deref()),
            ("Blue", Some("cover.jpg"))
        );
        assert_eq!(kept.tracks.len(), 2);
    }

    fn folder(name: &str) -> PathBuf {
        let folder = std::env::temp_dir().join(format!("cauce-{name}-{}", std::process::id()));
        std::fs::create_dir_all(&folder).unwrap();
        folder
    }

    #[test]
    fn kept_collections_survive_a_load() {
        let folder = folder("kept");
        let mut downloads = Downloads::default();
        downloads.keep("subsonic", true, "album", vec!["1".into()]);
        downloads.save(&folder);
        let loaded = Downloads::load(&folder);
        assert_eq!(loaded.collections(), downloads.collections());
        std::fs::remove_dir_all(&folder).ok();
    }

    #[test]
    fn a_list_from_before_kept_collections_keeps_none() {
        let folder = folder("old");
        let mut downloads = Downloads::default();
        downloaded(&mut downloads, "1", 0);
        std::fs::write(
            folder.join(FILE),
            serde_json::to_string(downloads.entries()).unwrap(),
        )
        .unwrap();
        let loaded = Downloads::load(&folder);
        assert_eq!(loaded.entries().len(), 1);
        assert!(loaded.collections().is_empty());
        std::fs::remove_dir_all(&folder).ok();
    }

    #[test]
    fn unfinished_downloads_queue_again_after_a_load() {
        let folder = std::env::temp_dir().join(format!("cauce-downloads-{}", std::process::id()));
        std::fs::create_dir_all(&folder).unwrap();
        let mut downloads = Downloads::default();
        downloads.add("subsonic", track("done"));
        downloads.add("subsonic", track("half"));
        downloads.next();
        downloads.next();
        downloads.finished("subsonic", "done", true);
        downloads.save(&folder);
        let mut loaded = Downloads::load(&folder);
        assert_eq!(loaded.get("subsonic", "done").unwrap().state(), State::Done);
        assert_eq!(
            loaded.next(),
            Some(("subsonic".to_owned(), "half".to_owned()))
        );
        std::fs::remove_dir_all(&folder).ok();
    }
}
