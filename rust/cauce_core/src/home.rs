//! A home feed made of the user's own library, for a provider that recommends nothing of its
//! own (Deezer's gateway has no home upstream reads).

use music::{Album, GenreItem, GenreSection, HomeFeed, Playlist, SavedArtist, Track};

/// Whether a feed has nothing to show.
pub fn empty(feed: &HomeFeed) -> bool {
    feed.quick_picks.as_ref().is_none_or(Vec::is_empty)
        && feed.listen_again.is_empty()
        && feed.sections.iter().all(|section| section.items.is_empty())
}

/// Quick picks from a radio of the user's favorites, the recommendations made from them, then
/// their playlists, albums and artists; each a shelf only when it has something.
pub fn from_library(
    radio: Vec<Track>,
    recommended: Vec<GenreSection>,
    playlists: Vec<Playlist>,
    albums: Vec<Album>,
    artists: Vec<SavedArtist>,
) -> HomeFeed {
    let library = [
        (
            "Your playlists",
            playlists
                .into_iter()
                .map(GenreItem::Playlist)
                .collect::<Vec<_>>(),
        ),
        (
            "Saved albums",
            albums.into_iter().map(GenreItem::Album).collect(),
        ),
        (
            "Your artists",
            artists.into_iter().map(GenreItem::Artist).collect(),
        ),
    ]
    .into_iter()
    .filter(|(_, items)| !items.is_empty())
    .map(|(title, items)| GenreSection {
        title: title.to_owned(),
        items,
    });
    let sections = recommended
        .into_iter()
        .chain(library)
        .filter(|section| !section.items.is_empty())
        .collect();
    HomeFeed {
        listen_again: Vec::new(),
        quick_picks: (!radio.is_empty()).then_some(radio),
        sections,
    }
}

/// Up to `count` favorites by different artists, in the order they were liked, to seed
/// recommendations that do not all sound alike.
pub fn seeds(saved: &[Track], count: usize) -> Vec<&Track> {
    let mut artists = Vec::new();
    let mut seeds = Vec::new();
    for track in saved {
        let artist = track
            .artist_refs
            .first()
            .and_then(|artist| artist.id.as_deref());
        let (Some(artist), Some(_)) = (artist, track.id.as_deref()) else {
            continue;
        };
        if artists.contains(&artist) {
            continue;
        }
        artists.push(artist);
        seeds.push(track);
        if seeds.len() == count {
            break;
        }
    }
    seeds
}

#[cfg(test)]
mod tests {
    use super::*;
    use music::ArtistRef;
    use std::time::Duration;

    fn track(id: &str, artist: &str) -> Track {
        Track {
            id: Some(id.to_owned()),
            name: id.to_owned(),
            playable: true,
            artists: artist.to_owned(),
            artist_refs: vec![ArtistRef {
                name: artist.to_owned(),
                id: Some(artist.to_owned()),
            }],
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
    fn seeds_skip_an_artist_already_seeded() {
        let saved = [track("a1", "a"), track("a2", "a"), track("b1", "b")];
        let ids: Vec<_> = seeds(&saved, 3)
            .iter()
            .map(|track| track.name.as_str())
            .collect();
        assert_eq!(ids, ["a1", "b1"]);
    }

    #[test]
    fn seeds_stop_at_the_count() {
        let saved = [track("a1", "a"), track("b1", "b"), track("c1", "c")];
        assert_eq!(seeds(&saved, 2).len(), 2);
    }

    #[test]
    fn seeds_skip_a_track_without_an_artist_id() {
        let mut anonymous = track("x", "x");
        anonymous.artist_refs[0].id = None;
        assert!(seeds(&[anonymous], 3).is_empty());
    }

    #[test]
    fn recommendations_come_after_quick_picks_and_before_the_library() {
        let picked = GenreSection {
            title: "Mix".to_owned(),
            items: vec![GenreItem::Track(track("t", "a"))],
        };
        let feed = from_library(
            vec![track("q", "a")],
            vec![picked],
            Vec::new(),
            Vec::new(),
            vec![artist("Bjork")],
        );
        let titles: Vec<_> = feed
            .sections
            .iter()
            .map(|section| section.title.as_str())
            .collect();
        assert_eq!(titles, ["Mix", "Your artists"]);
    }

    fn artist(name: &str) -> SavedArtist {
        SavedArtist {
            id: name.to_owned(),
            name: name.to_owned(),
            cover: None,
            added_at: None,
        }
    }

    #[test]
    fn a_default_feed_is_empty() {
        assert!(empty(&HomeFeed::default()));
    }

    #[test]
    fn a_feed_with_empty_shelves_is_empty() {
        let feed = HomeFeed {
            quick_picks: Some(Vec::new()),
            sections: vec![GenreSection {
                title: "Nothing".to_owned(),
                items: Vec::new(),
            }],
            ..HomeFeed::default()
        };
        assert!(empty(&feed));
    }

    #[test]
    fn the_library_makes_only_the_shelves_it_fills() {
        let feed = from_library(
            Vec::new(),
            Vec::new(),
            Vec::new(),
            Vec::new(),
            vec![artist("Bjork")],
        );
        assert_eq!(feed.quick_picks, None);
        assert_eq!(feed.sections.len(), 1);
        assert_eq!(feed.sections[0].title, "Your artists");
        assert!(!empty(&feed));
    }

    #[test]
    fn an_empty_library_makes_an_empty_feed() {
        assert!(empty(&from_library(
            Vec::new(),
            Vec::new(),
            Vec::new(),
            Vec::new(),
            Vec::new()
        )));
    }
}
