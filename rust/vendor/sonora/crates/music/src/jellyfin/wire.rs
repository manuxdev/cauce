//! What Jellyfin answers with, and how it becomes the app's models.

use std::time::Duration;

use serde::Deserialize;

use crate::engine::Loudness;
use crate::escape;
use crate::jellyfin::Flavor;
use crate::jellyfin::auth::Credentials;
use crate::{
    Album, ArtistRef, Genre, GenreItem, GenreSection, HomeFeed, Playlist, ReleaseType, SavedArtist,
    Track, iso_8601_to_epoch,
};

/// How many ticks Jellyfin counts in a second.
const TICKS_PER_SECOND: u64 = 10_000_000;
const COVER: u32 = 300;
const COVER_LARGE: u32 = 600;

#[derive(Deserialize)]
#[serde(rename_all = "PascalCase")]
pub struct Items {
    #[serde(default)]
    pub items: Vec<Item>,
    pub total_record_count: Option<usize>,
}

/// One entry of a listing: a track, album, artist or playlist. Jellyfin sends `null` for many
/// fields it has nothing for, so every one of them is optional.
#[derive(Clone, Default, Deserialize)]
#[serde(rename_all = "PascalCase", default)]
pub struct Item {
    pub id: String,
    pub name: Option<String>,
    pub run_time_ticks: Option<u64>,
    pub index_number: Option<u32>,
    pub parent_index_number: Option<u32>,
    pub album: Option<String>,
    pub album_id: Option<String>,
    pub album_primary_image_tag: Option<String>,
    pub artists: Option<Vec<String>>,
    pub artist_items: Option<Vec<Named>>,
    pub album_artist: Option<String>,
    pub album_artists: Option<Vec<Named>>,
    pub image_tags: Option<ImageTags>,
    pub production_year: Option<i32>,
    pub date_created: Option<String>,
    pub child_count: Option<u32>,
    pub user_data: Option<UserData>,
    pub normalization_gain: Option<f32>,
    pub overview: Option<String>,
    /// Which entry of a playlist this is, from `/Playlists/{id}/Items`.
    pub playlist_item_id: Option<String>,
    /// The files of a track. Emby lists its lyrics among their streams.
    pub media_sources: Option<Vec<MediaSource>>,
}

#[derive(Clone, Default, Deserialize)]
#[serde(rename_all = "PascalCase", default)]
pub struct MediaSource {
    pub id: Option<String>,
    pub media_streams: Vec<MediaStream>,
}

#[derive(Clone, Default, Deserialize)]
#[serde(rename_all = "PascalCase", default)]
pub struct MediaStream {
    #[serde(rename = "Type")]
    pub kind: Option<String>,
    pub index: Option<u32>,
    pub is_text_subtitle_stream: bool,
}

#[derive(Clone, Default, Deserialize)]
#[serde(rename_all = "PascalCase", default)]
pub struct Named {
    pub id: Option<String>,
    pub name: Option<String>,
}

#[derive(Clone, Default, Deserialize)]
#[serde(rename_all = "PascalCase", default)]
pub struct ImageTags {
    pub primary: Option<String>,
}

#[derive(Clone, Default, Deserialize)]
#[serde(rename_all = "PascalCase", default)]
pub struct UserData {
    pub play_count: Option<u64>,
    pub is_favorite: Option<bool>,
}

/// `/Playlists/{id}/Users/{userId}`: whether that user may change the playlist.
#[derive(Clone, Default, Deserialize)]
#[serde(rename_all = "PascalCase", default)]
pub struct PlaylistUser {
    pub can_edit: bool,
}

/// `/Playlists/{id}`: the playlist's entries by track id, in order, duplicates included.
#[derive(Default, Deserialize)]
#[serde(rename_all = "PascalCase", default)]
pub struct PlaylistEntries {
    pub item_ids: Vec<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "PascalCase")]
pub struct Authenticated {
    pub access_token: String,
    pub user: User,
}

#[derive(Deserialize)]
#[serde(rename_all = "PascalCase")]
pub struct User {
    pub id: String,
    pub name: String,
}

impl Item {
    fn primary(&self) -> Option<&str> {
        self.image_tags.as_ref()?.primary.as_deref()
    }
}

