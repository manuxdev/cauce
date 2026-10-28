//! Podcasts as the core sees them: the shows the listener subscribed to, with the episodes
//! their feeds listed last, and how far each episode has been heard, kept in `podcasts.json`
//! in the data folder.

use std::collections::HashMap;
use std::path::Path;
use std::time::{Duration, Instant};

use music::podcast::Feed;
use serde::{Deserialize, Serialize};

/// The source episodes play through. It needs no account and is always there.
pub use music::podcast::SLUG as PODCAST;
const FILE: &str = "podcasts.json";
/// How much of an episode has to be heard for it to count as played.
const PLAYED: f64 = 0.95;
/// How often the position of an episode playing is written down.
const SAVE_EVERY: Duration = Duration::from_secs(15);

/// Whether items of `source` are podcast episodes: resumed where they were left, never
/// scrobbled, prefetched or preloaded, and with no lyrics.
pub fn is_episode(source: &str) -> bool {
    source == PODCAST
}

/// How far one episode has been heard. The enclosure is kept too, so an episode played from a
/// feed the listener never subscribed to still resumes after a restart.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Progress {
    pub url: String,
    #[serde(default)]
    pub position_ms: u64,
    #[serde(default)]
    pub duration_ms: u64,
    #[serde(default)]
    pub played: bool,
}

#[derive(Default, Serialize, Deserialize)]
struct Saved {
    #[serde(default)]
    subscriptions: Vec<serde_json::Value>,
    #[serde(default)]
    progress: HashMap<String, serde_json::Value>,
}

/// The subscriptions, newest first, and the progress of every episode heard.
#[derive(Debug, Default)]
pub struct Library {
    subscriptions: Vec<Feed>,
    progress: HashMap<String, Progress>,
    /// When the progress was last due to be written.
    saved_at: Option<Instant>,
}

impl Library {
    /// The saved library. A missing or unreadable file is an empty one, and an entry that does
    /// not read is left out rather than losing the rest.
    pub fn load(folder: &Path) -> Self {
        let saved = std::fs::read_to_string(folder.join(FILE))
            .ok()
            .and_then(|text| serde_json::from_str::<Saved>(&text).ok())
            .unwrap_or_default();
        Self {
            subscriptions: saved
                .subscriptions
                .into_iter()
                .filter_map(|entry| serde_json::from_value(entry).ok())
                .collect(),
            progress: saved
                .progress
                .into_iter()
                .filter_map(|(id, entry)| Some((id, serde_json::from_value(entry).ok()?)))
                .collect(),
            saved_at: None,
        }
    }

    pub fn save(&self, folder: &Path) {
        let saved = Saved {
            subscriptions: self
                .subscriptions
                .iter()
                .filter_map(|feed| serde_json::to_value(feed).ok())
                .collect(),
            progress: self
                .progress
                .iter()
                .filter_map(|(id, progress)| {
                    Some((id.clone(), serde_json::to_value(progress).ok()?))
                })
                .collect(),
        };
        let written = serde_json::to_vec(&saved)
            .map_err(anyhow::Error::from)
            .and_then(|json| Ok(std::fs::write(folder.join(FILE), json)?));
        if let Err(error) = written {
            log::warn!("podcast: cannot save the library: {error:#}");
        }
    }

    pub fn subscriptions(&self) -> &[Feed] {
        &self.subscriptions
    }

    pub fn subscribed(&self, feed: &str) -> bool {
        self.feed(feed).is_some()
    }

    /// The stored feed of a subscription.
    pub fn feed(&self, feed: &str) -> Option<&Feed> {
        self.subscriptions
            .iter()
            .find(|kept| kept.podcast.feed == feed)
    }

    /// Subscribes to `feed` first, or stops. Subscribing again moves it first with its new
    /// episodes.
    pub fn subscribe(&mut self, feed: Feed, on: bool) {
        self.subscriptions
            .retain(|kept| kept.podcast.feed != feed.podcast.feed);
        if on {
            self.subscriptions.insert(0, feed);
        }
    }

    /// Stores `feed`'s fresh episodes when it is subscribed to, in place. Answers whether it was.
    pub fn refresh(&mut self, feed: &Feed) -> bool {
        match self
            .subscriptions
            .iter_mut()
            .find(|kept| kept.podcast.feed == feed.podcast.feed)
        {
            Some(kept) => {
                *kept = feed.clone();
                true
            }
            None => false,
        }
    }

    pub fn progress(&self, id: &str) -> Option<&Progress> {
        self.progress.get(id)
    }

