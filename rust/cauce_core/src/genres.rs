//! Deezer's genres through its public API, which upstream's Deezer provider does not browse:
//! the genre list with a picture each, and a genre's editorial charts as shelves. The ids are
//! Deezer's own, so whatever they list plays and opens through the signed-in provider.

use std::time::Duration;

use anyhow::{Context as _, Result};
use music::{
    Album, ArtistRef, Genre, GenreDetail, GenreItem, GenreSection, Playlist, ReleaseType,
    SavedArtist, Track,
};
use serde::Deserialize;

const API: &str = "https://api.deezer.com";

/// Every genre but "All", which is the whole catalogue rather than a style.
pub async fn genres(http: &reqwest::Client) -> Result<Vec<Genre>> {
    let body = get(http, &format!("{API}/genre")).await?;
    parse_genres(&body)
}

/// A genre's charts: its top tracks, albums, artists and playlists.
pub async fn genre(http: &reqwest::Client, id: &str, titles: &Titles) -> Result<GenreDetail> {
    let body = get(http, &format!("{API}/editorial/{id}/charts")).await?;
    parse_charts(&body, titles)
}

/// The shelf titles, in the listener's language.
pub struct Titles {
    pub tracks: String,
    pub albums: String,
    pub artists: String,
    pub playlists: String,
}

async fn get(http: &reqwest::Client, url: &str) -> Result<String> {
    let response = http
        .get(url)
        .timeout(Duration::from_secs(10))
        .send()
        .await
        .with_context(|| format!("cannot reach {url}"))?;
    response
        .error_for_status()?
        .text()
        .await
        .context("cannot read the answer")
}

#[derive(Deserialize)]
struct List<T> {
    #[serde(default = "Vec::new")]
    data: Vec<T>,
}

#[derive(Deserialize)]
struct RawGenre {
    id: u64,
    name: String,
    picture_xl: Option<String>,
}

#[derive(Deserialize)]
struct Charts {
    tracks: Option<List<RawTrack>>,
    albums: Option<List<RawAlbum>>,
    artists: Option<List<RawArtist>>,
    playlists: Option<List<RawPlaylist>>,
}

#[derive(Deserialize)]
struct RawArtist {
    id: u64,
    name: String,
    picture_xl: Option<String>,
}

#[derive(Deserialize)]
struct RawTrack {
    id: u64,
    title: String,
    duration: u64,
    #[serde(default)]
    explicit_lyrics: bool,
    artist: RawArtist,
    album: RawTrackAlbum,
}

#[derive(Deserialize)]
struct RawTrackAlbum {
    id: u64,
    title: String,
    cover_xl: Option<String>,
}

#[derive(Deserialize)]
struct RawAlbum {
    id: u64,
    title: String,
    cover_xl: Option<String>,
    record_type: Option<String>,
    artist: RawArtist,
}

#[derive(Deserialize)]
struct RawPlaylist {
    id: u64,
    title: String,
    picture_xl: Option<String>,
    #[serde(default)]
    nb_tracks: u32,
}

fn parse_genres(body: &str) -> Result<Vec<Genre>> {
    let list: List<RawGenre> = serde_json::from_str(body).context("the genres do not read")?;
    Ok(list
        .data
        .into_iter()
        .filter(|genre| genre.id != 0)
        .map(|genre| Genre {
            id: genre.id.to_string(),
            name: genre.name,
            cover: genre.picture_xl,
        })
        .collect())
}

fn parse_charts(body: &str, titles: &Titles) -> Result<GenreDetail> {
    let charts: Charts = serde_json::from_str(body).context("the charts do not read")?;
    let shelf = |title: &str, items: Vec<GenreItem>| GenreSection {
        title: title.to_owned(),
        items,
    };
    let sections = [
        shelf(
            &titles.tracks,
            charts
                .tracks
                .map_or_else(Vec::new, |list| list.data.into_iter().map(track).collect()),
        ),
        shelf(
            &titles.albums,
            charts
                .albums
                .map_or_else(Vec::new, |list| list.data.into_iter().map(album).collect()),
        ),
        shelf(
            &titles.artists,
            charts
                .artists
                .map_or_else(Vec::new, |list| list.data.into_iter().map(artist).collect()),
        ),
        shelf(
            &titles.playlists,
            charts.playlists.map_or_else(Vec::new, |list| {
                list.data.into_iter().map(playlist).collect()
            }),
        ),
    ];
    Ok(GenreDetail {
        name: String::new(),
        sections: sections
            .into_iter()
            .filter(|section| !section.items.is_empty())
            .collect(),
    })
}

