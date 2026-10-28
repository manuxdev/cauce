use std::collections::HashMap;
use std::sync::Arc;
use std::time::Duration;

use anyhow::{Context as _, Result, anyhow};
use async_trait::async_trait;
use reqwest::header::{ACCEPT, HeaderMap, HeaderName, HeaderValue};
use reqwest::{Method, StatusCode};

use crate::engine::Loudness;
use crate::plex::auth::Credentials;
use crate::plex::wire::{self, Answer, Art, Container, Metadata, Plan};
use crate::{
    Album, AlbumDetail, Artist, ArtistProfile, Genre, GenreDetail, GenreItem, GenreSection,
    HomeFeed, MediaKind, MusicApi, Playlist, PlaylistDetail, SavedArtist, Track, Transcode,
    UserProfile, distinct_covers,
};

/// Plex keeps each account's playlists to itself, with no library of other people's.
const NO_LIBRARY: &str = "plex has no library of saved playlists";
/// Likes and playlist edits are not here yet.
const NOT_YET: &str = "not supported by plex yet";
const PAGE: usize = 500;
/// How many ids one lookup or one playlist addition carries, so the url stays short.
const IDS_PER_REQUEST: usize = 100;
const TOP_TRACKS: usize = 20;
/// The home shelves' sizes, as Subsonic's and Jellyfin's.
const HOME_SONGS: usize = 25;
const HOME_ALBUMS: usize = 12;
const GENRE_ALBUMS: usize = 50;
const SEARCH_TRACKS: usize = 50;
const SEARCH_OTHERS: usize = 30;
/// How long an address may take to answer before the next one is preferred.
const PROBE: Duration = Duration::from_secs(5);
/// Plex's track type in a section's listings, then its album and artist types.
const TRACK: &str = "10";
const ALBUM: &str = "9";
const ARTIST: &str = "8";

/// A transport error as text with no url and none of `secrets` in it.
pub(crate) fn failed(error: reqwest::Error, secrets: &[&str]) -> anyhow::Error {
    let text = format!("{:#}", anyhow::Error::from(error.without_url()));
    anyhow!(
        secrets
            .iter()
            .fold(text, |text, secret| crate::jellyfin::scrub(&text, secret))
    )
}

/// The headers every request to plex.tv or a server carries: which app and install is asking,
/// and once signed in the token, marked sensitive so nothing that logs headers shows it. The
/// token travels here rather than in the url, so no url the app sends carries it.
pub(crate) fn headers(client_id: &str, token: Option<&str>) -> Result<HeaderMap> {
    let mut headers = HeaderMap::new();
    let mut put = |name: &'static str, value: &str| -> Result<()> {
        headers.insert(
            HeaderName::from_static(name),
            HeaderValue::from_str(value).context("cannot build the plex headers")?,
        );
        Ok(())
    };
    put("x-plex-product", crate::plex::PRODUCT)?;
    put("x-plex-version", env!("CARGO_PKG_VERSION"))?;
    put("x-plex-client-identifier", client_id)?;
    put("x-plex-platform", std::env::consts::OS)?;
    put("x-plex-device-name", crate::plex::PRODUCT)?;
    headers.insert(ACCEPT, HeaderValue::from_static("application/json"));
    if let Some(token) = token {
        let mut value =
            HeaderValue::from_str(token).context("cannot build the plex authorization")?;
        value.set_sensitive(true);
        headers.insert(HeaderName::from_static("x-plex-token"), value);
    }
    Ok(headers)
}

/// The query of a conversion of track `id` to MP3 at `kbps`, as a stream that downloads like a
/// file. `session` tells this conversion apart from any other the server runs for this install.
pub(crate) fn transcode_query(id: &str, kbps: u32, session: &str) -> Vec<(&'static str, String)> {
    vec![
        ("path", format!("/library/metadata/{id}")),
        ("mediaIndex", "0".to_owned()),
        ("partIndex", "0".to_owned()),
        ("protocol", "http".to_owned()),
        ("directPlay", "0".to_owned()),
        ("directStream", "0".to_owned()),
        ("hasMDE", "1".to_owned()),
        ("musicBitrate", kbps.to_string()),
        ("maxAudioBitrate", kbps.to_string()),
        ("session", session.to_owned()),
    ]
}

