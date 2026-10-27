//! The playback state machine: what the listener sees, and what the engine is told next. It never
//! touches an engine itself, so every rule here runs in a test.

use std::time::Duration;

use music::{PlaybackEvent, Track};
use serde::{Deserialize, Serialize};

use crate::queue::{Back, Queue, Repeat};

/// One queued track and the provider it plays through.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Item {
    pub source: String,
    pub id: String,
    pub track: Track,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum Status {
    #[default]
    Idle,
    Loading,
    Playing,
    Paused,
}

/// What the engine has to do after a transport change.
#[derive(Clone, Debug, PartialEq)]
pub enum Command {
    /// Load `item` from its start. `seamless` is a segue the gapless engine may join.
    Load { item: Item, seamless: bool },
    /// Fetch `item` ahead of time, as the segue after the current one.
    Preload { item: Item },
    /// Play the current item again from its start.
    Restart,
    /// The queue ran out: find more like `seed` and hand them to [`Transport::extend`].
    Continue { seed: Item },
}

/// What the listener sees right now.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Snapshot {
    pub item: Option<Item>,
    pub index: Option<usize>,
    pub items: Vec<Item>,
    pub status: Status,
    pub position: Duration,
    pub duration: Duration,
    pub repeat: Repeat,
    pub stop_after_current: bool,
    /// Playback stopped because several tracks in a row could not be played.
    pub stalled: bool,
}

/// How many unplayable tracks in a row stop the queue, so a service that plays nothing does not
/// race through the whole of it.
const STALL: u8 = 3;

#[derive(Default)]
pub struct Transport {
    queue: Queue<Item>,
    status: Status,
    position: Duration,
    duration: Duration,
    /// The current item is only remembered from last time: on screen, but in no engine yet.
    resumed: bool,
    /// Rest once the current item ends, as a sleep timer set to the end of a track does.
    stop_after_current: bool,
    /// Ask for similar tracks when the queue runs out rather than stopping.
    continue_similar: bool,
    /// Tracks in a row that could not be played.
    failures: u8,
}

impl Transport {
    /// Brings back last time's queue, paused at `position`, without telling any engine: the
    /// track loads once the listener presses play.
    pub fn resume(&mut self, items: Vec<Item>, index: usize, position: Duration, repeat: Repeat) {
        self.queue.repeat = repeat;
        let Some(item) = self.queue.replace(items, index) else {
            return;
        };
        self.duration = item.track.duration;
        self.status = Status::Paused;
        self.position = position;
        self.resumed = true;
    }

    /// The remembered track and where to start it, while it has not been loaded.
    pub fn resumed(&self) -> Option<(Item, Duration)> {
        let item = self.queue.current()?;
        self.resumed.then(|| (item.clone(), self.position))
    }

    /// The engine is gone: the current track is remembered where it was, paused, for play to
    /// load again.
    pub fn unload(&mut self) {
        if self.queue.current().is_some() {
            self.resumed = true;
            self.status = Status::Paused;
        }
    }

    /// Empties the queue, as when the provider of what was playing is gone. The settings that
    /// outlive a queue stay.
    pub fn clear(&mut self) {
        *self = Transport {
            continue_similar: self.continue_similar,
            ..Transport::default()
        };
    }

    /// The remembered track went to an engine.
    pub fn loaded(&mut self) {
        self.resumed = false;
        self.status = Status::Loading;
    }

    /// Shows the new position at once, since a paused engine only says it moved once audio
    /// plays. Answers whether the track is only remembered, with no engine to tell.
    pub fn seek(&mut self, position: Duration) -> bool {
        self.position = position;
        self.resumed
    }

    pub fn move_item(&mut self, from: usize, to: usize) {
        self.queue.move_item(from, to);
    }

    pub fn shuffle_upcoming(&mut self) {
        self.queue.shuffle_upcoming(|n| fastrand::usize(..n));
    }

    pub fn remove(&mut self, index: usize) {
        self.queue.remove(index);
    }

    pub fn clear_upcoming(&mut self) {
        self.queue.clear_upcoming();
    }

    /// Puts `items` right after the current track, or plays them when nothing is playing.
    pub fn play_next(&mut self, items: Vec<Item>) -> Option<Command> {
        let first = self.queue.index().map_or(0, |index| index + 1);
        self.queue.play_next(items);
        self.start_if_idle(first)
    }

