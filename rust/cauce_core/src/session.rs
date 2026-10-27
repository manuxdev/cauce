//! What was playing when the app last ran: the queue, the track and how far into it, so the next
//! launch shows it in the player and picks it up on play.

use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};

use crate::queue::Repeat;
use crate::transport::{Item, Snapshot, Status};

pub const FILE: &str = "session.json";

/// How often a playing track's position is written, so a closed app comes back near where it was
/// without writing every half second.
const POSITION_EVERY: Duration = Duration::from_secs(10);

#[derive(Debug, PartialEq, Serialize, Deserialize)]
pub struct Session {
    pub items: Vec<Item>,
    pub index: usize,
    pub position_ms: u64,
    #[serde(default)]
    pub repeat: Repeat,
}

impl Session {
    pub fn of(snapshot: &Snapshot) -> Option<Self> {
        Some(Self {
            items: snapshot.items.clone(),
            index: snapshot.index?,
            position_ms: snapshot.position.as_millis() as u64,
            repeat: snapshot.repeat,
        })
    }

    pub fn position(&self) -> Duration {
        Duration::from_millis(self.position_ms)
    }

    pub fn load(folder: &Path) -> Option<Self> {
        let text = std::fs::read_to_string(path(folder)).ok()?;
        serde_json::from_str(&text).ok()
    }

    /// Removes the saved session, so nothing comes back at the next launch.
    pub fn forget(folder: &Path) {
        std::fs::remove_file(path(folder)).ok();
    }

    /// Writes beside the file and moves it in place, so a crash never leaves half a session.
    pub fn save(&self, folder: &Path) {
        let partial = folder.join(format!("{FILE}.part"));
        let written = serde_json::to_string(self)
            .map_err(std::io::Error::other)
            .and_then(|text| std::fs::write(&partial, text))
            .and_then(|()| std::fs::rename(&partial, path(folder)));
        if let Err(error) = written {
            log::warn!("session: cannot save: {error}");
        }
    }
}

/// Decides when a snapshot is worth writing: whenever the queue, the track or the status changes,
/// and every [`POSITION_EVERY`] while the position moves.
/// What, when it changes, is saved at once: the queue's order, index, status and repeat.
type Key = (Vec<String>, Option<usize>, Status, Repeat);

#[derive(Default)]
pub struct Saver {
    last: Option<Key>,
    position: Duration,
    at: Option<Instant>,
}

impl Saver {
    pub fn due(&mut self, snapshot: &Snapshot, now: Instant) -> bool {
        let key = (
            snapshot.items.iter().map(|item| item.id.clone()).collect(),
            snapshot.index,
            snapshot.status,
            snapshot.repeat,
        );
        let changed = self.last.as_ref() != Some(&key);
        let moved = snapshot.position != self.position
            && self
                .at
                .is_none_or(|at| now.duration_since(at) >= POSITION_EVERY);
        if !changed && !moved {
            return false;
        }
        self.last = Some(key);
        self.position = snapshot.position;
        self.at = Some(now);
        true
    }
}