/// What a conversion's profile asks the server for: MP3 over plain http, at most `kbps`.
fn transcode_profile(kbps: u32) -> String {
    format!(
        "add-transcode-target(type=musicProfile&context=streaming&protocol=http&container=mp3&audioCodec=mp3)\
         +add-limitation(scope=musicCodec&scopeName=mp3&type=upperBound&name=audio.bitrate&value={kbps})"
    )
}

/// The first of `addresses`, in order, that answers as a Plex server with `token`. They are all
/// asked at once, so a gone local address costs no more than one wait.
pub async fn reach(addresses: &[String], client_id: &str, token: &str) -> Option<String> {
    let http = reqwest::Client::builder().timeout(PROBE).build().ok()?;
    let headers = headers(client_id, Some(token)).ok()?;
    let answers = futures::future::join_all(addresses.iter().map(|address| {
        let request = http
            .get(format!("{address}/identity"))
            .headers(headers.clone());
        async move {
            request
                .send()
                .await
                .is_ok_and(|response| response.status().is_success())
        }
    }))
    .await;
    addresses
        .iter()
        .zip(answers)
        .find_map(|(address, answered)| answered.then(|| address.clone()))
}

/// What the server records about a track that playback wants before the decoder can tell.
#[derive(Clone, Copy, Debug, Default)]
pub struct Details {
    pub duration: Option<Duration>,
    pub loudness: Option<Loudness>,
}

#[derive(Clone)]
pub struct PlexClient {
    http: reqwest::Client,
    /// The address in use, with no trailing slash.
    server: String,
    server_id: String,
    user_id: String,
    username: String,
    token: String,
    headers: HeaderMap,
    /// The music libraries of the server, which every listing reads.
    sections: Arc<Vec<String>>,
}

impl PlexClient {
    pub fn new(credentials: &Credentials) -> Result<Self> {
        Ok(Self {
            http: reqwest::Client::new(),
            server: credentials.server.trim_end_matches('/').to_owned(),
            server_id: credentials.server_id.clone(),
            user_id: credentials.user_id.clone(),
            username: credentials.username.clone(),
            token: credentials.token.clone(),
            headers: headers(&credentials.client_id, Some(&credentials.token))?,
            sections: Arc::default(),
        })
    }

    pub fn with_sections(mut self, sections: Vec<String>) -> Self {
        self.sections = Arc::new(sections);
        self
    }

    /// The account and server this client plays from. A track id only means something on its
    /// own server, and the server keeps its id whichever address it is reached on.
    pub fn identity(&self) -> String {
        format!("{}@{}", self.user_id, self.server_id)
    }

