//! The playback preferences, kept as JSON in the data folder: what the engine starts with, the
//! equalizer and how much the track cache may hold.

use std::path::{Path, PathBuf};

use music::Quality;
use music::equalizer::{Curve, Preset};
use serde::{Deserialize, Serialize};

/// Gains of the ten graphic bands, in dB.
pub type Bands = [f64; 10];

pub const FILE: &str = "playback.json";

/// How long a download may go unplayed before freeing space removes it, in seconds.
pub const STALE_AFTER: u64 = 90 * 24 * 60 * 60;

/// The cache size the slider allows, in GB.
pub const CACHE_GB_RANGE: (u64, u64) = (1, 64);

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(default, rename_all = "kebab-case")]
pub struct PlaybackSettings {
    pub normalisation: bool,
    pub gapless: bool,
    /// A [`Quality`] id, for Wi-Fi; anything unknown reads as the best level.
    pub quality: String,
    /// The [`Quality`] id on mobile data.
    pub quality_cellular: String,
    /// On mobile data, the lowest quality and no fetching ahead.
    pub data_saver: bool,
    /// When the queue runs out, play on with tracks like the last one.
    pub continue_similar: bool,
    /// Whether repeat comes back as it was on the next launch.
    pub remember_repeat: bool,
    /// Whether the last queue comes back, paused, on the next launch.
    pub resume_last: bool,
    /// Play when headphones connect, not only when they come back after dropping off.
    pub resume_on_connect: bool,
    /// Downloads wait for Wi-Fi.
    pub downloads_wifi_only: bool,
    /// Every track liked is downloaded too.
    pub download_likes: bool,
    /// The [`Quality`] id downloads are fetched at.
    pub download_quality: String,
    /// Downloads not played for [`STALE_AFTER`] are removed on their own.
    pub free_space: bool,
    pub equalizer: bool,
    pub bands: Bands,
    /// Whether tracks that played are kept for the next time.
    pub keep_tracks: bool,
    pub cache_gb: u64,
}

impl Default for PlaybackSettings {
    fn default() -> Self {
        Self {
            normalisation: false,
            gapless: true,
            quality: Quality::default().id().to_owned(),
            quality_cellular: Quality::Normal.id().to_owned(),
            data_saver: false,
            continue_similar: true,
            remember_repeat: true,
            resume_last: true,
            resume_on_connect: false,
            downloads_wifi_only: true,
            download_likes: false,
            download_quality: Quality::default().id().to_owned(),
            free_space: false,
            equalizer: false,
            bands: [0.; 10],
            keep_tracks: true,
            cache_gb: 2,
        }
    }
}

impl PlaybackSettings {
    pub fn quality(&self) -> Quality {
        Quality::from_id(&self.quality).unwrap_or_default()
    }

    pub fn download_quality(&self) -> Quality {
        Quality::from_id(&self.download_quality).unwrap_or_default()
    }

    /// The quality to stream at, on mobile data or not.
    pub fn stream_quality(&self, cellular: bool) -> Quality {
        match (cellular, self.data_saver) {
            (false, _) => self.quality(),
            (true, true) => Quality::Low,
            (true, false) => Quality::from_id(&self.quality_cellular).unwrap_or(Quality::Normal),
        }
    }

    /// Whether the next track is fetched ahead, which saving data on mobile data stops.
    pub fn preloads(&self, cellular: bool) -> bool {
        !(cellular && self.data_saver)
    }

    pub fn curve(&self) -> Curve {
        Curve::bands(&self.bands)
    }

    /// The cache limit in bytes.
    pub fn cache_bytes(&self) -> u64 {
        self.cache_gb.clamp(CACHE_GB_RANGE.0, CACHE_GB_RANGE.1) << 30
    }

    /// Whether going from `self` to `next` needs a new engine: what an engine reads only when it
    /// starts. The equalizer and the cache reach a running one.
    pub fn restarts(&self, next: &Self) -> bool {
        self.normalisation != next.normalisation
            || self.gapless != next.gapless
            || self.quality() != next.quality()
    }

    /// The saved settings under `folder`, or the defaults when there are none or they do not read.
    pub fn load(folder: &Path) -> Self {
        std::fs::read_to_string(path(folder))
            .ok()
            .and_then(|text| serde_json::from_str(&text).ok())
            .unwrap_or_default()
    }

    pub fn save(&self, folder: &Path) {
        match serde_json::to_string_pretty(self) {
            Ok(text) => {
                if let Err(error) = std::fs::write(path(folder), text) {
                    log::warn!("settings: cannot save the playback settings: {error}");
                }
            }
            Err(error) => log::warn!("settings: cannot encode the playback settings: {error}"),
        }
    }
}

