use std::collections::{HashMap, HashSet};
use std::time::Duration;

use anyhow::{Context as _, Result, anyhow};
use async_trait::async_trait;
use reqwest::header::{AUTHORIZATION, HeaderValue};
use serde::de::DeserializeOwned;

use crate::engine::Loudness;
use crate::jellyfin::auth::{self, Credentials};
use crate::jellyfin::wire::{self, Authenticated, Item, Items, User};
use crate::{
    Album, AlbumDetail, Artist, ArtistProfile, Codec, Genre, GenreDetail, GenreItem, GenreSection,
    HomeFeed, MediaKind, MusicApi, Playlist, PlaylistDetail, SavedArtist, Track, Transcode,
    UserProfile, distinct_covers,
};

/// What part 1 of the Jellyfin provider answers for likes and playlist edits, which come in
/// part 2.
const NOT_YET: &str = "not supported yet on Jellyfin";
const PAGE: usize = 500;
/// How many ids one `Ids=` lookup carries, so the url stays short.
const IDS_PER_LOOKUP: usize = 100;
const TOP_TRACKS: usize = 20;
/// The home shelves' sizes, as Subsonic's.
const HOME_SONGS: usize = 25;
const HOME_ALBUMS: usize = 12;
/// How many of the most played tracks are read to find the most played albums.
const PLAYED_TRACKS: usize = 100;
const GENRE_ALBUMS: usize = 50;
const FIELDS: &str = "DateCreated,ChildCount";
/// What the engine decodes as it comes, so the server sends these files untouched.
const DIRECT: &str = "mp3,flac,aac,m4a,mp4,alac,ogg,oga,opus,webm,wav,aiff";

/// Replaces every copy of the token in an error's text, so a failure never shows or logs it.
pub fn scrub(text: &str, token: &str) -> String {
    match token.is_empty() {
        true => text.to_owned(),
        false => text.replace(token, "[token]"),
    }
}

/// A transport error as text with no url and no token in it.
fn failed(error: reqwest::Error, token: &str) -> anyhow::Error {
    anyhow!(scrub(
        &format!("{:#}", anyhow::Error::from(error.without_url())),
        token
    ))
}

/// The header value for `authorization`, marked sensitive so nothing that logs headers shows it.
fn header(authorization: &str) -> Result<HeaderValue> {
    let mut value =
        HeaderValue::from_str(authorization).context("cannot build the jellyfin authorization")?;
    value.set_sensitive(true);
    Ok(value)
}

/// Signs in with the password and answers what to store. The password goes in the body of this
/// one request and nowhere else.
pub async fn authenticate(
    server: &str,
    username: &str,
    password: &str,
    device_id: &str,
) -> Result<Credentials> {
    let response = reqwest::Client::new()
        .post(format!("{server}/Users/AuthenticateByName"))
        .header(
            AUTHORIZATION,
            header(&auth::authorization(device_id, None))?,
        )
        .json(&serde_json::json!({ "Username": username, "Pw": password }))
        .send()
        .await
        .map_err(|error| failed(error, ""))
        .context("cannot reach the jellyfin server")?;
    if response.status() == reqwest::StatusCode::UNAUTHORIZED {
        anyhow::bail!("the jellyfin server refused the username or password");
    }
    let answer: Authenticated = response
        .error_for_status()
        .map_err(|error| failed(error, ""))
        .context("the jellyfin server refused the sign-in")?
        .json()
        .await
        .map_err(|error| failed(error, ""))
        .context("cannot read the jellyfin sign-in answer")?;
    Ok(wire::credentials(answer, server, device_id))
}

/// Ends the session on the server, so the token stops working there too. Best effort: the
/// credentials go whatever the server says. It blocks, so it runs on a thread of its own.
pub fn logout(credentials: &Credentials) {
    let sent = header(&auth::authorization(
        &credentials.device_id,
        Some(&credentials.token),
    ))
    .and_then(|value| {
        reqwest::blocking::Client::builder()
            .timeout(Duration::from_secs(10))
            .build()?
            .post(format!("{}/Sessions/Logout", credentials.server))
            .header(AUTHORIZATION, value)
            .send()?
            .error_for_status()?;
        Ok(())
    });
    if let Err(error) = sent {
        log::info!(
            "jellyfin: the server did not take the sign-out: {}",
            scrub(&format!("{error:#}"), &credentials.token)
        );
    }
}

