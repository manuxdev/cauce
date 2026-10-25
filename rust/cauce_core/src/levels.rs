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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_level_is_the_bands_average_kept_inside_zero_to_one() {
        assert_eq!(channel_level(&[]), 0.0);
        assert!((channel_level(&[0.2, 0.4, 0.6]) - 0.4).abs() < 1e-6);
        assert_eq!(channel_level(&[2.0, -1.0]), 0.5);
    }
}