    /// Puts `items` at the end, or plays them when nothing is playing.
    pub fn append(&mut self, items: Vec<Item>) -> Option<Command> {
        let first = self.queue.index().map_or(0, |_| self.queue.items().len());
        self.queue.append(items);
        self.start_if_idle(first)
    }

    /// Makes `items` the queue and starts `start`.
    pub fn start(&mut self, items: Vec<Item>, start: usize) -> Option<Command> {
        // The listener picked something: earlier failures no longer hold the queue.
        self.failures = 0;
        let item = self.queue.replace(items, start)?.clone();
        Some(self.begin(item, false))
    }

    pub fn next(&mut self) -> Option<Command> {
        // The listener picked something: earlier failures no longer hold the queue.
        self.failures = 0;
        let item = self.queue.skip()?.clone();
        Some(self.begin(item, false))
    }

    pub fn previous(&mut self) -> Option<Command> {
        // The listener picked something: earlier failures no longer hold the queue.
        self.failures = 0;
        let earlier = match self.queue.back(self.position)? {
            Back::Restart(_) => None,
            Back::To(item) => Some(item.clone()),
        };
        match earlier {
            Some(item) => Some(self.begin(item, false)),
            None => {
                self.position = Duration::ZERO;
                Some(Command::Restart)
            }
        }
    }

    pub fn jump(&mut self, index: usize) -> Option<Command> {
        // The listener picked something: earlier failures no longer hold the queue.
        self.failures = 0;
        let item = self.queue.jump(index)?.clone();
        Some(self.begin(item, false))
    }

    pub fn set_repeat(&mut self, repeat: Repeat) {
        self.queue.repeat = repeat;
    }

    pub fn set_stop_after_current(&mut self, stop: bool) {
        self.stop_after_current = stop;
    }

    pub fn stops_after_current(&self) -> bool {
        self.stop_after_current
    }

    pub fn set_continue_similar(&mut self, continues: bool) {
        self.continue_similar = continues;
    }

    /// Puts what [`Command::Continue`] found at the end and segues into the first of it, or
    /// rests at the end when nothing was found.
    pub fn extend(&mut self, items: Vec<Item>) -> Option<Command> {
        self.queue.append(items);
        let next = self.queue.ended().cloned();
        self.advance(next, true)
    }

    /// Folds one engine event in. Events about anything but the current item are stale and
    /// change nothing.
    pub fn on_event(&mut self, event: &PlaybackEvent) -> Option<Command> {
        let current = self.queue.current()?;
        if event.id() != Some(current.id.as_str()) {
            return None;
        }
        match event {
            PlaybackEvent::Loading { at, .. } => {
                self.status = Status::Loading;
                self.position = *at;
            }
            PlaybackEvent::Playing { at, .. } => {
                self.failures = 0;
                self.status = Status::Playing;
                self.position = *at;
            }
            PlaybackEvent::Paused { at, .. } => {
                self.status = Status::Paused;
                self.position = *at;
            }
            PlaybackEvent::Position { at, .. } | PlaybackEvent::Seeked { at, .. } => {
                self.position = *at;
            }
            PlaybackEvent::Length { duration, .. } => self.duration = *duration,
            PlaybackEvent::Downloaded { .. } if self.stop_after_current => {}
            PlaybackEvent::Downloaded { .. } => {
                return self
                    .queue
                    .upcoming()
                    .cloned()
                    .map(|item| Command::Preload { item });
            }
            PlaybackEvent::Ended { .. } if self.stop_after_current => {
                self.stop_after_current = false;
                return self.advance(None, true);
            }
            PlaybackEvent::Ended { .. } => {
                let seed = current.clone();
                let next = self.queue.ended().cloned();
                if next.is_none() && self.continue_similar {
                    self.status = Status::Loading;
                    return Some(Command::Continue { seed });
                }
                return self.advance(next, true);
            }
            PlaybackEvent::Unavailable { .. } => {
                self.failures += 1;
                if self.failures >= STALL {
                    // Play tries the track again rather than resuming an engine that has nothing.
                    self.resumed = true;
                    self.status = Status::Paused;
                    return None;
                }
                let next = self.queue.skip().cloned();
                return self.advance(next, false);
            }
            _ => {}
        }
        None
    }

    /// Plays the item at `first` when nothing was playing: an empty queue or one that ran out.
    fn start_if_idle(&mut self, first: usize) -> Option<Command> {
        if self.status != Status::Idle {
            return None;
        }
        self.jump(first)
    }