fn artist_ref(artist: &RawArtist) -> ArtistRef {
    ArtistRef {
        name: artist.name.clone(),
        id: Some(artist.id.to_string()),
    }
}

fn track(raw: RawTrack) -> GenreItem {
    GenreItem::Track(Track {
        id: Some(raw.id.to_string()),
        name: raw.title,
        playable: true,
        artists: raw.artist.name.clone(),
        artist_refs: vec![artist_ref(&raw.artist)],
        album: raw.album.title,
        album_id: Some(raw.album.id.to_string()),
        cover: raw.album.cover_xl,
        duration: Duration::from_secs(raw.duration),
        added_at: None,
        added_by: None,
        playcount: None,
        popularity: 0,
        explicit: raw.explicit_lyrics,
        track_number: 0,
        disc_number: 0,
        tags: Vec::new(),
        languages: Vec::new(),
        credits: Vec::new(),
    })
}

fn album(raw: RawAlbum) -> GenreItem {
    GenreItem::Album(Album {
        id: raw.id.to_string(),
        name: raw.title,
        artists: raw.artist.name.clone(),
        artist_refs: vec![artist_ref(&raw.artist)],
        cover: raw.cover_xl.clone(),
        cover_large: raw.cover_xl,
        release_type: match raw.record_type.as_deref() {
            Some("single") => ReleaseType::Single,
            Some("ep") => ReleaseType::Ep,
            Some("compile") => ReleaseType::Compilation,
            _ => ReleaseType::Album,
        },
        year: 0,
        track_count: 0,
        release_date: String::new(),
        label: String::new(),
        copyrights: Vec::new(),
        added_at: None,
    })
}

fn artist(raw: RawArtist) -> GenreItem {
    GenreItem::Artist(SavedArtist {
        id: raw.id.to_string(),
        name: raw.name,
        cover: raw.picture_xl,
        added_at: None,
    })
}

fn playlist(raw: RawPlaylist) -> GenreItem {
    GenreItem::Playlist(Playlist {
        id: raw.id.to_string(),
        name: raw.title,
        owner: "Deezer".to_owned(),
        owner_id: String::new(),
        owned: false,
        collaborative: false,
        blend: false,
        public: true,
        cover: raw.picture_xl,
        track_count: raw.nb_tracks,
        modified_at: None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn titles() -> Titles {
        Titles {
            tracks: "Songs".to_owned(),
            albums: "Albums".to_owned(),
            artists: "Artists".to_owned(),
            playlists: "Playlists".to_owned(),
        }
    }

    #[test]
    fn the_whole_catalogue_is_not_a_genre() {
        let body = r#"{"data":[
            {"id":0,"name":"All","picture_xl":"a"},
            {"id":152,"name":"Rock","picture_xl":"https://rock"}
        ]}"#;
        let genres = parse_genres(body).unwrap();
        assert_eq!(genres.len(), 1);
        assert_eq!(genres[0].id, "152");
        assert_eq!(genres[0].cover.as_deref(), Some("https://rock"));
    }

    #[test]
    fn charts_become_shelves_and_empty_ones_go() {
        let body = r#"{
            "tracks":{"data":[{"id":1,"title":"Song","duration":200,"explicit_lyrics":true,
                "artist":{"id":7,"name":"Band","picture_xl":null},
                "album":{"id":9,"title":"Record","cover_xl":"https://cover"}}]},
            "albums":{"data":[{"id":9,"title":"Record","cover_xl":"https://cover","record_type":"single",
                "artist":{"id":7,"name":"Band"}}]},
            "artists":{"data":[]},
            "playlists":{"data":[{"id":5,"title":"Best of","picture_xl":"https://list","nb_tracks":50}]},
            "podcasts":{"data":[]}
        }"#;
        let detail = parse_charts(body, &titles()).unwrap();
        let shelves: Vec<&str> = detail
            .sections
            .iter()
            .map(|section| section.title.as_str())
            .collect();
        assert_eq!(shelves, ["Songs", "Albums", "Playlists"]);
        let GenreItem::Track(track) = &detail.sections[0].items[0] else {
            panic!("the first shelf holds tracks");
        };
        assert_eq!(track.id.as_deref(), Some("1"));
        assert_eq!(track.album_id.as_deref(), Some("9"));
        assert_eq!(track.artist_refs[0].id.as_deref(), Some("7"));
        assert_eq!(track.duration, Duration::from_secs(200));
        let GenreItem::Album(album) = &detail.sections[1].items[0] else {
            panic!("the second shelf holds albums");
        };
        assert_eq!(album.release_type, ReleaseType::Single);
    }
}