/// What the server records about a track that playback wants before the decoder can tell.
#[derive(Clone, Copy, Debug, Default)]
pub struct Details {
    pub duration: Option<Duration>,
    pub loudness: Option<Loudness>,
}

/// The query of a `/universal` stream: the formats to send untouched and what to convert the
/// rest into. A chosen codec is the only format sent, so everything else is converted to it, and
/// a bitrate ceiling converts whatever goes over it.
pub(crate) fn stream_query(
    user_id: &str,
    device_id: &str,
    transcode: Transcode,
) -> Vec<(&'static str, String)> {
    let (direct, container, codec) = match transcode.codec {
        None => (DIRECT, "mp3", "mp3"),
        Some(Codec::Mp3) => ("mp3", "mp3", "mp3"),
        Some(Codec::Opus) => ("opus", "ogg", "opus"),
        Some(Codec::Aac) => ("aac", "aac", "aac"),
    };
    let mut query = vec![
        ("UserId", user_id.to_owned()),
        ("DeviceId", device_id.to_owned()),
        ("Container", direct.to_owned()),
        ("TranscodingContainer", container.to_owned()),
        ("TranscodingProtocol", "http".to_owned()),
        ("AudioCodec", codec.to_owned()),
    ];
    if let Some(kbps) = transcode.bitrate {
        query.push(("MaxStreamingBitrate", (u64::from(kbps) * 1000).to_string()));
    }
    query
}

#[derive(Clone)]
pub struct JellyfinClient {
    http: reqwest::Client,
    /// The server address with no trailing slash.
    server: String,
    user_id: String,
    username: String,
    device_id: String,
    token: String,
    authorization: HeaderValue,
}

impl JellyfinClient {
    pub fn new(credentials: &Credentials) -> Result<Self> {
        Ok(Self {
            http: reqwest::Client::new(),
            server: credentials.server.clone(),
            user_id: credentials.user_id.clone(),
            username: credentials.username.clone(),
            device_id: credentials.device_id.clone(),
            token: credentials.token.clone(),
            authorization: header(&auth::authorization(
                &credentials.device_id,
                Some(&credentials.token),
            ))?,
        })
    }

    /// The account and server this client plays from. A track id only means something on its
    /// own server, so this tells apart two servers' tracks that share one.
    pub fn identity(&self) -> String {
        format!("{}@{}", self.user_id, self.server)
    }

    fn fail(&self, error: reqwest::Error) -> anyhow::Error {
        failed(error, &self.token)
    }

    async fn send(&self, path: &str, query: &[(&str, String)]) -> Result<reqwest::Response> {
        self.http
            .get(format!("{}{path}", self.server))
            .header(AUTHORIZATION, self.authorization.clone())
            .query(query)
            .send()
            .await
            .map_err(|error| self.fail(error))?
            .error_for_status()
            .map_err(|error| self.fail(error))
    }

    async fn get<T: DeserializeOwned>(&self, path: &str, query: &[(&str, String)]) -> Result<T> {
        self.send(path, query)
            .await?
            .json()
            .await
            .map_err(|error| self.fail(error))
    }

    /// One page of `path`, for the user, with the fields every conversion reads.
    async fn page(
        &self,
        path: &str,
        query: &[(&str, &str)],
        start: usize,
        limit: usize,
    ) -> Result<Items> {
        let mut full: Vec<(&str, String)> = vec![
            ("userId", self.user_id.clone()),
            ("Fields", FIELDS.to_owned()),
            ("StartIndex", start.to_string()),
            ("Limit", limit.to_string()),
        ];
        full.extend(query.iter().map(|(key, value)| (*key, (*value).to_owned())));
        self.get(path, &full).await
    }