/// Every equalizer preset as its id and band gains.
pub fn presets() -> Vec<(&'static str, Bands)> {
    Preset::ALL
        .iter()
        .map(|preset| {
            let mut bands = [0.; 10];
            for (band, filter) in bands.iter_mut().zip(preset.curve().filters()) {
                *band = filter.gain();
            }
            (preset.id(), bands)
        })
        .collect()
}

fn path(folder: &Path) -> PathBuf {
    folder.join(FILE)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn downloads_keep_their_own_quality() {
        let settings = PlaybackSettings {
            quality: "low".to_owned(),
            download_quality: "high".to_owned(),
            ..Default::default()
        };
        assert_eq!(settings.download_quality(), Quality::High);
        assert_eq!(
            PlaybackSettings::default().download_quality(),
            Quality::default()
        );
        assert!(!PlaybackSettings::default().free_space);
    }

    #[test]
    fn the_last_song_comes_back_unless_turned_off() {
        assert!(PlaybackSettings::default().resume_last);
        let old: PlaybackSettings = serde_json::from_str("{}").unwrap();
        assert!(old.resume_last);
    }

    #[test]
    fn an_unknown_quality_reads_as_the_best() {
        let settings = PlaybackSettings {
            quality: "studio".to_owned(),
            ..PlaybackSettings::default()
        };
        assert_eq!(settings.quality(), Quality::default());
    }

    #[test]
    fn the_cache_limit_stays_in_range() {
        let tiny = PlaybackSettings {
            cache_gb: 0,
            ..PlaybackSettings::default()
        };
        assert_eq!(tiny.cache_bytes(), 1 << 30);
        let huge = PlaybackSettings {
            cache_gb: 500,
            ..PlaybackSettings::default()
        };
        assert_eq!(huge.cache_bytes(), 64 << 30);
    }

    #[test]
    fn only_engine_settings_restart_it() {
        let base = PlaybackSettings::default();
        let mut equalized = base.clone();
        equalized.equalizer = true;
        equalized.bands[0] = 6.;
        equalized.cache_gb = 8;
        assert!(!base.restarts(&equalized));
        let mut lower = base.clone();
        lower.quality = Quality::Normal.id().to_owned();
        assert!(base.restarts(&lower));
    }

    #[test]
    fn missing_fields_take_their_defaults() {
        let settings: PlaybackSettings = serde_json::from_str(r#"{"gapless": false}"#).unwrap();
        assert!(!settings.gapless);
        assert_eq!(settings.cache_gb, 2);
    }

    #[test]
    fn settings_survive_a_save() {
        let folder = std::env::temp_dir().join(format!("cauce-settings-{}", std::process::id()));
        std::fs::create_dir_all(&folder).unwrap();
        let mut settings = PlaybackSettings::default();
        settings.bands[3] = -4.5;
        settings.save(&folder);
        assert_eq!(PlaybackSettings::load(&folder), settings);
        std::fs::remove_dir_all(&folder).ok();
    }

    #[test]
    fn the_flat_preset_is_flat() {
        let presets = presets();
        assert_eq!(presets.len(), 12);
        assert!(
            presets
                .iter()
                .any(|(id, bands)| *id == "flat" && bands.iter().all(|gain| *gain == 0.))
        );
    }

    #[test]
    fn mobile_data_streams_at_its_own_quality_and_lower_still_saving_data() {
        let settings = PlaybackSettings {
            quality: Quality::HiRes.id().to_owned(),
            quality_cellular: Quality::Normal.id().to_owned(),
            ..PlaybackSettings::default()
        };
        assert_eq!(settings.stream_quality(false), Quality::HiRes);
        assert_eq!(settings.stream_quality(true), Quality::Normal);
        let saving = PlaybackSettings {
            data_saver: true,
            ..settings
        };
        assert_eq!(saving.stream_quality(true), Quality::Low);
        assert_eq!(saving.stream_quality(false), Quality::HiRes);
        assert!(saving.preloads(false));
        assert!(!saving.preloads(true));
    }

    #[test]
    fn new_preferences_default_as_the_design_shows_them() {
        let settings = PlaybackSettings::default();
        assert!(settings.continue_similar);
        assert!(settings.remember_repeat);
        assert!(settings.downloads_wifi_only);
        assert!(!settings.data_saver);
        assert!(!settings.resume_on_connect);
        assert!(!settings.download_likes);
    }
}