pub fn duration(ticks: Option<u64>) -> Duration {
    let ticks = ticks.unwrap_or(0);
    Duration::from_secs(ticks / TICKS_PER_SECOND)
        + Duration::from_nanos((ticks % TICKS_PER_SECOND) * 100)
}

/// The picture of item `id` as tagged. The tag changes with the picture, so the url stays the
/// same until then and image caches hold it. The demo and a default server serve pictures with
/// no sign-in, so the url carries no token.
pub fn cover(server: &str, id: &str, tag: Option<&str>, height: u32) -> Option<String> {
    let tag = tag.filter(|tag| !tag.is_empty())?;
    Some(format!(
        "{server}/Items/{}/Images/Primary?maxHeight={height}&tag={}",
        escape::component(id),
        escape::component(tag)
    ))
}

/// The track's own picture, or its album's.
fn track_cover(item: &Item, server: &str) -> Option<String> {
    cover(server, &item.id, item.primary(), COVER).or_else(|| {
        cover(
            server,
            item.album_id.as_deref()?,
            item.album_primary_image_tag.as_deref(),
            COVER,
        )
    })
}

fn refs(named: Option<&Vec<Named>>) -> Vec<ArtistRef> {
    named
        .into_iter()
        .flatten()
        .filter_map(|artist| {
            Some(ArtistRef {
                name: artist.name.clone().filter(|name| !name.is_empty())?,
                id: artist.id.clone().filter(|id| !id.is_empty()),
            })
        })
        .collect()
}

fn joined(refs: &[ArtistRef]) -> String {
    refs.iter()
        .map(|artist| artist.name.as_str())
        .collect::<Vec<_>>()
        .join(", ")
}

pub fn track(item: Item, server: &str) -> Track {
    let cover = track_cover(&item, server);
    let artist_refs = refs(item.artist_items.as_ref());
    let artists = match artist_refs.is_empty() {
        true => item.artists.unwrap_or_default().join(", "),
        false => joined(&artist_refs),
    };
    Track {
        id: Some(item.id),
        name: item.name.unwrap_or_default(),
        playable: true,
        artists,
        artist_refs,
        album: item.album.unwrap_or_default(),
        album_id: item.album_id.filter(|id| !id.is_empty()),
        cover,
        duration: duration(item.run_time_ticks),
        added_at: iso_8601_to_epoch(item.date_created.as_deref()),
        added_by: None,
        playcount: item.user_data.and_then(|data| data.play_count),
        popularity: 0,
        explicit: false,
        track_number: item.index_number.unwrap_or(0),
        disc_number: item.parent_index_number.unwrap_or(1).max(1),
        tags: Vec::new(),
        languages: Vec::new(),
        credits: Vec::new(),
    }
}

/// Jellyfin's `NormalizationGain` is the gain in dB that brings a track to -18 LUFS, which is
/// what a ReplayGain gain is. It sends no peak.
pub fn loudness(item: &Item) -> Option<Loudness> {
    item.normalization_gain
        .map(|gain| Loudness::replay_gain(gain, None))
}

pub fn album(item: Item, server: &str) -> Album {
    let mut artist_refs = refs(item.album_artists.as_ref());
    if artist_refs.is_empty() {
        artist_refs = refs(item.artist_items.as_ref());
    }
    let artists = match (&item.album_artist, artist_refs.is_empty()) {
        (Some(name), _) if !name.is_empty() => name.clone(),
        _ => joined(&artist_refs),
    };
    let year = item.production_year.unwrap_or(0);
    Album {
        cover: cover(server, &item.id, item.primary(), COVER),
        cover_large: cover(server, &item.id, item.primary(), COVER_LARGE),
        id: item.id,
        name: item.name.unwrap_or_default(),
        artists,
        artist_refs,
        release_type: ReleaseType::Album,
        year,
        track_count: item.child_count.unwrap_or(0),
        release_date: match year {
            0 => String::new(),
            _ => year.to_string(),
        },
        label: String::new(),
        copyrights: Vec::new(),
        added_at: iso_8601_to_epoch(item.date_created.as_deref()),
    }
}