    /// Every item of `path`, a page at a time.
    async fn all(&self, path: &str, query: &[(&str, &str)]) -> Result<Vec<Item>> {
        let mut items = Vec::new();
        loop {
            let page = self.page(path, query, items.len(), PAGE).await?;
            let fetched = page.items.len();
            items.extend(page.items);
            let done = page
                .total_record_count
                .is_some_and(|total| items.len() >= total);
            if fetched < PAGE || done {
                return Ok(items);
            }
        }
    }

    /// Every item of `kind` in the library, by name.
    async fn library(&self, kind: &str) -> Result<Vec<Item>> {
        self.all(
            "/Items",
            &[
                ("Recursive", "true"),
                ("IncludeItemTypes", kind),
                ("SortBy", "SortName"),
            ],
        )
        .await
    }

    async fn search_kind(&self, query: &str, kind: &str, limit: usize) -> Result<Vec<Item>> {
        let found = self
            .page(
                "/Items",
                &[
                    ("searchTerm", query),
                    ("Recursive", "true"),
                    ("IncludeItemTypes", kind),
                ],
                0,
                limit,
            )
            .await
            .context("cannot search")?;
        Ok(found.items)
    }

    async fn item(&self, id: &str) -> Result<Item> {
        self.get(
            &format!("/Items/{}", crate::escape::component(id)),
            &[
                ("userId", self.user_id.clone()),
                ("Fields", format!("{FIELDS},Overview")),
            ],
        )
        .await
    }

    /// The items with these ids, looked up a hundred at a time.
    async fn by_ids(&self, ids: &[String]) -> Result<Vec<Item>> {
        let mut items = Vec::new();
        for chunk in ids.chunks(IDS_PER_LOOKUP) {
            let ids = chunk.join(",");
            items.extend(
                self.page("/Items", &[("Ids", ids.as_str())], 0, chunk.len())
                    .await?
                    .items,
            );
        }
        Ok(items)
    }

    fn track_of(&self, item: Item) -> Track {
        wire::track(item, &self.server)
    }

    fn tracks(&self, items: Vec<Item>) -> Vec<Track> {
        items.into_iter().map(|item| self.track_of(item)).collect()
    }

    fn albums(&self, items: Vec<Item>) -> Vec<Album> {
        items
            .into_iter()
            .map(|item| wire::album(item, &self.server))
            .collect()
    }

    fn playlists_of(&self, items: Vec<Item>) -> Vec<Playlist> {
        items
            .into_iter()
            .map(|item| wire::playlist(item, &self.server))
            .collect()
    }

    /// Opens the audio of a track, converted as `transcode` asks, and answers once the response
    /// headers are in. The token travels in the header, so the url carries none.
    pub async fn open_stream(
        &self,
        track_id: &str,
        transcode: Transcode,
    ) -> Result<reqwest::Response> {
        self.send(
            &format!("/Audio/{}/universal", crate::escape::component(track_id)),
            &stream_query(&self.user_id, &self.device_id, transcode),
        )
        .await
        .context("cannot stream the track")
    }

    /// The length and normalisation gain the server records for a track.
    pub async fn details(&self, track_id: &str) -> Details {
        let Ok(item) = self.item(track_id).await else {
            return Details::default();
        };
        Details {
            duration: item.run_time_ticks.map(|ticks| wire::duration(Some(ticks))),
            loudness: wire::loudness(&item),
        }
    }
}

#[async_trait]
impl MusicApi for JellyfinClient {
    fn share_url(&self, _kind: MediaKind, _id: &str) -> Option<String> {
        None
    }

    async fn profile(&self) -> Result<UserProfile> {
        let user: User = self
            .get("/Users/Me", &[])
            .await
            .context("cannot reach the jellyfin server")?;
        Ok(UserProfile {
            id: user.id,
            display_name: match user.name.is_empty() {
                true => self.username.clone(),
                false => user.name,
            },
            avatar: None,
        })
    }

