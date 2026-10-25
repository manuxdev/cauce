//! The same song from another provider, for a track its own account cannot play, such as one
//! from a free Spotify account kept only to browse.

use music::Track;

/// The first playable track in `found` with the title and first artist of `wanted`, matched
/// as the app's own substitute does: case aside, and without what follows a dash or a bracket.
pub fn same_song<'a>(wanted: &Track, found: &'a [Track]) -> Option<&'a Track> {
    let title = bare(&wanted.name);
    let artist = first_artist(&wanted.artists);
    found.iter().find(|track| {
        track.playable && bare(&track.name) == title && first_artist(&track.artists) == artist
    })
}

/// The title without what follows a dash or opens a bracket, lowercased.
fn bare(title: &str) -> String {
    let cut = [" - ", "(", "["]
        .iter()
        .filter_map(|mark| title.find(mark))
        .min()
        .unwrap_or(title.len());
    title[..cut].trim().to_lowercase()
}

fn first_artist(artists: &str) -> String {
    let lower = artists.to_lowercase();
    let cut = [",", "&", " feat. ", " feat ", " ft. ", " ft "]
        .iter()
        .filter_map(|mark| lower.find(mark))
        .min()
        .unwrap_or(lower.len());
    lower[..cut].trim().to_owned()
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use super::*;

    fn track(name: &str, artists: &str, playable: bool) -> Track {
        Track {
            id: Some(name.to_owned()),
            name: name.to_owned(),
            playable,
            artists: artists.to_owned(),
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
    fn the_same_title_and_first_artist_match_ignoring_case_and_extras() {
        let wanted = track("Marea Alta", "Lucía Ferrer, Bruma", true);
        let found = [
            track("Marea Alta", "Otra Banda", true),
            track("marea alta - Remastered", "lucía ferrer feat. Bruma", false),
            track("Marea Alta (Live)", "Lucía Ferrer & Bruma", true),
        ];
        assert_eq!(
            same_song(&wanted, &found).map(|track| track.name.as_str()),
            Some("Marea Alta (Live)")
        );
    }

    #[test]
    fn nothing_matches_another_song() {
        let wanted = track("Marea Alta", "Lucía Ferrer", true);
        assert!(same_song(&wanted, &[track("Marea Baja", "Lucía Ferrer", true)]).is_none());
    }
}