    /// Every episode heard, by id.
    pub fn heard_episodes(&self) -> &HashMap<String, Progress> {
        &self.progress
    }

    /// Notes that episode `id` at `url` has been heard up to `at` of `duration`, played once
    /// that is most of it. Answers whether it is time to write the library, which it is the
    /// first time and then every [`SAVE_EVERY`].
    pub fn heard(
        &mut self,
        id: &str,
        url: &str,
        at: Duration,
        duration: Duration,
        now: Instant,
    ) -> bool {
        let progress = self.entry(id, url, duration);
        progress.position_ms = at.as_millis() as u64;
        if !duration.is_zero() && at.as_secs_f64() >= duration.as_secs_f64() * PLAYED {
            progress.played = true;
        }
        let due = self
            .saved_at
            .is_none_or(|saved| now.saturating_duration_since(saved) >= SAVE_EVERY);
        if due {
            self.saved_at = Some(now);
        }
        due
    }

    /// Episode `id` played to its end.
    pub fn finished(&mut self, id: &str, url: &str, duration: Duration) {
        let progress = self.entry(id, url, duration);
        progress.position_ms = progress.duration_ms;
        progress.played = true;
    }

    fn entry(&mut self, id: &str, url: &str, duration: Duration) -> &mut Progress {
        let progress = self
            .progress
            .entry(id.to_owned())
            .or_insert_with(|| Progress {
                url: url.to_owned(),
                position_ms: 0,
                duration_ms: 0,
                played: false,
            });
        progress.url = url.to_owned();
        if !duration.is_zero() {
            progress.duration_ms = duration.as_millis() as u64;
        }
        progress
    }