    /// The artist, their most played tracks and the albums those tracks come from. Albums are
    /// found through the tracks, since many libraries leave the album artist unset.
    async fn artist(&self, artist_id: &str) -> Result<Artist> {
        let query = [
            ("Recursive", "true"),
            ("IncludeItemTypes", "Audio"),
            ("ArtistIds", artist_id),
            ("SortBy", "PlayCount,SortName"),
            ("SortOrder", "Descending,Ascending"),
        ];
        let (item, tracks) = tokio::join!(self.item(artist_id), self.all("/Items", &query));
        let item = item.context("cannot load the artist")?;
        let tracks = tracks.context("cannot load the artist's tracks")?;
        let mut seen = HashSet::new();
        let album_ids: Vec<String> = tracks
            .iter()
            .filter_map(|track| track.album_id.clone())
            .filter(|id| seen.insert(id.clone()))
            .collect();
        let albums = self.by_ids(&album_ids).await.unwrap_or_else(|error| {
            log::warn!("jellyfin: cannot load the artist's albums: {error:#}");
            Vec::new()
        });
        let profile = wire::artist(&item, &self.server);
        Ok(Artist {
            name: profile.name,
            cover_large: profile.cover,
            biography: item.overview.filter(|text| !text.trim().is_empty()),
            monthly_listeners: None,
            top_tracks: self.tracks(tracks.into_iter().take(TOP_TRACKS).collect()),
            albums: self.albums(albums),
        })
    }

    async fn artist_profile(&self, artist_id: &str) -> Result<ArtistProfile> {
        let item = self
            .item(artist_id)
            .await
            .context("cannot load the artist")?;
        let profile = wire::artist(&item, &self.server);
        Ok(ArtistProfile {
            name: profile.name,
            cover_large: profile.cover,
            biography: item.overview.filter(|text| !text.trim().is_empty()),
        })
    }

    async fn artist_images(&self, ids: Vec<String>) -> Result<HashMap<String, String>> {
        Ok(self
            .by_ids(&ids)
            .await?
            .iter()
            .filter_map(|item| {
                let artist = wire::artist(item, &self.server);
                Some((artist.id, artist.cover?))
            })
            .collect())
    }

    async fn saved_tracks(&self) -> Result<Vec<Track>> {
        Ok(Vec::new())
    }

    async fn all_tracks(&self) -> Result<Vec<Track>> {
        Ok(self.tracks(
            self.library("Audio")
                .await
                .context("cannot load the songs")?,
        ))
    }

    async fn set_track_saved(&self, _track_id: &str, _saved: bool) -> Result<()> {
        anyhow::bail!("likes are {NOT_YET}")
    }

    async fn track(&self, track_id: &str) -> Result<Track> {
        let item = self
            .item(track_id)
            .await
            .with_context(|| format!("cannot load the song {track_id}"))?;
        Ok(self.track_of(item))
    }

    async fn track_playcount(&self, track_id: &str) -> Result<Option<u64>> {
        Ok(self
            .track(track_id)
            .await
            .ok()
            .and_then(|track| track.playcount))
    }

    async fn playlists(&self) -> Result<Vec<Playlist>> {
        Ok(self.playlists_of(
            self.library("Playlist")
                .await
                .context("cannot load the playlists")?,
        ))
    }

    async fn create_playlist(&self, _name: &str) -> Result<String> {
        anyhow::bail!("creating playlists is {NOT_YET}")
    }

    async fn rename_playlist(&self, _playlist_id: &str, _name: &str) -> Result<()> {
        anyhow::bail!("renaming playlists is {NOT_YET}")
    }

    async fn delete_playlist(&self, _playlist_id: &str) -> Result<()> {
        anyhow::bail!("deleting playlists is {NOT_YET}")
    }

    async fn remove_playlist_from_library(&self, _playlist_id: &str) -> Result<()> {
        anyhow::bail!("removing playlists is {NOT_YET}")
    }

    async fn add_playlist_to_library(&self, _playlist_id: &str) -> Result<()> {
        anyhow::bail!("saving playlists is {NOT_YET}")
    }

    async fn set_playlist_public(&self, _playlist_id: &str, _public: bool) -> Result<()> {
        anyhow::bail!("changing playlists is {NOT_YET}")
    }

