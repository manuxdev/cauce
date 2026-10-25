//! The list of downloaded tracks and the queue that fills it. The audio itself lives in the
//! vault, where a provider's player puts it; this only remembers which tracks were asked for, in
//! what order, and how each one went.

use std::collections::VecDeque;
use std::path::{Path, PathBuf};

use music::Track;
use serde::{Deserialize, Serialize};

pub const FILE: &str = "downloads.json";

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

#[derive(Debug, Default)]
pub struct Downloads {
    entries: Vec<Entry>,
    queue: VecDeque<(String, String)>,
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
        Self { entries, queue }
    }

    pub fn save(&self, folder: &Path) {
        match serde_json::to_string(&self.entries) {
            Ok(text) => {
                if let Err(error) = std::fs::write(path(folder), text) {
                    log::warn!("downloads: cannot save the list: {error}");
                }
            }
            Err(error) => log::warn!("downloads: cannot encode the list: {error}"),
        }
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
            })
            .map(|entry| (entry.source.clone(), entry.id.clone()))
            .collect()
    }

    /// Takes a track off the list; answers whether it was there.
    pub fn remove(&mut self, source: &str, id: &str) -> bool {
        let before = self.entries.len();
        self.entries
            .retain(|entry| !(entry.source == source && entry.id == id));
        self.entries.len() != before
    }

    pub fn clear(&mut self) {
        self.entries.clear();
        self.queue.clear();
    }

    pub fn running(&self) -> bool {
        self.entries
            .iter()
            .any(|entry| matches!(entry.state(), State::Queued | State::Running))
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_a_finished_download_is_kept() {
        let mut downloads = Downloads::default();
        downloads.add("deezer", track("a"));
        downloads.add("deezer", track("b"));
        downloads.finished("deezer", "a", true);
        assert!(downloads.kept("deezer", "a"));
        assert!(!downloads.kept("deezer", "b"));
        assert!(!downloads.kept("youtube", "a"));
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
        downloads.add("deezer", track("1"));
        downloads.add("deezer", track("1"));
        assert_eq!(downloads.entries().len(), 1);
        assert_eq!(
            downloads.next(),
            Some(("deezer".to_owned(), "1".to_owned()))
        );
        assert_eq!(downloads.next(), None);
    }

    #[test]
    fn no_more_than_two_run_at_once() {
        let mut downloads = Downloads::default();
        for id in ["1", "2", "3"] {
            downloads.add("deezer", track(id));
        }
        assert!(downloads.next().is_some());
        assert!(downloads.next().is_some());
        assert_eq!(downloads.next(), None);
        downloads.finished("deezer", "1", true);
        assert_eq!(
            downloads.next(),
            Some(("deezer".to_owned(), "3".to_owned()))
        );
    }

    #[test]
    fn a_failed_download_can_be_asked_for_again() {
        let mut downloads = Downloads::default();
        downloads.add("deezer", track("1"));
        downloads.next();
        downloads.finished("deezer", "1", false);
        assert_eq!(downloads.get("deezer", "1").unwrap().state(), State::Failed);
        downloads.add("deezer", track("1"));
        assert_eq!(
            downloads.next(),
            Some(("deezer".to_owned(), "1".to_owned()))
        );
    }

    #[test]
    fn a_provider_not_signed_in_keeps_its_place() {
        let mut downloads = Downloads::default();
        downloads.add("youtube", track("y"));
        downloads.add("deezer", track("d"));
        assert_eq!(
            downloads.next_ready(|source| source == "deezer"),
            Some(("deezer".to_owned(), "d".to_owned()))
        );
        assert_eq!(downloads.next_ready(|source| source == "deezer"), None);
        assert_eq!(
            downloads.next(),
            Some(("youtube".to_owned(), "y".to_owned()))
        );
    }

    #[test]
    fn a_removed_track_is_skipped_in_the_queue() {
        let mut downloads = Downloads::default();
        downloads.add("deezer", track("1"));
        assert!(downloads.remove("deezer", "1"));
        assert_eq!(downloads.next(), None);
        assert!(!downloads.running());
    }

    const DAY: u64 = 24 * 60 * 60;

    fn downloaded(downloads: &mut Downloads, id: &str, at: u64) {
        downloads.add("deezer", track(id));
        downloads.next();
        downloads.finished_at("deezer", id, true, at);
    }

    #[test]
    fn a_download_left_unplayed_too_long_goes_stale() {
        let mut downloads = Downloads::default();
        downloaded(&mut downloads, "old", 0);
        downloaded(&mut downloads, "new", 80 * DAY);
        assert_eq!(
            downloads.stale(91 * DAY, 90 * DAY),
            vec![("deezer".to_owned(), "old".to_owned())]
        );
    }

    #[test]
    fn playing_a_download_keeps_it_fresh() {
        let mut downloads = Downloads::default();
        downloaded(&mut downloads, "1", 0);
        downloads.played("deezer", "1", 50 * DAY);
        assert!(downloads.stale(100 * DAY, 90 * DAY).is_empty());
        assert_eq!(downloads.stale(141 * DAY, 90 * DAY).len(), 1);
    }

    #[test]
    fn unfinished_or_undated_downloads_never_go_stale() {
        let mut downloads = Downloads::default();
        downloads.add("deezer", track("queued"));
        downloaded(&mut downloads, "undated", 0);
        downloads.entry_mut("deezer", "undated").unwrap().played_at = None;
        assert!(downloads.stale(1000 * DAY, 90 * DAY).is_empty());
    }

    #[test]
    fn unfinished_downloads_queue_again_after_a_load() {
        let folder = std::env::temp_dir().join(format!("cauce-downloads-{}", std::process::id()));
        std::fs::create_dir_all(&folder).unwrap();
        let mut downloads = Downloads::default();
        downloads.add("deezer", track("done"));
        downloads.add("deezer", track("half"));
        downloads.next();
        downloads.next();
        downloads.finished("deezer", "done", true);
        downloads.save(&folder);
        let mut loaded = Downloads::load(&folder);
        assert_eq!(loaded.get("deezer", "done").unwrap().state(), State::Done);
        assert_eq!(
            loaded.next(),
            Some(("deezer".to_owned(), "half".to_owned()))
        );
        std::fs::remove_dir_all(&folder).ok();
    }
}