    fn art(&self) -> Art<'_> {
        Art {
            server: &self.server,
            token: &self.token,
        }
    }

    fn fail(&self, error: reqwest::Error) -> anyhow::Error {
        failed(error, &[&self.token])
    }

    fn request(
        &self,
        method: Method,
        path: &str,
        query: &[(&str, String)],
    ) -> reqwest::RequestBuilder {
        self.http
            .request(method, format!("{}{path}", self.server))
            .headers(self.headers.clone())
            .query(query)
    }

    async fn sent(&self, request: reqwest::RequestBuilder) -> Result<reqwest::Response> {
        let response = request.send().await.map_err(|error| self.fail(error))?;
        if response.status() == StatusCode::UNAUTHORIZED {
            anyhow::bail!("the plex server refused the sign-in");
        }
        response
            .error_for_status()
            .map_err(|error| self.fail(error))
    }

    async fn get(&self, path: &str, query: &[(&str, String)]) -> Result<Container> {
        let answer: Answer = self
            .sent(self.request(Method::GET, path, query))
            .await?
            .json()
            .await
            .map_err(|error| self.fail(error))?;
        Ok(answer.container)
    }

    async fn page(
        &self,
        path: &str,
        query: &[(&str, &str)],
        start: usize,
        size: usize,
    ) -> Result<Container> {
        let mut full: Vec<(&str, String)> = vec![
            ("X-Plex-Container-Start", start.to_string()),
            ("X-Plex-Container-Size", size.to_string()),
        ];
        full.extend(query.iter().map(|(key, value)| (*key, (*value).to_owned())));
        self.get(path, &full).await
    }

    /// Every item of `path`, a page at a time.
    async fn all(&self, path: &str, query: &[(&str, &str)]) -> Result<Vec<Metadata>> {
        let mut items = Vec::new();
        loop {
            let page = self.page(path, query, items.len(), PAGE).await?;
            let fetched = page.metadata.len();
            items.extend(page.metadata);
            let done = page.total_size.is_some_and(|total| items.len() >= total);
            if fetched < PAGE || done {
                return Ok(items);
            }
        }
    }

    /// Every item of Plex type `kind` in every music library, by name.
    async fn library(&self, kind: &str, query: &[(&str, &str)]) -> Result<Vec<Metadata>> {
        let mut items = Vec::new();
        for section in self.sections.iter() {
            let mut full = vec![("type", kind), ("sort", "titleSort")];
            full.extend_from_slice(query);
            items.extend(
                self.all(&format!("/library/sections/{section}/all"), &full)
                    .await?,
            );
        }
        Ok(items)
    }

    /// The first `size` items of Plex type `kind` sorted by `sort`, from each music library in
    /// turn.
    // ponytail: libraries are read one after the other, not merged by `sort`; merge them if
    // anyone keeps music in two.
    async fn first(&self, kind: &str, sort: &str, size: usize) -> Result<Vec<Metadata>> {
        let mut items = Vec::new();
        for section in self.sections.iter() {
            let path = format!("/library/sections/{section}/all");
            let page = self
                .page(&path, &[("type", kind), ("sort", sort)], 0, size)
                .await?;
            items.extend(page.metadata);
        }
        items.truncate(size);
        Ok(items)
    }

    /// The music libraries on the server. A refused token is an error saying so.
    pub async fn music_sections(&self) -> Result<Vec<String>> {
        let sections = self.get("/library/sections", &[]).await?;
        Ok(wire::music_sections(sections.directory))
    }

    async fn metadata(&self, id: &str) -> Result<Metadata> {
        self.get(
            &format!("/library/metadata/{}", crate::escape::component(id)),
            &[],
        )
        .await?
        .metadata
        .into_iter()
        .next()
        .with_context(|| format!("the plex server has no item {id}"))
    }

    async fn children(&self, id: &str) -> Result<Vec<Metadata>> {
        self.all(
            &format!(
                "/library/metadata/{}/children",
                crate::escape::component(id)
            ),
            &[],
        )
        .await
    }

    /// The items with these ids, looked up a hundred at a time.
    async fn by_ids(&self, ids: &[String]) -> Result<Vec<Metadata>> {
        let mut items = Vec::new();
        for chunk in ids.chunks(IDS_PER_REQUEST) {
            let ids: Vec<String> = chunk
                .iter()
                .map(|id| crate::escape::component(id))
                .collect();
            items.extend(
                self.get(&format!("/library/metadata/{}", ids.join(",")), &[])
                    .await?
                    .metadata,
            );
        }
        Ok(items)
    }

    /// The search results of the kind Plex calls `kind`.
    async fn search_hub(&self, query: &str, kind: &str, limit: usize) -> Result<Vec<Metadata>> {
        let hubs = self
            .get(
                "/hubs/search",
                &[("query", query.to_owned()), ("limit", limit.to_string())],
            )
            .await
            .context("cannot search")?
            .hub;
        Ok(hubs
            .into_iter()
            .filter(|hub| hub.kind.as_deref() == Some(kind))
            .flat_map(|hub| hub.metadata)
            .take(limit)
            .collect())
    }

    fn tracks(&self, items: Vec<Metadata>) -> Vec<Track> {
        let art = self.art();
        items
            .into_iter()
            .map(|item| wire::track(item, &art))
            .collect()
    }

    fn albums(&self, items: Vec<Metadata>) -> Vec<Album> {
        let art = self.art();
        items
            .into_iter()
            .map(|item| wire::album(item, &art))
            .collect()
    }

    fn artists(&self, items: &[Metadata]) -> Vec<SavedArtist> {
        let art = self.art();
        items.iter().map(|item| wire::artist(item, &art)).collect()
    }

    fn playlists_of(&self, items: Vec<Metadata>) -> Vec<Playlist> {
        let art = self.art();
        items
            .into_iter()
            .filter(|item| {
                item.playlist_type
                    .as_deref()
                    .is_none_or(|kind| kind == "audio")
            })
            .map(|item| wire::playlist(item, &art))
            .collect()
    }

    /// Opens the audio of a track, converted as `transcode` asks, and answers once the response
    /// headers are in, with what the server records about the track. The token travels in the
    /// header, so the url carries none.
    pub async fn open_stream(
        &self,
        track_id: &str,
        transcode: Transcode,
    ) -> Result<(reqwest::Response, Details)> {
        let item = self
            .metadata(track_id)
            .await
            .context("cannot stream the track")?;
        let details = Details {
            duration: item.duration.map(Duration::from_millis),
            loudness: wire::loudness(&item),
        };
        let request = match wire::plan(&item, transcode).context("the track has no file")? {
            Plan::Direct(path) => self.request(Method::GET, &path, &[]),
            Plan::Convert(kbps) => {
                let session: String = std::iter::repeat_with(|| fastrand::alphanumeric())
                    .take(16)
                    .collect();
                let mut request = self.request(
                    Method::GET,
                    "/music/:/transcode/universal/start.mp3",
                    &transcode_query(&item.rating_key, kbps, &session),
                );
                let profile = HeaderValue::from_str(&transcode_profile(kbps))
                    .context("cannot build the plex profile")?;
                request = request
                    .header("x-plex-client-profile-extra", profile)
                    .header("x-plex-session-identifier", session);
                request
            }
        };
        let response = self
            .sent(request)
            .await
            .context("cannot stream the track")?;
        Ok((response, details))
    }
}