    /// Starts `item` from zero, taking the length its listing knew until the engine says better.
    fn begin(&mut self, item: Item, seamless: bool) -> Command {
        self.resumed = false;
        self.status = Status::Loading;
        self.position = Duration::ZERO;
        self.duration = item.track.duration;
        Command::Load { item, seamless }
    }

    /// Moves on to `next`, or comes to rest at the start of the track that ended.
    fn advance(&mut self, next: Option<Item>, seamless: bool) -> Option<Command> {
        match next {
            Some(item) => Some(self.begin(item, seamless)),
            None => {
                self.status = Status::Idle;
                self.position = Duration::ZERO;
                None
            }
        }
    }

    pub fn snapshot(&self) -> Snapshot {
        Snapshot {
            item: self.queue.current().cloned(),
            index: self.queue.index(),
            items: self.queue.items().to_vec(),
            status: self.status,
            position: self.position,
            duration: self.duration,
            repeat: self.queue.repeat,
            stop_after_current: self.stop_after_current,
            stalled: self.failures >= STALL,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn clearing_leaves_nothing_to_play_and_keeps_continue_similar() {
        let mut transport = Transport::default();
        transport.set_continue_similar(true);
        transport.start(vec![item("a"), item("b")], 1);
        transport.clear();
        let snapshot = transport.snapshot();
        assert!(snapshot.item.is_none() && snapshot.items.is_empty());
        assert!(transport.continue_similar);
    }

    fn item(id: &str) -> Item {
        Item {
            source: "subsonic".to_owned(),
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

    fn id(id: &str) -> Option<String> {
        Some(id.to_owned())
    }

    fn started(ids: &[&str]) -> Transport {
        let mut transport = Transport::default();
        transport.start(ids.iter().map(|id| item(id)).collect(), 0);
        transport
    }

    fn load(id: &str, seamless: bool) -> Option<Command> {
        Some(Command::Load {
            item: item(id),
            seamless,
        })
    }

    #[test]
    fn a_remembered_queue_shows_paused_where_it_was_without_loading() {
        let mut transport = Transport::default();
        transport.resume(
            vec![item("a"), item("b")],
            1,
            Duration::from_secs(42),
            Repeat::All,
        );
        let snapshot = transport.snapshot();
        assert_eq!(snapshot.status, Status::Paused);
        assert_eq!(snapshot.index, Some(1));
        assert_eq!(snapshot.position, Duration::from_secs(42));
        assert_eq!(snapshot.repeat, Repeat::All);
        assert_eq!(
            transport.resumed(),
            Some((item("b"), Duration::from_secs(42)))
        );
        transport.loaded();
        assert_eq!(transport.resumed(), None);
        assert_eq!(transport.snapshot().status, Status::Loading);
    }

    #[test]
    fn a_seek_before_playing_moves_where_a_remembered_track_starts() {
        let mut transport = Transport::default();
        transport.resume(vec![item("a")], 0, Duration::from_secs(42), Repeat::Off);
        assert!(transport.seek(Duration::from_secs(10)));
        assert_eq!(
            transport.resumed(),
            Some((item("a"), Duration::from_secs(10)))
        );
    }

    #[test]
    fn an_unloaded_track_is_remembered_where_it_was() {
        let mut transport = started(&["a", "b"]);
        transport.on_event(&PlaybackEvent::Playing {
            id: id("a"),
            at: Duration::from_secs(30),
        });
        transport.unload();
        let snapshot = transport.snapshot();
        assert_eq!(snapshot.status, Status::Paused);
        assert_eq!(
            transport.resumed(),
            Some((item("a"), Duration::from_secs(30)))
        );
    }

    #[test]
    fn starting_another_queue_forgets_the_remembered_one() {
        let mut transport = Transport::default();
        transport.resume(vec![item("a")], 0, Duration::from_secs(42), Repeat::Off);
        transport.start(vec![item("b")], 0);
        assert_eq!(transport.resumed(), None);
        assert!(!transport.seek(Duration::from_secs(1)));
    }

    #[test]
    fn start_loads_the_chosen_track_and_takes_its_known_length() {
        let mut transport = Transport::default();
        assert_eq!(
            transport.start(vec![item("a"), item("b")], 1),
            load("b", false)
        );
        let snapshot = transport.snapshot();
        assert_eq!(snapshot.status, Status::Loading);
        assert_eq!(snapshot.index, Some(1));
        assert_eq!(snapshot.duration, Duration::from_secs(200));
    }

    #[test]
    fn engine_events_drive_status_position_and_length() {
        let mut transport = started(&["a"]);
        transport.on_event(&PlaybackEvent::Playing {
            id: id("a"),
            at: Duration::ZERO,
        });
        transport.on_event(&PlaybackEvent::Position {
            id: id("a"),
            at: Duration::from_secs(5),
        });
        transport.on_event(&PlaybackEvent::Length {
            id: id("a"),
            duration: Duration::from_secs(180),
        });
        let snapshot = transport.snapshot();
        assert_eq!(snapshot.status, Status::Playing);
        assert_eq!(snapshot.position, Duration::from_secs(5));
        assert_eq!(snapshot.duration, Duration::from_secs(180));
        transport.on_event(&PlaybackEvent::Paused {
            id: id("a"),
            at: Duration::from_secs(6),
        });
        assert_eq!(transport.snapshot().status, Status::Paused);
    }

    #[test]
    fn stale_events_from_another_track_change_nothing() {
        let mut transport = started(&["a", "b"]);
        assert_eq!(
            transport.on_event(&PlaybackEvent::Ended { id: id("old") }),
            None
        );
        transport.on_event(&PlaybackEvent::Position {
            id: id("old"),
            at: Duration::from_secs(99),
        });
        let snapshot = transport.snapshot();
        assert_eq!(snapshot.index, Some(0));
        assert_eq!(snapshot.position, Duration::ZERO);
    }

    #[test]
    fn a_track_that_ends_segues_into_the_next() {
        let mut transport = started(&["a", "b"]);
        assert_eq!(
            transport.on_event(&PlaybackEvent::Ended { id: id("a") }),
            load("b", true)
        );
        let snapshot = transport.snapshot();
        assert_eq!(snapshot.index, Some(1));
        assert_eq!(snapshot.position, Duration::ZERO);
    }

    #[test]
    fn the_last_track_ending_stops_at_its_start() {
        let mut transport = started(&["a"]);
        assert_eq!(
            transport.on_event(&PlaybackEvent::Ended { id: id("a") }),
            None
        );
        let snapshot = transport.snapshot();
        assert_eq!(snapshot.status, Status::Idle);
        assert_eq!(snapshot.position, Duration::ZERO);
    }

    #[test]
    fn an_unavailable_track_is_skipped_without_a_segue() {
        let mut transport = started(&["a", "b"]);
        assert_eq!(
            transport.on_event(&PlaybackEvent::Unavailable { id: id("a") }),
            load("b", false)
        );
    }

    #[test]
    fn three_unplayable_tracks_in_a_row_stop_the_queue_rather_than_race_through_it() {
        let mut transport = started(&["a", "b", "c", "d"]);
        transport.on_event(&PlaybackEvent::Unavailable { id: id("a") });
        transport.on_event(&PlaybackEvent::Unavailable { id: id("b") });
        assert_eq!(
            transport.on_event(&PlaybackEvent::Unavailable { id: id("c") }),
            None
        );
        let snapshot = transport.snapshot();
        assert_eq!(snapshot.item, Some(item("c")));
        assert_eq!(snapshot.status, Status::Paused);
        assert!(snapshot.stalled);
    }

    #[test]
    fn a_track_that_plays_clears_the_failures() {
        let mut transport = started(&["a", "b", "c", "d", "e"]);
        transport.on_event(&PlaybackEvent::Unavailable { id: id("a") });
        transport.on_event(&PlaybackEvent::Unavailable { id: id("b") });
        transport.on_event(&PlaybackEvent::Playing {
            id: id("c"),
            at: Duration::ZERO,
        });
        assert!(!transport.snapshot().stalled);
        transport.on_event(&PlaybackEvent::Ended { id: id("c") });
        transport.on_event(&PlaybackEvent::Unavailable { id: id("d") });
        assert_eq!(transport.snapshot().item, Some(item("e")));
    }

    #[test]
    fn a_finished_download_preloads_what_follows() {
        let mut transport = started(&["a", "b"]);
        assert_eq!(
            transport.on_event(&PlaybackEvent::Downloaded { id: id("a") }),
            Some(Command::Preload { item: item("b") })
        );
    }

    #[test]
    fn next_and_jump_load_without_a_segue() {
        let mut transport = started(&["a", "b", "c"]);
        assert_eq!(transport.next(), load("b", false));
        assert_eq!(transport.jump(0), load("a", false));
        assert_eq!(transport.jump(7), None);
    }

    #[test]
    fn previous_restarts_late_in_a_track_and_goes_back_early() {
        let mut transport = started(&["a", "b"]);
        transport.next();
        transport.on_event(&PlaybackEvent::Position {
            id: id("b"),
            at: Duration::from_secs(30),
        });
        assert_eq!(transport.previous(), Some(Command::Restart));
        assert_eq!(transport.snapshot().position, Duration::ZERO);
        assert_eq!(transport.previous(), load("a", false));
    }

    #[test]
    fn repeat_one_replays_the_track_that_ended() {
        let mut transport = started(&["a", "b"]);
        transport.set_repeat(Repeat::One);
        assert_eq!(
            transport.on_event(&PlaybackEvent::Ended { id: id("a") }),
            load("a", true)
        );
    }

    #[test]
    fn stopping_after_the_current_track_rests_when_it_ends() {
        let mut transport = started(&["a", "b"]);
        transport.set_stop_after_current(true);
        assert_eq!(
            transport.on_event(&PlaybackEvent::Downloaded { id: id("a") }),
            None
        );
        assert_eq!(
            transport.on_event(&PlaybackEvent::Ended { id: id("a") }),
            None
        );
        let snapshot = transport.snapshot();
        assert_eq!(snapshot.status, Status::Idle);
        assert!(!transport.stops_after_current());
    }

    #[test]
    fn the_end_of_the_queue_asks_for_more_when_it_continues() {
        let mut transport = started(&["a"]);
        transport.set_continue_similar(true);
        assert_eq!(
            transport.on_event(&PlaybackEvent::Ended { id: id("a") }),
            Some(Command::Continue { seed: item("a") })
        );
        assert_eq!(transport.snapshot().status, Status::Loading);
        assert_eq!(
            transport.extend(vec![item("b"), item("c")]),
            load("b", true)
        );
        let snapshot = transport.snapshot();
        assert_eq!(snapshot.index, Some(1));
        assert_eq!(snapshot.items.len(), 3);
    }

    #[test]
    fn nothing_more_to_continue_with_rests_at_the_end() {
        let mut transport = started(&["a"]);
        transport.set_continue_similar(true);
        transport.on_event(&PlaybackEvent::Ended { id: id("a") });
        assert_eq!(transport.extend(Vec::new()), None);
        assert_eq!(transport.snapshot().status, Status::Idle);
    }

    #[test]
    fn a_queue_that_repeats_never_asks_for_more() {
        let mut transport = started(&["a"]);
        transport.set_continue_similar(true);
        transport.set_repeat(Repeat::All);
        assert_eq!(
            transport.on_event(&PlaybackEvent::Ended { id: id("a") }),
            load("a", true)
        );
    }

    #[test]
    fn a_seek_shows_at_once_even_while_paused() {
        let mut transport = started(&["a"]);
        transport.on_event(&PlaybackEvent::Paused {
            id: id("a"),
            at: Duration::from_secs(5),
        });
        assert!(!transport.seek(Duration::from_secs(60)));
        assert_eq!(transport.snapshot().position, Duration::from_secs(60));
        assert_eq!(transport.snapshot().status, Status::Paused);
    }

    #[test]
    fn play_next_while_playing_queues_without_loading() {
        let mut transport = started(&["a", "b"]);
        transport.on_event(&PlaybackEvent::Playing {
            id: id("a"),
            at: Duration::ZERO,
        });
        assert_eq!(transport.play_next(vec![item("c")]), None);
        assert_eq!(transport.next(), load("c", false));
    }

    #[test]
    fn play_next_with_nothing_queued_plays_it() {
        let mut transport = Transport::default();
        assert_eq!(transport.play_next(vec![item("a")]), load("a", false));
        let mut transport = Transport::default();
        assert_eq!(
            transport.append(vec![item("a"), item("b")]),
            load("a", false)
        );
    }

    #[test]
    fn appending_after_the_queue_ended_plays_what_was_added() {
        let mut transport = started(&["a"]);
        transport.on_event(&PlaybackEvent::Ended { id: id("a") });
        assert_eq!(transport.append(vec![item("b")]), load("b", false));
        assert_eq!(transport.snapshot().index, Some(1));
    }

    #[test]
    fn appending_to_a_paused_queue_leaves_it_paused() {
        let mut transport = Transport::default();
        transport.resume(vec![item("a")], 0, Duration::from_secs(9), Repeat::Off);
        assert_eq!(transport.append(vec![item("b")]), None);
        assert_eq!(transport.snapshot().status, Status::Paused);
        assert_eq!(transport.snapshot().items.len(), 2);
    }
}