    async fn add_track_to_playlist(&self, _playlist_id: &str, _track_id: &str) -> Result<()> {
        anyhow::bail!("adding to playlists is {NOT_YET}")
    }

    async fn remove_track_from_playlist(
        &self,
        _playlist_id: &str,
        _track_id: &str,
        _copy: usize,
    ) -> Result<()> {
        anyhow::bail!("removing from playlists is {NOT_YET}")
    }

    async fn saved_albums(&self) -> Result<Vec<Album>> {
        Ok(Vec::new())
    }

    async fn all_albums(&self) -> Result<Vec<Album>> {
        Ok(self.albums(
            self.library("MusicAlbum")
                .await
                .context("cannot load the albums")?,
        ))
    }

    async fn set_album_saved(&self, _album_id: &str, _saved: bool) -> Result<()> {
        anyhow::bail!("likes are {NOT_YET}")
    }

    async fn saved_artists(&self) -> Result<Vec<SavedArtist>> {
        Ok(Vec::new())
    }

    async fn all_artists(&self) -> Result<Vec<SavedArtist>> {
        let artists = self
            .all("/Artists/AlbumArtists", &[("SortBy", "SortName")])
            .await
            .context("cannot load the artists")?;
        Ok(artists
            .iter()
            .map(|item| wire::artist(item, &self.server))
            .collect())
    }

    async fn set_artist_saved(&self, _artist_id: &str, _saved: bool) -> Result<()> {
        anyhow::bail!("following artists is {NOT_YET}")
    }

    async fn album(&self, album_id: &str) -> Result<AlbumDetail> {
        let query = [
            ("ParentId", album_id),
            ("IncludeItemTypes", "Audio"),
            ("SortBy", "ParentIndexNumber,IndexNumber,SortName"),
        ];
        let (item, tracks) = tokio::join!(self.item(album_id), self.all("/Items", &query));
        let item = item.with_context(|| format!("cannot load the album {album_id}"))?;
        let tracks =
            self.tracks(tracks.with_context(|| format!("cannot load the album {album_id}"))?);
        let mut album = wire::album(item, &self.server);
        if album.track_count == 0 {
            album.track_count = tracks.len() as u32;
        }
        Ok(AlbumDetail { album, tracks })
    }

    async fn album_tracks(&self, album_id: &str) -> Result<Vec<Track>> {
        Ok(self.album(album_id).await?.tracks)
    }

    async fn playlist(&self, playlist_id: &str) -> Result<PlaylistDetail> {
        let path = format!("/Playlists/{}/Items", crate::escape::component(playlist_id));
        let (item, tracks) = tokio::join!(self.item(playlist_id), self.all(&path, &[]));
        let item = item.with_context(|| format!("cannot load the playlist {playlist_id}"))?;
        let tracks =
            self.tracks(tracks.with_context(|| format!("cannot load the playlist {playlist_id}"))?);
        let mut playlist = wire::playlist(item, &self.server);
        if playlist.track_count == 0 {
            playlist.track_count = tracks.len() as u32;
        }
        if playlist.cover.is_none() {
            playlist.cover = tracks.iter().find_map(|track| track.cover.clone());
        }
        Ok(PlaylistDetail {
            playlist,
            tracks,
            continuation: None,
        })
    }

    async fn playlist_tracks(&self, playlist_id: &str) -> Result<Vec<Track>> {
        Ok(self.playlist(playlist_id).await?.tracks)
    }

    async fn playlist_covers(&self, playlist_id: &str, wanted: usize) -> Result<Vec<String>> {
        Ok(distinct_covers(
            &self.playlist_tracks(playlist_id).await?,
            wanted,
        ))
    }

    /// No stations yet, which `Capabilities::radio` being off keeps out of sight.
    async fn track_radio(
        &self,
        _track_id: &str,
        _from: Option<&str>,
    ) -> Result<(Vec<Track>, Option<String>)> {
        Ok((Vec::new(), None))
    }