fn path(folder: &Path) -> PathBuf {
    folder.join(FILE)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::transport::Transport;
    use music::Track;

    fn item(id: &str) -> Item {
        Item {
            source: "deezer".to_owned(),
            id: id.to_owned(),
            track: Track {
                id: Some(id.to_owned()),
                name: id.to_owned(),
                playable: true,
                artists: String::new(),
                artist_refs: Vec::new(),
                album: String::new(),
                album_id: None,
                cover: None,
                duration: Duration::from_secs(200),
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

    #[test]
    fn a_saved_session_comes_back_as_it_was() {
        let folder = std::env::temp_dir().join(format!("cauce-session-{}", std::process::id()));
        std::fs::create_dir_all(&folder).unwrap();
        let mut transport = Transport::default();
        transport.resume(
            vec![item("a"), item("b")],
            1,
            Duration::from_secs(42),
            Repeat::One,
        );
        Session::of(&transport.snapshot()).unwrap().save(&folder);
        let session = Session::load(&folder).unwrap();
        assert_eq!(session.index, 1);
        assert_eq!(session.items, vec![item("a"), item("b")]);
        assert_eq!(session.position(), Duration::from_secs(42));
        assert_eq!(session.repeat, Repeat::One);
        std::fs::remove_dir_all(&folder).ok();
    }

    #[test]
    fn nothing_queued_is_no_session() {
        assert_eq!(Session::of(&Snapshot::default()), None);
    }

    #[test]
    fn a_new_track_saves_at_once_and_a_moving_one_every_ten_seconds() {
        let mut saver = Saver::default();
        let start = Instant::now();
        let mut snapshot = Snapshot {
            items: vec![item("a")],
            index: Some(0),
            item: Some(item("a")),
            status: Status::Playing,
            ..Snapshot::default()
        };
        assert!(saver.due(&snapshot, start));
        snapshot.position = Duration::from_secs(1);
        assert!(!saver.due(&snapshot, start + Duration::from_secs(1)));
        snapshot.position = Duration::from_secs(11);
        assert!(saver.due(&snapshot, start + Duration::from_secs(11)));
        snapshot.status = Status::Paused;
        assert!(saver.due(&snapshot, start + Duration::from_secs(12)));
        assert!(!saver.due(&snapshot, start + Duration::from_secs(30)));
    }

    fn folder(name: &str) -> std::path::PathBuf {
        let folder = std::env::temp_dir().join(format!("cauce-{name}-{}", std::process::id()));
        std::fs::create_dir_all(&folder).unwrap();
        folder
    }

    #[test]
    fn a_reordered_queue_comes_back_in_its_order_paused() {
        let folder = folder("round-trip");
        let mut transport = Transport::default();
        transport.start(vec![item("a"), item("b"), item("c")], 0);
        transport.play_next(vec![item("a")]);
        transport.move_item(3, 1);
        transport.set_repeat(Repeat::All);
        transport.seek(Duration::from_secs(7));
        let saved = transport.snapshot();
        Session::of(&saved).unwrap().save(&folder);
        let session = Session::load(&folder).unwrap();
        let mut back = Transport::default();
        back.resume(
            session.items.clone(),
            session.index,
            session.position(),
            session.repeat,
        );
        let snapshot = back.snapshot();
        assert_eq!(snapshot.items, saved.items);
        assert_eq!(snapshot.index, Some(0));
        assert_eq!(snapshot.position, Duration::from_secs(7));
        assert_eq!(snapshot.repeat, Repeat::All);
        assert_eq!(snapshot.status, Status::Paused);
        std::fs::remove_dir_all(&folder).ok();
    }

    #[test]
    fn a_corrupt_session_is_no_session() {
        let folder = folder("corrupt");
        std::fs::write(folder.join(FILE), "{\"items\": [{\"source\": 1}], \"index\"").unwrap();
        assert_eq!(Session::load(&folder), None);
        std::fs::remove_dir_all(&folder).ok();
    }

    #[test]
    fn a_session_pointing_past_its_items_resumes_nothing() {
        let mut transport = Transport::default();
        transport.resume(vec![item("a")], 4, Duration::from_secs(3), Repeat::Off);
        let snapshot = transport.snapshot();
        assert!(snapshot.items.is_empty());
        assert_eq!(snapshot.status, Status::Idle);
    }

    #[test]
    fn reordering_or_shuffling_saves_at_once() {
        let mut saver = Saver::default();
        let start = Instant::now();
        let mut snapshot = Snapshot {
            items: vec![item("a"), item("b"), item("c")],
            index: Some(0),
            item: Some(item("a")),
            status: Status::Paused,
            ..Snapshot::default()
        };
        assert!(saver.due(&snapshot, start));
        snapshot.items.swap(1, 2);
        assert!(saver.due(&snapshot, start + Duration::from_secs(1)));
    }
}