#[async_trait]
impl MusicApi for PlexClient {
    fn share_url(&self, _kind: MediaKind, _id: &str) -> Option<String> {
        None
    }

    /// The account stored at sign-in: the server keeps no profile of its own to read.
    async fn profile(&self) -> Result<UserProfile> {
        Ok(UserProfile {
            id: self.user_id.clone(),
            display_name: self.username.clone(),
            avatar: None,
        })
    }

    /// The artist, their most played tracks and their albums.
    async fn artist(&self, artist_id: &str) -> Result<Artist> {
        let leaves = format!(
            "/library/metadata/{}/allLeaves",
            crate::escape::component(artist_id)
        );
        let (item, albums, tracks) = tokio::join!(
            self.metadata(artist_id),
            self.children(artist_id),
            self.all(&leaves, &[])
        );
        let item = item.context("cannot load the artist")?;
        let mut tracks = tracks.context("cannot load the artist's tracks")?;
        tracks.sort_by_key(|track| std::cmp::Reverse(track.view_count.unwrap_or(0)));
        tracks.truncate(TOP_TRACKS);
        let albums = albums.unwrap_or_else(|error| {
            log::warn!("plex: cannot load the artist's albums: {error:#}");
            Vec::new()
        });
        let profile = wire::artist(&item, &self.art());
        Ok(Artist {
            name: profile.name,
            cover_large: profile.cover,
            biography: item.summary.filter(|text| !text.trim().is_empty()),
            monthly_listeners: None,
            top_tracks: self.tracks(tracks),
            albums: self.albums(albums),
        })
    }

    async fn artist_profile(&self, artist_id: &str) -> Result<ArtistProfile> {
        let item = self
            .metadata(artist_id)
            .await
            .context("cannot load the artist")?;
        let profile = wire::artist(&item, &self.art());
        Ok(ArtistProfile {
            name: profile.name,
            cover_large: profile.cover,
            biography: item.summary.filter(|text| !text.trim().is_empty()),
        })
    }

    async fn artist_images(&self, ids: Vec<String>) -> Result<HashMap<String, String>> {
        Ok(self
            .artists(&self.by_ids(&ids).await?)
            .into_iter()
            .filter_map(|artist| Some((artist.id, artist.cover?)))
            .collect())
    }

    /// No likes yet.
    async fn saved_tracks(&self) -> Result<Vec<Track>> {
        Ok(Vec::new())
    }

    async fn all_tracks(&self) -> Result<Vec<Track>> {
        Ok(self.tracks(
            self.library(TRACK, &[])
                .await
                .context("cannot load the songs")?,
        ))
    }

    async fn set_track_saved(&self, _track_id: &str, _saved: bool) -> Result<()> {
        anyhow::bail!("{NOT_YET}")
    }

    async fn track(&self, track_id: &str) -> Result<Track> {
        let item = self
            .metadata(track_id)
            .await
            .with_context(|| format!("cannot load the song {track_id}"))?;
        Ok(self.tracks(vec![item]).remove(0))
    }