pub fn artist(item: &Item, server: &str) -> SavedArtist {
    SavedArtist {
        id: item.id.clone(),
        name: item.name.clone().unwrap_or_default(),
        cover: cover(server, &item.id, item.primary(), COVER_LARGE),
        added_at: None,
    }
}

/// A playlist, the listener's own when the server says they may edit it.
pub fn playlist(item: Item, server: &str, user: Option<PlaylistUser>) -> Playlist {
    Playlist {
        cover: cover(server, &item.id, item.primary(), COVER),
        id: item.id,
        name: item.name.unwrap_or_default(),
        owner: String::new(),
        owner_id: String::new(),
        owned: user.is_some_and(|user| user.can_edit),
        collaborative: false,
        blend: false,
        public: false,
        track_count: item.child_count.unwrap_or(0),
        modified_at: None,
    }
}

/// The items marked as favorites, so a server that ignored the filter still likes nothing extra.
pub fn favorites(items: Vec<Item>) -> Vec<Item> {
    items
        .into_iter()
        .filter(|item| item.user_data.as_ref().and_then(|data| data.is_favorite) == Some(true))
        .collect()
}

/// How to take one copy of a track out of a playlist.
#[derive(Debug, PartialEq, Eq)]
pub enum Removal {
    /// By the entry's own id.
    Entry(String),
    /// By writing the list back without it, since its entry id names every copy. The 12.x
    /// servers give each entry its track's id, so removing one copy that way removes them all.
    Rewrite,
}

/// How to remove the `copy`-th entry (from 0) of `track_id` from the playlist's `entries`.
pub fn removal(entries: &[Item], track_id: &str, copy: usize) -> Option<Removal> {
    let index = crate::entry_index(
        entries.iter().map(|entry| entry.id.as_str()),
        track_id,
        copy,
    )?;
    let entry = entries[index]
        .playlist_item_id
        .as_deref()
        .filter(|id| !id.is_empty());
    let shared = |id: &str| {
        entries
            .iter()
            .filter(|other| other.playlist_item_id.as_deref() == Some(id))
            .count()
            > 1
    };
    Some(match entry {
        Some(id) if !shared(id) => Removal::Entry(id.to_owned()),
        _ => Removal::Rewrite,
    })
}

/// `ids` without the `copy`-th (from 0) of `track_id`.
pub fn without(mut ids: Vec<String>, track_id: &str, copy: usize) -> Option<Vec<String>> {
    let index = crate::entry_index(ids.iter().map(String::as_str), track_id, copy)?;
    ids.remove(index);
    Some(ids)
}

/// `at` as the UTC date and time Jellyfin reads, to the second.
pub fn iso_8601(at: std::time::SystemTime) -> String {
    let at = time::OffsetDateTime::from(at);
    format!(
        "{:04}-{:02}-{:02}T{:02}:{:02}:{:02}Z",
        at.year(),
        u8::from(at.month()),
        at.day(),
        at.hour(),
        at.minute(),
        at.second()
    )
}

/// `at` as the UTC date and time Emby reads a listen's date in, to the second.
pub fn emby_date(at: std::time::SystemTime) -> String {
    let at = time::OffsetDateTime::from(at);
    format!(
        "{:04}{:02}{:02}{:02}{:02}{:02}",
        at.year(),
        u8::from(at.month()),
        at.day(),
        at.hour(),
        at.minute(),
        at.second()
    )
}

/// Where Emby keeps a track's lyrics: the file and the stream index of its first text
/// subtitle, which on a track is a `.lrc` or `.txt` beside it or lyrics in its tags.
pub fn lyrics_stream(item: &Item) -> Option<(String, u32)> {
    item.media_sources.iter().flatten().find_map(|source| {
        let stream = source.media_streams.iter().find(|stream| {
            stream.kind.as_deref() == Some("Subtitle") && stream.is_text_subtitle_stream
        })?;
        Some((source.id.clone()?, stream.index?))
    })
}

pub fn credentials(
    answer: Authenticated,
    server: &str,
    device_id: &str,
    flavor: Flavor,
) -> Credentials {
    Credentials {
        server: server.to_owned(),
        user_id: answer.user.id,
        username: answer.user.name,
        device_id: device_id.to_owned(),
        token: answer.access_token,
        flavor,
    }
}

