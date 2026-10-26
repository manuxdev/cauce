//! A log file in the app's cache folder. A phone has no terminal to read upstream's warnings in,
//! and those warnings are often the only record of why a provider gave up.

use std::fs::{File, OpenOptions};
use std::io::Write as _;
use std::path::Path;
use std::sync::Mutex;
use std::time::{SystemTime, UNIX_EPOCH};

use log::{Level, LevelFilter, Metadata, Record};

/// The file the log is written to, inside the cache folder.
pub const FILE: &str = "cauce.log";
/// Past this size the log starts over at launch, so it never grows without bound.
const LIMIT: u64 = 2 * 1024 * 1024;

/// Whether a record is kept: debug and up from the app's own crates, warnings and up from the
/// rest, whose debug output is mostly connection chatter.
fn kept(target: &str, level: Level) -> bool {
    let krate = target.split("::").next().unwrap_or(target);
    let ours = matches!(
        krate,
        "music" | "cauce_core" | "cauce_bridge" | "storage"
    );
    match ours {
        true => level <= Level::Debug,
        false => level <= Level::Warn,
    }
}

struct FileLogger(Mutex<File>);

impl log::Log for FileLogger {
    fn enabled(&self, metadata: &Metadata) -> bool {
        kept(metadata.target(), metadata.level())
    }

    fn log(&self, record: &Record) {
        if !self.enabled(record.metadata()) {
            return;
        }
        let seconds = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_or(0, |since| since.as_secs());
        let line = format!(
            "{seconds} {} {}: {}\n",
            record.level(),
            record.target(),
            record.args()
        );
        if let Ok(mut file) = self.0.lock() {
            file.write_all(line.as_bytes()).ok();
        }
    }

    fn flush(&self) {
        if let Ok(mut file) = self.0.lock() {
            file.flush().ok();
        }
    }
}

/// Starts writing the log under `folder`. A second call, or a logger already installed, keeps
/// the first.
pub fn init(folder: &Path) {
    let path = folder.join(FILE);
    let oversized = std::fs::metadata(&path).is_ok_and(|meta| meta.len() > LIMIT);
    let file = OpenOptions::new()
        .create(true)
        .append(!oversized)
        .write(true)
        .truncate(oversized)
        .open(&path);
    let Ok(file) = file else {
        return;
    };
    if log::set_boxed_logger(Box::new(FileLogger(Mutex::new(file)))).is_ok() {
        log::set_max_level(LevelFilter::Debug);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn own_crates_log_from_debug() {
        assert!(kept("music::subsonic", Level::Debug));
        assert!(kept("cauce_core", Level::Info));
        assert!(!kept("music::subsonic", Level::Trace));
    }

    #[test]
    fn other_crates_log_only_warnings() {
        assert!(kept("reqwest::connect", Level::Warn));
        assert!(kept("opensubsonic", Level::Error));
        assert!(!kept("hyper::proto", Level::Debug));
        assert!(!kept("rustls", Level::Info));
    }

    #[test]
    fn a_crate_named_like_ours_is_not_ours() {
        assert!(!kept("musicbrainz", Level::Debug));
    }
}