    async fn search(&self, query: &str) -> Result<Vec<Track>> {
        Ok(self.tracks(self.search_kind(query, "Audio", 50).await?))
    }

    async fn search_albums(&self, query: &str) -> Result<Vec<Album>> {
        Ok(self.albums(self.search_kind(query, "MusicAlbum", 30).await?))
    }

    async fn search_playlists(&self, query: &str) -> Result<Vec<Playlist>> {
        Ok(self.playlists_of(self.search_kind(query, "Playlist", 30).await?))
    }

    /// Jellyfin keeps play counts on tracks, not albums, so the most played albums are the ones
    /// the most played tracks come from.
    async fn home(&self) -> Result<HomeFeed> {
        let random = [
            ("Recursive", "true"),
            ("IncludeItemTypes", "Audio"),
            ("SortBy", "Random"),
        ];
        let newest = [
            ("Recursive", "true"),
            ("IncludeItemTypes", "MusicAlbum"),
            ("SortBy", "DateCreated"),
            ("SortOrder", "Descending"),
        ];
        let played = [
            ("Recursive", "true"),
            ("IncludeItemTypes", "Audio"),
            ("Filters", "IsPlayed"),
            ("SortBy", "PlayCount"),
            ("SortOrder", "Descending"),
        ];
        let (random, newest, played) = tokio::join!(
            self.page("/Items", &random, 0, HOME_SONGS),
            self.page("/Items", &newest, 0, HOME_ALBUMS),
            self.page("/Items", &played, 0, PLAYED_TRACKS),
        );
        // Nothing read at all is an error rather than an empty home, so it is asked again.
        if let (Err(error), Err(_), Err(_)) = (&random, &newest, &played) {
            anyhow::bail!("cannot load the home feed: {error:#}");
        }
        let shelf = |read: Result<Items>| {
            read.map(|page| page.items)
                .inspect_err(|error| log::warn!("jellyfin: a home shelf failed: {error:#}"))
                .unwrap_or_default()
        };
        let ids = wire::album_ids(&shelf(played), HOME_ALBUMS);
        let mut most_played = self.by_ids(&ids).await.unwrap_or_default();
        // a lookup by ids answers in its own order; the shelf keeps the play count's
        most_played.sort_by_key(|album| ids.iter().position(|id| *id == album.id));
        Ok(wire::home(
            self.tracks(shelf(random)),
            self.albums(shelf(newest)),
            self.albums(most_played),
        ))
    }

    async fn genres(&self) -> Result<Vec<Genre>> {
        let genres = self
            .all("/MusicGenres", &[("SortBy", "SortName")])
            .await
            .context("cannot load the genres")?;
        Ok(genres
            .into_iter()
            .map(|item| wire::genre(item, &self.server))
            .collect())
    }

