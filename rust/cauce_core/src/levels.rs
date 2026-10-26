//! How loud each channel is right now, from the engine's running spectrum, for the player's VU
//! meters, its ripple, and the song waves built while it plays.

/// One channel's level, 0 to 1: the average of its spectrum bands, so it rises with the music as
/// a whole rather than with any one band. No bands is silence.
pub fn channel_level(bands: &[f32]) -> f32 {
    if bands.is_empty() {
        return 0.0;
    }
    let sum: f32 = bands.iter().map(|band| band.clamp(0.0, 1.0)).sum();
    sum / bands.len() as f32
}

/// How many of the spectrum's lowest bands are the bass. The bands run log-spaced from 100 Hz
/// to 6 kHz in 32, so the first five reach about 190 Hz: the kick drum and the bass line, where
/// a song's beat is.
pub const BASS_BANDS: usize = 5;

/// How loud the bass is, 0 to 1, from one channel's bands: what the beat is told from.
pub fn bass(bands: &[f32]) -> f32 {
    channel_level(&bands[..bands.len().min(BASS_BANDS)])
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_level_is_the_bands_average_kept_inside_zero_to_one() {
        assert_eq!(channel_level(&[]), 0.0);
        assert!((channel_level(&[0.2, 0.4, 0.6]) - 0.4).abs() < 1e-6);
        assert_eq!(channel_level(&[2.0, -1.0]), 0.5);
    }

    #[test]
    fn the_bass_is_the_lowest_bands_alone() {
        let mut bands = vec![0.0; 32];
        bands[..BASS_BANDS].fill(0.8);
        assert!((bass(&bands) - 0.8).abs() < 1e-6);
        bands[..BASS_BANDS].fill(0.0);
        bands[BASS_BANDS..].fill(1.0);
        assert_eq!(bass(&bands), 0.0);
        assert_eq!(bass(&[]), 0.0);
    }
}