    async fn track_playcount(&self, track_id: &str) -> Result<Option<u64>> {
        Ok(self
            .metadata(track_id)
            .await
            .ok()
            .and_then(|item| item.view_count))
    }

    async fn playlists(&self) -> Result<Vec<Playlist>> {
        let items = self
            .all("/playlists", &[("playlistType", "audio")])
            .await
            .context("cannot load the playlists")?;
        Ok(self.playlists_of(items))
    }

    async fn create_playlist(&self, _name: &str) -> Result<String> {
        anyhow::bail!("{NOT_YET}")
    }

    async fn rename_playlist(&self, _playlist_id: &str, _name: &str) -> Result<()> {
        anyhow::bail!("{NOT_YET}")
    }

    async fn delete_playlist(&self, _playlist_id: &str) -> Result<()> {
        anyhow::bail!("{NOT_YET}")
    }

    async fn remove_playlist_from_library(&self, _playlist_id: &str) -> Result<()> {
        anyhow::bail!("{NO_LIBRARY}")
    }

    async fn add_playlist_to_library(&self, _playlist_id: &str) -> Result<()> {
        anyhow::bail!("{NO_LIBRARY}")
    }

    async fn set_playlist_public(&self, _playlist_id: &str, _public: bool) -> Result<()> {
        anyhow::bail!("plex playlists have no public setting")
    }

    async fn add_track_to_playlist(&self, _playlist_id: &str, _track_id: &str) -> Result<()> {
        anyhow::bail!("{NOT_YET}")
    }

    async fn remove_track_from_playlist(
        &self,
        _playlist_id: &str,
        _track_id: &str,
        _copy: usize,
    ) -> Result<()> {
        anyhow::bail!("{NOT_YET}")
    }

    /// No likes yet.
    async fn saved_albums(&self) -> Result<Vec<Album>> {
        Ok(Vec::new())
    }

    async fn all_albums(&self) -> Result<Vec<Album>> {
        Ok(self.albums(
            self.library(ALBUM, &[])
                .await
                .context("cannot load the albums")?,
        ))
    }

    async fn set_album_saved(&self, _album_id: &str, _saved: bool) -> Result<()> {
        anyhow::bail!("{NOT_YET}")
    }

    /// No likes yet.
    async fn saved_artists(&self) -> Result<Vec<SavedArtist>> {
        Ok(Vec::new())
    }

    async fn all_artists(&self) -> Result<Vec<SavedArtist>> {
        let artists = self
            .library(ARTIST, &[])
            .await
            .context("cannot load the artists")?;
        Ok(self.artists(&artists))
    }

    async fn set_artist_saved(&self, _artist_id: &str, _saved: bool) -> Result<()> {
        anyhow::bail!("{NOT_YET}")
    }

    async fn album(&self, album_id: &str) -> Result<AlbumDetail> {
        let (item, tracks) = tokio::join!(self.metadata(album_id), self.children(album_id));
        let item = item.with_context(|| format!("cannot load the album {album_id}"))?;
        let tracks =
            self.tracks(tracks.with_context(|| format!("cannot load the album {album_id}"))?);
        let mut album = wire::album(item, &self.art());
        if album.track_count == 0 {
            album.track_count = tracks.len() as u32;
        }
        Ok(AlbumDetail { album, tracks })
    }

    async fn album_tracks(&self, album_id: &str) -> Result<Vec<Track>> {
        Ok(self.album(album_id).await?.tracks)
    }