    async fn genre(&self, genre_id: &str) -> Result<GenreDetail> {
        let query = [
            ("Recursive", "true"),
            ("IncludeItemTypes", "MusicAlbum"),
            ("GenreIds", genre_id),
            ("SortBy", "SortName"),
        ];
        let (item, albums) = tokio::join!(
            self.item(genre_id),
            self.page("/Items", &query, 0, GENRE_ALBUMS)
        );
        let albums = albums.with_context(|| format!("cannot load the genre {genre_id}"))?;
        let name = item
            .ok()
            .and_then(|item| item.name)
            .unwrap_or_else(|| genre_id.to_owned());
        let items: Vec<GenreItem> = self
            .albums(albums.items)
            .into_iter()
            .map(GenreItem::Album)
            .collect();
        Ok(GenreDetail {
            sections: match items.is_empty() {
                true => Vec::new(),
                false => vec![GenreSection {
                    title: name.clone(),
                    items,
                }],
            },
            name,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn scrub_hides_the_token() {
        let text =
            r#"error sending request for url (https://x/Audio/1?api_key=s3cr3t): Token="s3cr3t""#;
        let scrubbed = scrub(text, "s3cr3t");
        assert!(!scrubbed.contains("s3cr3t"));
        assert!(scrubbed.contains("error sending request"));
        assert_eq!(scrub("plain", ""), "plain");
    }
}

#[cfg(test)]
mod stream_tests {
    use super::*;

    fn value<'a>(query: &'a [(&str, String)], key: &str) -> Option<&'a str> {
        query
            .iter()
            .find(|(name, _)| *name == key)
            .map(|(_, value)| value.as_str())
    }

    #[test]
    fn no_choice_sends_decodable_files_untouched_with_no_ceiling() {
        let query = stream_query("u", "d", Transcode::default());
        assert_eq!(value(&query, "Container"), Some(DIRECT));
        assert_eq!(value(&query, "TranscodingProtocol"), Some("http"));
        assert_eq!(value(&query, "MaxStreamingBitrate"), None);
        assert!(query.iter().all(|(key, _)| *key != "api_key"));
    }

    #[test]
    fn a_chosen_codec_and_ceiling_convert_to_them() {
        let query = stream_query(
            "u",
            "d",
            Transcode {
                codec: Some(Codec::Opus),
                bitrate: Some(128),
            },
        );
        assert_eq!(value(&query, "Container"), Some("opus"));
        assert_eq!(value(&query, "TranscodingContainer"), Some("ogg"));
        assert_eq!(value(&query, "AudioCodec"), Some("opus"));
        assert_eq!(value(&query, "MaxStreamingBitrate"), Some("128000"));
    }
}

/// Against the public demo, by hand: `cargo test -p music --lib jellyfin_demo -- --ignored`.
/// It stores nothing and never prints the token.
#[cfg(test)]
mod demo {
    use super::*;

    #[tokio::test]
    #[ignore = "reaches demo.jellyfin.org"]
    async fn jellyfin_demo_signs_in_lists_searches_and_streams() {
        let server = auth::normalize_server("demo.jellyfin.org/stable").unwrap();
        let credentials = authenticate(&server, "demo", "", "cauce-live-check")
            .await
            .unwrap();
        let client = JellyfinClient::new(&credentials).unwrap();
        let albums = client.all_albums().await.unwrap();
        println!("albums: {}", albums.len());
        let found = client.search("Binaerpilot").await.unwrap();
        println!("tracks found: {}", found.len());
        let playlists = client.search_playlists("Binaerpilot").await.unwrap();
        println!("playlists found: {}", playlists.len());
        let artists = client.all_artists().await.unwrap();
        println!("album artists: {}", artists.len());
        let artist = client.artist(&artists[0].id).await.unwrap();
        println!(
            "{}: {} top tracks, {} albums",
            artist.name,
            artist.top_tracks.len(),
            artist.albums.len()
        );
        let playlist = client.playlist(&playlists[0].id).await.unwrap();
        println!(
            "playlist {}: {} tracks",
            playlist.playlist.name,
            playlist.tracks.len()
        );
        let first = albums.first().unwrap();
        let detail = client.album(&first.id).await.unwrap();
        println!("{}: {} tracks", detail.album.name, detail.tracks.len());
        let track = found.first().or(detail.tracks.first()).unwrap();
        let id = track.id.clone().unwrap();
        let mut response = client.open_stream(&id, Transcode::default()).await.unwrap();
        let chunk = response.chunk().await.unwrap().unwrap();
        println!(
            "{} streams {:?}, first bytes {:02x?}",
            track.name,
            response.headers().get("content-type"),
            &chunk[..4]
        );
        let home = client.home().await.unwrap();
        println!(
            "home: {} to listen again, shelves {:?}",
            home.listen_again.len(),
            home.sections
                .iter()
                .map(|section| (section.title.as_str(), section.items.len()))
                .collect::<Vec<_>>()
        );
        let genres = client.genres().await.unwrap();
        let genre = client.genre(&genres[0].id).await.unwrap();
        println!(
            "genres: {}, {}: {} shelves",
            genres.len(),
            genre.name,
            genre.sections.len()
        );
        let details = client.details(&id).await;
        println!("details: {details:?}");
        assert!(!chunk.is_empty());
        std::thread::spawn(move || logout(&credentials))
            .join()
            .unwrap();
    }
}
