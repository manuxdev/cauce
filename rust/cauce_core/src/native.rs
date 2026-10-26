//! An engine the host app plays through, for songs only the system's own player can play: Apple
//! Music on iOS, through its queue player. Commands go out through the hook [`on_command`] sets,
//! and what the host's player does comes back through [`event`].

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Mutex, MutexGuard, PoisonError};
use std::time::Duration;

use anyhow::Result;
use music::{PlaybackConfig, PlaybackEvent, PlaybackEvents, PlaybackFactory, Player};
use tokio::sync::mpsc::{UnboundedReceiver, UnboundedSender, unbounded_channel};

/// What the host's player is asked to do.
#[derive(Clone, Debug, PartialEq)]
pub enum Command {
    /// Plays `id` from `at`, or leaves it paused there when `play` is off.
    Load { id: String, at: Duration, play: bool },
    Play,
    Pause,
    Seek(Duration),
    Stop,
}

type Commands = Box<dyn Fn(Command) + Send + Sync>;

static COMMANDS: Mutex<Option<Commands>> = Mutex::new(None);
/// Where the host's reports go: the engine that loaded last, by its number, so one dropped later
/// leaves its successor alone.
static EVENTS: Mutex<Option<(u64, UnboundedSender<PlaybackEvent>)>> = Mutex::new(None);
static ENGINES: AtomicU64 = AtomicU64::new(0);

/// Hands every command from now on to the host.
pub fn on_command(commands: impl Fn(Command) + Send + Sync + 'static) {
    *lock(&COMMANDS) = Some(Box::new(commands));
}

/// Folds in a report from the host's player about track `id`. An unknown kind is dropped.
pub fn event(kind: &str, id: String, at_ms: u64, duration_ms: u64) {
    let Some(event) = translate(kind, id, at_ms, duration_ms) else {
        log::warn!("native: the host reported an unknown event {kind}");
        return;
    };
    if let Some((_, events)) = lock(&EVENTS).as_ref() {
        events.send(event).ok();
    }
}

fn translate(kind: &str, id: String, at_ms: u64, duration_ms: u64) -> Option<PlaybackEvent> {
    let id = Some(id);
    let at = Duration::from_millis(at_ms);
    Some(match kind {
        "loading" => PlaybackEvent::Loading { id, at },
        "playing" => PlaybackEvent::Playing { id, at },
        "paused" => PlaybackEvent::Paused { id, at },
        "position" => PlaybackEvent::Position { id, at },
        "seeked" => PlaybackEvent::Seeked { id, at },
        "length" => PlaybackEvent::Length {
            id,
            duration: Duration::from_millis(duration_ms),
        },
        "ended" => PlaybackEvent::Ended { id },
        "unavailable" => PlaybackEvent::Unavailable { id },
        _ => return None,
    })
}

fn send(command: Command) {
    match lock(&COMMANDS).as_ref() {
        Some(commands) => commands(command),
        None => log::warn!("native: no host player listens"),
    }
}

/// Starts engines on the host's player. The system mixes, levels and keeps the audio itself, so
/// the config means nothing here.
pub struct Factory;

impl PlaybackFactory for Factory {
    fn start(&self, _config: PlaybackConfig) -> (Box<dyn Player>, Box<dyn PlaybackEvents>) {
        let (events, receiver) = unbounded_channel();
        let engine = ENGINES.fetch_add(1, Ordering::Relaxed);
        (
            Box::new(Native { engine, events }),
            Box::new(Events(receiver)),
        )
    }
}

/// One engine. It takes the host's reports only once it loads, so one started just to download
/// or discard, which it refuses, never steals them from the one playing.
struct Native {
    engine: u64,
    events: UnboundedSender<PlaybackEvent>,
}

impl Native {
    fn claim(&self) {
        *lock(&EVENTS) = Some((self.engine, self.events.clone()));
    }
}

impl Player for Native {
    fn load(&self, track_id: &str, at: Duration, _seamless: bool) -> Result<()> {
        self.claim();
        send(Command::Load {
            id: track_id.to_owned(),
            at,
            play: true,
        });
        Ok(())
    }

    fn load_paused_at(&self, track_id: &str, at: Duration) -> Result<()> {
        self.claim();
        send(Command::Load {
            id: track_id.to_owned(),
            at,
            play: false,
        });
        Ok(())
    }

    fn preload(&self, _track_id: &str, _segue: bool) -> Result<()> {
        Ok(())
    }

    fn play(&self) {
        send(Command::Play);
    }

    fn pause(&self) {
        send(Command::Pause);
    }

    fn seek(&self, position: Duration) {
        send(Command::Seek(position));
    }

    /// The system's volume is the only one its player has.
    fn set_gain(&self, _gain: f32) {}
}

/// Dropping the engine that plays is what stops it, as with every other engine.
impl Drop for Native {
    fn drop(&mut self) {
        let mut events = lock(&EVENTS);
        if events.as_ref().is_some_and(|(engine, _)| *engine == self.engine) {
            *events = None;
            drop(events);
            send(Command::Stop);
        }
    }
}

struct Events(UnboundedReceiver<PlaybackEvent>);

#[async_trait::async_trait]
impl PlaybackEvents for Events {
    async fn next(&mut self) -> Option<PlaybackEvent> {
        self.0.recv().await
    }
}

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn host_reports_become_engine_events_about_their_track() {
        let id = || Some("1440".to_owned());
        let half = Duration::from_millis(500);
        assert_eq!(
            translate("playing", "1440".into(), 500, 0),
            Some(PlaybackEvent::Playing { id: id(), at: half })
        );
        assert_eq!(
            translate("position", "1440".into(), 500, 0),
            Some(PlaybackEvent::Position { id: id(), at: half })
        );
        assert_eq!(
            translate("length", "1440".into(), 0, 180_000),
            Some(PlaybackEvent::Length {
                id: id(),
                duration: Duration::from_secs(180)
            })
        );
        assert_eq!(
            translate("ended", "1440".into(), 0, 0),
            Some(PlaybackEvent::Ended { id: id() })
        );
        assert_eq!(
            translate("unavailable", "1440".into(), 0, 0),
            Some(PlaybackEvent::Unavailable { id: id() })
        );
        assert_eq!(translate("buffering", "1440".into(), 0, 0), None);
    }
}