    async fn playlist(&self, playlist_id: &str) -> Result<PlaylistDetail> {
        let path = format!("/playlists/{}", crate::escape::component(playlist_id));
        let items = format!("{path}/items");
        let (item, tracks) = tokio::join!(self.get(&path, &[]), self.all(&items, &[]));
        let item = item
            .ok()
            .and_then(|container| container.metadata.into_iter().next())
            .with_context(|| format!("cannot load the playlist {playlist_id}"))?;
        let tracks =
            self.tracks(tracks.with_context(|| format!("cannot load the playlist {playlist_id}"))?);
        let mut playlist = wire::playlist(item, &self.art());
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

    /// No stations, which `Capabilities::radio` being off keeps out of sight.
    async fn track_radio(
        &self,
        _track_id: &str,
        _from: Option<&str>,
    ) -> Result<(Vec<Track>, Option<String>)> {
        Ok((Vec::new(), None))
    }

    async fn search(&self, query: &str) -> Result<Vec<Track>> {
        Ok(self.tracks(self.search_hub(query, "track", SEARCH_TRACKS).await?))
    }

    async fn search_albums(&self, query: &str) -> Result<Vec<Album>> {
        Ok(self.albums(self.search_hub(query, "album", SEARCH_OTHERS).await?))
    }

    async fn search_playlists(&self, query: &str) -> Result<Vec<Playlist>> {
        Ok(self.playlists_of(self.search_hub(query, "playlist", SEARCH_OTHERS).await?))
    }

    /// Subsonic's shelves: random songs, then the newest and the most played albums.
    async fn home(&self) -> Result<HomeFeed> {
        let (random, newest, played) = tokio::join!(
            self.first(TRACK, "random", HOME_SONGS),
            self.first(ALBUM, "addedAt:desc", HOME_ALBUMS),
            self.first(ALBUM, "viewCount:desc", HOME_ALBUMS),
        );
        // Nothing read at all is an error rather than an empty home, so it is asked again.
        if let (Err(error), Err(_), Err(_)) = (&random, &newest, &played) {
            anyhow::bail!("cannot load the home feed: {error:#}");
        }
        let shelf = |read: Result<Vec<Metadata>>| {
            read.inspect_err(|error| log::warn!("plex: a home shelf failed: {error:#}"))
                .unwrap_or_default()
        };
        let played: Vec<Metadata> = shelf(played)
            .into_iter()
            .filter(|album| album.view_count.unwrap_or(0) > 0)
            .collect();
        Ok(crate::jellyfin::home(
            self.tracks(shelf(random)),
            self.albums(shelf(newest)),
            self.albums(played),
        ))
    }

    async fn genres(&self) -> Result<Vec<Genre>> {
        let mut genres = Vec::new();
        for section in self.sections.iter() {
            let found = self
                .get(
                    &format!("/library/sections/{section}/genre"),
                    &[("type", ALBUM.to_owned())],
                )
                .await
                .context("cannot load the genres")?;
            genres.extend(
                found
                    .directory
                    .into_iter()
                    .map(|directory| wire::genre(section, directory)),
            );
        }
        Ok(genres)
    }

    async fn genre(&self, genre_id: &str) -> Result<GenreDetail> {
        let (section, key) = genre_id.split_once(':').context("not a plex genre")?;
        let path = format!(
            "/library/sections/{}/all",
            crate::escape::component(section)
        );
        let query = [("type", ALBUM), ("genre", key), ("sort", "titleSort")];
        let (albums, genres) =
            tokio::join!(self.page(&path, &query, 0, GENRE_ALBUMS), self.genres());
        let albums = albums.with_context(|| format!("cannot load the genre {genre_id}"))?;
        let name = genres
            .ok()
            .and_then(|genres| genres.into_iter().find(|genre| genre.id == genre_id))
            .map_or_else(|| key.to_owned(), |genre| genre.name);
        let items: Vec<GenreItem> = self
            .albums(albums.metadata)
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
    fn a_conversion_is_a_progressive_mp3_at_the_ceiling() {
        let query = transcode_query("1203", 128, "s1");
        let value = |key: &str| {
            query
                .iter()
                .find(|(name, _)| *name == key)
                .map(|(_, value)| value.as_str())
        };
        assert_eq!(value("path"), Some("/library/metadata/1203"));
        assert_eq!(value("protocol"), Some("http"));
        assert_eq!(value("directPlay"), Some("0"));
        assert_eq!(value("maxAudioBitrate"), Some("128"));
        assert_eq!(value("session"), Some("s1"));
        assert!(query.iter().all(|(key, _)| !key.contains("Token")));
    }

    #[test]
    fn the_token_goes_in_a_sensitive_header() {
        let sent = headers("c1", Some("t0k")).unwrap();
        let token = sent.get("x-plex-token").unwrap();
        assert!(token.is_sensitive());
        assert_eq!(sent.get("x-plex-client-identifier").unwrap(), "c1");
        assert_eq!(sent.get("x-plex-product").unwrap(), "Cauce");
        assert_eq!(sent.get("accept").unwrap(), "application/json");
        assert!(headers("c1", None).unwrap().get("x-plex-token").is_none());
    }
}