    /// Where episode `id` starts: where it was left, or its start when it was played through,
    /// which then counts as not played yet.
    pub fn starting(&mut self, id: &str) -> Duration {
        let Some(progress) = self.progress.get_mut(id) else {
            return Duration::ZERO;
        };
        if progress.played {
            progress.played = false;
            progress.position_ms = 0;
        }
        Duration::from_millis(progress.position_ms)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use music::podcast::{Episode, Podcast};

    fn folder(name: &str) -> std::path::PathBuf {
        let folder =
            std::env::temp_dir().join(format!("cauce-podcasts-{name}-{}", std::process::id()));
        std::fs::create_dir_all(&folder).unwrap();
        folder
    }

    fn feed(url: &str, episodes: &[&str]) -> Feed {
        Feed {
            podcast: Podcast {
                feed: url.to_owned(),
                title: format!("{url} show"),
                author: "Someone".to_owned(),
                description: "About things".to_owned(),
                artwork: None,
            },
            episodes: episodes
                .iter()
                .map(|id| Episode {
                    id: (*id).to_owned(),
                    title: format!("Episode {id}"),
                    url: format!("https://cdn.example.com/{id}.mp3"),
                    mime: Some("audio/mpeg".to_owned()),
                    duration_secs: Some(600),
                    published: Some(1_700_000_000),
                    artwork: None,
                })
                .collect(),
        }
    }

    const HOUR: Duration = Duration::from_secs(3600);

    #[test]
    fn subscriptions_read_back_newest_first_with_their_episodes() {
        let folder = folder("saved");
        let mut library = Library::default();
        library.subscribe(feed("https://a", &["a1", "a2"]), true);
        library.subscribe(feed("https://b", &["b1"]), true);
        library.heard(
            "a1",
            "https://cdn.example.com/a1.mp3",
            Duration::from_secs(90),
            HOUR,
            Instant::now(),
        );
        library.save(&folder);
        let loaded = Library::load(&folder);
        let feeds: Vec<&str> = loaded
            .subscriptions()
            .iter()
            .map(|feed| feed.podcast.feed.as_str())
            .collect();
        assert_eq!(feeds, ["https://b", "https://a"]);
        assert_eq!(loaded.feed("https://a").unwrap().episodes.len(), 2);
        assert_eq!(loaded.progress("a1").unwrap().position_ms, 90_000);
        std::fs::remove_dir_all(folder).ok();
    }

    #[test]
    fn a_missing_or_corrupt_file_is_an_empty_library_and_a_broken_entry_is_skipped() {
        let folder = folder("corrupt");
        assert!(Library::load(&folder).subscriptions().is_empty());
        std::fs::write(folder.join(FILE), "{not json").unwrap();
        assert!(Library::load(&folder).subscriptions().is_empty());
        let good = serde_json::to_value(feed("https://a", &["a1"])).unwrap();
        let saved = serde_json::json!({
            "subscriptions": [good, {"podcast": {"title": "no feed"}}],
            "progress": {"a1": {"url": "https://cdn.example.com/a1.mp3", "position_ms": 5000}, "b1": {"position_ms": 1}},
        });
        std::fs::write(folder.join(FILE), saved.to_string()).unwrap();
        let loaded = Library::load(&folder);
        assert_eq!(loaded.subscriptions().len(), 1);
        assert!(loaded.progress("a1").is_some());
        assert!(
            loaded.progress("b1").is_none(),
            "an entry with no enclosure is no use"
        );
        std::fs::remove_dir_all(folder).ok();
    }

    #[test]
    fn subscribing_twice_keeps_one_and_unsubscribing_removes_it() {
        let mut library = Library::default();
        library.subscribe(feed("https://a", &["a1"]), true);
        library.subscribe(feed("https://b", &["b1"]), true);
        library.subscribe(feed("https://a", &["a1", "a2"]), true);
        assert_eq!(library.subscriptions().len(), 2);
        assert_eq!(library.subscriptions()[0].podcast.feed, "https://a");
        assert_eq!(library.feed("https://a").unwrap().episodes.len(), 2);
        library.subscribe(feed("https://a", &[]), false);
        assert!(!library.subscribed("https://a"));
        assert!(library.subscribed("https://b"));
    }

    #[test]
    fn a_refresh_only_stores_a_subscribed_feed_and_keeps_its_place() {
        let mut library = Library::default();
        library.subscribe(feed("https://a", &["a1"]), true);
        library.subscribe(feed("https://b", &["b1"]), true);
        assert!(library.refresh(&feed("https://a", &["a2", "a1"])));
        assert_eq!(
            library.subscriptions()[1].podcast.feed,
            "https://a",
            "it stays where it was"
        );
        assert_eq!(library.feed("https://a").unwrap().episodes[0].id, "a2");
        assert!(!library.refresh(&feed("https://c", &["c1"])));
        assert!(!library.subscribed("https://c"));
    }

    #[test]
    fn heard_writes_down_at_first_and_then_every_so_often() {
        let mut library = Library::default();
        let start = Instant::now();
        let url = "https://cdn.example.com/a1.mp3";
        assert!(library.heard("a1", url, Duration::from_secs(1), HOUR, start));
        assert!(!library.heard(
            "a1",
            url,
            Duration::from_secs(5),
            HOUR,
            start + Duration::from_secs(5)
        ));
        assert!(library.heard("a1", url, Duration::from_secs(16), HOUR, start + SAVE_EVERY));
        let progress = library.progress("a1").unwrap();
        assert_eq!(progress.position_ms, 16_000);
        assert_eq!(progress.duration_ms, 3_600_000);
        assert_eq!(progress.url, url);
        assert!(!progress.played);
    }

    #[test]
    fn most_of_an_episode_heard_counts_as_played() {
        let mut library = Library::default();
        let url = "https://cdn.example.com/a1.mp3";
        library.heard("a1", url, Duration::from_secs(3400), HOUR, Instant::now());
        assert!(!library.progress("a1").unwrap().played, "94% is not yet");
        library.heard("a1", url, Duration::from_secs(3420), HOUR, Instant::now());
        assert!(library.progress("a1").unwrap().played, "95% is");
        library.finished("b1", url, Duration::ZERO);
        assert!(
            library.progress("b1").unwrap().played,
            "an end with no length still counts"
        );
    }

    #[test]
    fn an_episode_with_no_length_is_never_played_by_position_alone() {
        let mut library = Library::default();
        library.heard(
            "a1",
            "https://x/a.mp3",
            Duration::from_secs(9000),
            Duration::ZERO,
            Instant::now(),
        );
        assert!(!library.progress("a1").unwrap().played);
    }

    #[test]
    fn an_episode_resumes_where_it_was_left_and_a_played_one_starts_over() {
        let mut library = Library::default();
        let url = "https://cdn.example.com/a1.mp3";
        assert_eq!(library.starting("new"), Duration::ZERO);
        library.heard("a1", url, Duration::from_secs(754), HOUR, Instant::now());
        assert_eq!(library.starting("a1"), Duration::from_secs(754));
        library.finished("a1", url, HOUR);
        assert_eq!(library.starting("a1"), Duration::ZERO);
        let progress = library.progress("a1").unwrap();
        assert!(!progress.played, "replaying it starts it over");
        assert_eq!(progress.position_ms, 0);
    }
}