pub fn genre(item: Item, server: &str) -> Genre {
    Genre {
        cover: cover(server, &item.id, item.primary(), COVER),
        id: item.id,
        name: item.name.unwrap_or_default(),
    }
}

/// The albums `tracks` come from, each once, in the order the tracks name them, up to `wanted`.
pub fn album_ids(tracks: &[Item], wanted: usize) -> Vec<String> {
    let mut ids: Vec<String> = Vec::new();
    for id in tracks.iter().filter_map(|track| track.album_id.as_deref()) {
        if ids.len() == wanted {
            break;
        }
        if !id.is_empty() && !ids.iter().any(|kept| kept == id) {
            ids.push(id.to_owned());
        }
    }
    ids
}

/// The home feed with Subsonic's shelves and titles: random songs to listen again and as quick
/// picks, then the newest and the most played albums. An empty shelf is left out.
pub fn home(random: Vec<Track>, newest: Vec<Album>, most_played: Vec<Album>) -> HomeFeed {
    let sections = [
        ("Newest albums", newest),
        ("Most played albums", most_played),
    ]
    .into_iter()
    .filter(|(_, albums)| !albums.is_empty())
    .map(|(title, albums)| GenreSection {
        title: title.to_owned(),
        items: albums.into_iter().map(GenreItem::Album).collect(),
    })
    .collect();
    HomeFeed {
        listen_again: random
            .iter()
            .take(10)
            .cloned()
            .map(GenreItem::Track)
            .collect(),
        quick_picks: Some(random.into_iter().take(15).collect()),
        sections,
    }
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use super::*;

    const SERVER: &str = "https://demo.jellyfin.org/stable";

    /// An `Audio` item from the demo's `/Items`, trimmed.
    const AUDIO: &str = r#"{
        "Name": "Bend",
        "Id": "a794b7c125d436df8dc2d870ad7b7e1e",
        "DateCreated": "2019-11-28T06:07:13.4661661Z",
        "Container": "mp3",
        "ChannelId": null,
        "RunTimeTicks": 2675461220,
        "ProductionYear": 2006,
        "IndexNumber": 1,
        "IsFolder": false,
        "Type": "Audio",
        "UserData": { "PlayCount": 3, "IsFavorite": false },
        "Artists": ["Binaerpilot"],
        "ArtistItems": [{ "Name": "Binaerpilot", "Id": "9ebcc113abb3ee375dbf1d68c9576ed5" }],
        "Album": "You Can't Stop Da Funk",
        "AlbumId": "f21ea9ece4e6e26ec26ebfb81b82ad78",
        "AlbumPrimaryImageTag": "95b159065964e1210d8c39d255920ebc",
        "AlbumArtist": "Binaerpilot",
        "AlbumArtists": [{ "Name": "Binaerpilot", "Id": "9ebcc113abb3ee375dbf1d68c9576ed5" }],
        "ImageTags": {},
        "MediaType": "Audio",
        "NormalizationGain": -6.6000004
    }"#;

    const ALBUM: &str = r#"{
        "Name": "Nemesis",
        "Id": "f7e6d83954e06a0d46724a6068fa21ff",
        "DateCreated": "2025-02-22T02:32:09.0178164Z",
        "RunTimeTicks": 1830508539,
        "ProductionYear": 2024,
        "IsFolder": true,
        "Type": "MusicAlbum",
        "ChildCount": 1,
        "Artists": ["Leap Fidei"],
        "ArtistItems": [{ "Name": "Leap Fidei", "Id": "78e6763b3d9b58c349a58ce5eb7877c1" }],
        "AlbumArtist": "Leap Fidei",
        "AlbumArtists": [{ "Name": "Leap Fidei", "Id": "78e6763b3d9b58c349a58ce5eb7877c1" }],
        "ImageTags": { "Primary": "45ff5f4520bf2b3e9e7410e4c8766cb1" }
    }"#;

    const ARTIST: &str = r#"{
        "Name": "Binaerpilot",
        "Id": "9ebcc113abb3ee375dbf1d68c9576ed5",
        "ChannelId": null,
        "Type": "MusicArtist",
        "ImageTags": { "Primary": "ac570184d1dceb91f6c47de54126557a" }
    }"#;

    const PLAYLIST: &str = r#"{
        "Name": "Binaerpilot",
        "Id": "d970eee82134b487f1df37d753fab1f9",
        "Type": "Playlist",
        "ChildCount": 3,
        "ImageTags": { "Primary": "791bb36966b5c10ddab20a73c25963fd" },
        "MediaType": "Audio"
    }"#;

    /// The demo's `/Users/AuthenticateByName` answer, trimmed, with a made-up token.
    const AUTHENTICATED: &str = r#"{
        "User": { "Name": "demo", "Id": "4ed1b8b42a7c4ea682f0fe5d08d4e278" },
        "SessionInfo": {},
        "AccessToken": "not-a-real-token",
        "ServerId": "f0b3381645f04afb9a0e392e74b6a1b0"
    }"#;

    fn item(json: &str) -> Item {
        serde_json::from_str(json).unwrap()
    }

    #[test]
    fn an_audio_item_becomes_a_track() {
        let track = track(item(AUDIO), SERVER);
        assert_eq!(
            track.id.as_deref(),
            Some("a794b7c125d436df8dc2d870ad7b7e1e")
        );
        assert_eq!(track.name, "Bend");
        assert!(track.playable);
        assert_eq!(track.duration, Duration::from_nanos(267_546_122_000));
        assert_eq!(track.artists, "Binaerpilot");
        assert_eq!(track.artist_refs.len(), 1);
        assert_eq!(
            track.artist_refs[0].id.as_deref(),
            Some("9ebcc113abb3ee375dbf1d68c9576ed5")
        );
        assert_eq!(track.album, "You Can't Stop Da Funk");
        assert_eq!(
            track.album_id.as_deref(),
            Some("f21ea9ece4e6e26ec26ebfb81b82ad78")
        );
        assert_eq!(
            track.cover.as_deref(),
            Some(
                "https://demo.jellyfin.org/stable/Items/f21ea9ece4e6e26ec26ebfb81b82ad78/Images/Primary?maxHeight=300&tag=95b159065964e1210d8c39d255920ebc"
            )
        );
        assert_eq!(track.track_number, 1);
        assert_eq!(track.disc_number, 1);
        assert_eq!(track.playcount, Some(3));
        assert!(track.added_at.is_some());
    }

    #[test]
    fn the_normalization_gain_reads_as_replay_gain() {
        let loudness = loudness(&item(AUDIO)).unwrap();
        assert!((loudness.lufs - (-18.0 + 6.6)).abs() < 0.01);
        assert_eq!(loudness.peak, None);
        assert_eq!(loudness_of_nothing(), None);
    }

    fn loudness_of_nothing() -> Option<crate::engine::Loudness> {
        loudness(&item(ARTIST))
    }

    #[test]
    fn a_music_album_becomes_an_album() {
        let album = album(item(ALBUM), SERVER);
        assert_eq!(album.id, "f7e6d83954e06a0d46724a6068fa21ff");
        assert_eq!(album.name, "Nemesis");
        assert_eq!(album.artists, "Leap Fidei");
        assert_eq!(
            album.artist_refs[0].id.as_deref(),
            Some("78e6763b3d9b58c349a58ce5eb7877c1")
        );
        assert_eq!(album.year, 2024);
        assert_eq!(album.release_date, "2024");
        assert_eq!(album.track_count, 1);
        assert_eq!(
            album.cover.as_deref(),
            Some(
                "https://demo.jellyfin.org/stable/Items/f7e6d83954e06a0d46724a6068fa21ff/Images/Primary?maxHeight=300&tag=45ff5f4520bf2b3e9e7410e4c8766cb1"
            )
        );
        assert!(album.cover_large.unwrap().contains("maxHeight=600"));
    }

    #[test]
    fn a_music_artist_becomes_an_artist() {
        let artist = artist(&item(ARTIST), SERVER);
        assert_eq!(artist.id, "9ebcc113abb3ee375dbf1d68c9576ed5");
        assert_eq!(artist.name, "Binaerpilot");
        assert!(
            artist
                .cover
                .unwrap()
                .ends_with("tag=ac570184d1dceb91f6c47de54126557a")
        );
    }

    #[test]
    fn a_playlist_item_becomes_a_playlist() {
        let playlist = playlist(item(PLAYLIST), SERVER, None);
        assert_eq!(playlist.id, "d970eee82134b487f1df37d753fab1f9");
        assert_eq!(playlist.name, "Binaerpilot");
        assert_eq!(playlist.track_count, 3);
        assert!(!playlist.owned);
        assert!(playlist.cover.is_some());
    }

    /// The demo's `/Playlists/{id}/Users/{userId}` for the playlist's owner.
    const PLAYLIST_USER: &str = r#"{"UserId":"4ed1b8b42a7c4ea682f0fe5d08d4e278","CanEdit":true}"#;

    #[test]
    fn a_playlist_the_listener_may_edit_is_their_own() {
        let user: PlaylistUser = serde_json::from_str(PLAYLIST_USER).unwrap();
        assert!(playlist(item(PLAYLIST), SERVER, Some(user)).owned);
        let viewer: PlaylistUser =
            serde_json::from_str(r#"{"UserId":"x","CanEdit":false}"#).unwrap();
        assert!(!playlist(item(PLAYLIST), SERVER, Some(viewer)).owned);
    }

    #[test]
    fn a_listen_is_dated_in_utc() {
        let at = std::time::UNIX_EPOCH + Duration::from_secs(1_793_131_200);
        assert_eq!(iso_8601(at), "2026-10-27T20:00:00Z");
    }

    #[test]
    fn emby_dates_a_listen_with_no_separators() {
        let at = std::time::UNIX_EPOCH + Duration::from_secs(1_793_131_200);
        assert_eq!(emby_date(at), "20261027200000");
    }

    /// An Emby 4.10 `/Users/{userId}/Items/{id}` of a track with an `.lrc` beside it, trimmed.
    const EMBY_TRACK: &str = r#"{
        "Name": "Song 1",
        "Id": "12",
        "Type": "Audio",
        "MediaSources": [{
            "Id": "mediasource_12",
            "MediaStreams": [
                { "Codec": "mp3", "Type": "Audio", "Index": 0, "IsTextSubtitleStream": false },
                { "Codec": "lrc", "Type": "Subtitle", "Index": 1, "IsExternal": true,
                  "IsTextSubtitleStream": true }
            ]
        }]
    }"#;

    #[test]
    fn emby_keeps_lyrics_as_a_text_subtitle_of_the_track() {
        assert_eq!(
            lyrics_stream(&item(EMBY_TRACK)),
            Some(("mediasource_12".to_owned(), 1))
        );
        assert_eq!(lyrics_stream(&item(AUDIO)), None);
    }

    #[test]
    fn only_favorites_count_as_liked() {
        let liked = item(r#"{"Id":"a","UserData":{"PlayCount":0,"IsFavorite":true}}"#);
        let other = item(AUDIO);
        let bare = item(r#"{"Id":"c"}"#);
        let kept: Vec<String> = favorites(vec![liked, other, bare])
            .into_iter()
            .map(|item| item.id)
            .collect();
        assert_eq!(kept, ["a"]);
    }

    /// `/Playlists/{id}/Items` of a playlist with "a" twice, trimmed: older servers give every
    /// entry its own `PlaylistItemId`.
    const ENTRIES: &str = r#"{"Items":[
        {"Id":"a","PlaylistItemId":"e1"},
        {"Id":"b","PlaylistItemId":"e2"},
        {"Id":"a","PlaylistItemId":"e3"}
    ]}"#;

    /// The same on the 12.4 demo, where an entry's `PlaylistItemId` is its track's id, so both
    /// copies share one.
    const SHARED_ENTRIES: &str = r#"{"Items":[
        {"Id":"a","PlaylistItemId":"a"},
        {"Id":"b","PlaylistItemId":"b"},
        {"Id":"a","PlaylistItemId":"a"}
    ]}"#;

    fn entries(json: &str) -> Vec<Item> {
        serde_json::from_str::<Items>(json).unwrap().items
    }

    #[test]
    fn a_copy_is_removed_by_its_own_entry_id() {
        let items = entries(ENTRIES);
        assert_eq!(removal(&items, "a", 1), Some(Removal::Entry("e3".into())));
        assert_eq!(removal(&items, "a", 0), Some(Removal::Entry("e1".into())));
        assert_eq!(removal(&items, "a", 2), None);
        assert_eq!(removal(&items, "z", 0), None);
    }

    #[test]
    fn a_copy_sharing_its_entry_id_is_removed_by_rewriting_the_list() {
        let items = entries(SHARED_ENTRIES);
        assert_eq!(removal(&items, "a", 1), Some(Removal::Rewrite));
        assert_eq!(removal(&items, "b", 0), Some(Removal::Entry("b".into())));
        let ids = ["a", "b", "a", "c"].map(String::from).to_vec();
        assert_eq!(
            without(ids.clone(), "a", 1),
            Some(["a", "b", "c"].map(String::from).to_vec())
        );
        assert_eq!(without(ids, "a", 2), None);
    }

    #[test]
    fn an_item_without_a_picture_has_no_cover() {
        let mut bare = item(AUDIO);
        bare.album_primary_image_tag = None;
        assert_eq!(track(bare, SERVER).cover, None);
    }

    #[test]
    fn the_sign_in_answer_becomes_the_stored_credentials() {
        let answer: Authenticated = serde_json::from_str(AUTHENTICATED).unwrap();
        let stored = credentials(answer, SERVER, "device-1", Flavor::Jellyfin);
        assert_eq!(stored.server, SERVER);
        assert_eq!(stored.user_id, "4ed1b8b42a7c4ea682f0fe5d08d4e278");
        assert_eq!(stored.username, "demo");
        assert_eq!(stored.device_id, "device-1");
        assert_eq!(stored.token, "not-a-real-token");
    }

    #[test]
    fn a_listing_reads_its_items_and_total() {
        let json = format!(r#"{{"Items":[{AUDIO}],"TotalRecordCount":5,"StartIndex":0}}"#);
        let listing: Items = serde_json::from_str(&json).unwrap();
        assert_eq!(listing.items.len(), 1);
        assert_eq!(listing.total_record_count, Some(5));
    }

    /// A `MusicGenre` from the demo's `/MusicGenres`, trimmed.
    const GENRE: &str = r#"{
        "Name": "Electronic",
        "Id": "6ca4fc40460773bb0ac0cd7c74ca4807",
        "Type": "MusicGenre",
        "ImageTags": { "Primary": "6a06bd45cf5d2f38ea3aa0a0dcc18afb" }
    }"#;

    #[test]
    fn a_music_genre_becomes_a_genre() {
        let genre = genre(item(GENRE), SERVER);
        assert_eq!(genre.id, "6ca4fc40460773bb0ac0cd7c74ca4807");
        assert_eq!(genre.name, "Electronic");
        assert!(
            genre
                .cover
                .unwrap()
                .ends_with("tag=6a06bd45cf5d2f38ea3aa0a0dcc18afb")
        );
    }

    #[test]
    fn the_most_played_tracks_name_their_albums_once_in_order() {
        let played = |album: &str| Item {
            album_id: Some(album.to_owned()),
            ..item(AUDIO)
        };
        let tracks = [
            played("a"),
            played("b"),
            played("a"),
            Item::default(),
            played("c"),
        ];
        assert_eq!(album_ids(&tracks, 2), ["a", "b"]);
        assert_eq!(album_ids(&tracks, 12), ["a", "b", "c"]);
    }

    #[test]
    fn home_has_the_subsonic_shelves_and_leaves_empty_ones_out() {
        let songs: Vec<Track> = (0..25).map(|_| track(item(AUDIO), SERVER)).collect();
        let albums = vec![album(item(ALBUM), SERVER)];
        let feed = home(songs, albums.clone(), albums);
        assert_eq!(feed.listen_again.len(), 10);
        assert_eq!(feed.quick_picks.as_ref().map(Vec::len), Some(15));
        let titles: Vec<&str> = feed
            .sections
            .iter()
            .map(|section| section.title.as_str())
            .collect();
        assert_eq!(titles, ["Newest albums", "Most played albums"]);

        let bare = home(Vec::new(), Vec::new(), vec![album(item(ALBUM), SERVER)]);
        let titles: Vec<&str> = bare
            .sections
            .iter()
            .map(|section| section.title.as_str())
            .collect();
        assert_eq!(titles, ["Most played albums"]);
        assert!(bare.listen_again.is_empty());
    }
}
