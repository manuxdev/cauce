use std::collections::HashMap;
use std::sync::Arc;
use std::time::{Duration, SystemTime};

use anyhow::{Context as _, Result, anyhow};
use async_trait::async_trait;
use reqwest::header::{ACCEPT, HeaderMap, HeaderName, HeaderValue};
use reqwest::{Method, StatusCode};

use crate::engine::Loudness;
use crate::lyrics::lrc;
use crate::plex::auth::Credentials;
use crate::plex::wire::{self, Answer, Art, Container, Metadata, Plan};
use crate::{
    Album, AlbumDetail, Artist, ArtistProfile, Genre, GenreDetail, GenreItem, GenreSection,
    HomeFeed, Lyrics, MediaKind, MusicApi, Playlist, PlaylistDetail, SavedArtist, Track, Transcode,
    UserProfile, distinct_covers,
};

/// What names the server's library to the routes that take an item by uri.
const LIBRARY: &str = "com.plexapp.plugins.library";
/// Plex keeps each account's playlists to itself, with no library of other people's.
const NO_LIBRARY: &str = "plex has no library of saved playlists";
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

/// The entry id of the `copy`-th entry (from 0) of `track_id` among a playlist's `items`.
pub(crate) fn entry_of(items: &[Metadata], track_id: &str, copy: usize) -> Option<String> {
    let index = crate::entry_index(
        items.iter().map(|item| item.rating_key.as_str()),
        track_id,
        copy,
    )?;
    items[index]
        .playlist_item_id
        .clone()
        .filter(|id| !id.is_empty())
}

/// What names library items to the playlist routes: the server, then the items.
pub(crate) fn library_uri(server_id: &str, ids: &[String]) -> String {
    let root = format!("server://{server_id}/{LIBRARY}");
    match ids.is_empty() {
        true => root,
        false => format!("{root}/library/metadata/{}", ids.join(",")),
    }
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

    async fn change(
        &self,
        method: Method,
        path: &str,
        query: &[(&str, String)],
    ) -> Result<reqwest::Response> {
        self.sent(self.request(method, path, query)).await
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

    /// Every liked item of Plex type `kind`, as `name` calls it in a filter. The liked ones are
    /// picked again here, so a server that ignored the filter still likes nothing extra, and one
    /// that refuses it is read whole.
    async fn liked(&self, kind: &str, name: &str) -> Result<Vec<Metadata>> {
        let filter = format!("{name}.userRating");
        let rating = (wire::LIKED as u32).to_string();
        let items = match self
            .library(kind, &[(filter.as_str(), rating.as_str())])
            .await
        {
            Ok(items) => items,
            Err(error) if !crate::trouble::offline(&format!("{error:#}")) => {
                log::warn!("plex: the rating filter was refused, reading everything: {error:#}");
                self.library(kind, &[]).await?
            }
            Err(error) => return Err(error),
        };
        Ok(items.into_iter().filter(wire::liked).collect())
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

    /// Rates any item: five stars for a like, none for taking it back.
    async fn rate(&self, id: &str, liked: bool) -> Result<()> {
        let rating = match liked {
            true => (wire::LIKED as u32).to_string(),
            false => "-1".to_owned(),
        };
        let query = [
            ("key", id.to_owned()),
            ("identifier", LIBRARY.to_owned()),
            ("rating", rating),
        ];
        self.change(Method::PUT, "/:/rate", &query).await?;
        Ok(())
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

    /// The lyrics the server holds for a track, or none when it has none: a `.lrc` beside it
    /// becomes synced lyrics, and a `.txt` or lyrics in its tags plain ones.
    pub(crate) async fn lyrics(&self, track_id: &str) -> Result<Option<Lyrics>> {
        let item = self.metadata(track_id).await?;
        let Some(key) = wire::lyrics_key(&item) else {
            return Ok(None);
        };
        let text = self
            .sent(self.request(Method::GET, &key, &[]))
            .await?
            .text()
            .await
            .map_err(|error| self.fail(error))?;
        Ok(read_lyrics(&text))
    }
}

/// Lyrics from the text of a lyrics stream: synced when it reads as LRC, plain otherwise.
pub(crate) fn read_lyrics(text: &str) -> Option<Lyrics> {
    let text = text.trim_start_matches('\u{feff}');
    let lines = lrc::parse(text);
    if !lines.is_empty() {
        return Some(Lyrics::Synced {
            lines: lines.into(),
        });
    }
    let text = text.replace("\r\n", "\n");
    (!text.trim().is_empty()).then(|| Lyrics::plain(text.trim().to_owned()))
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

    async fn saved_tracks(&self) -> Result<Vec<Track>> {
        Ok(self.tracks(
            self.liked(TRACK, "track")
                .await
                .context("cannot load the liked songs")?,
        ))
    }

    async fn all_tracks(&self) -> Result<Vec<Track>> {
        Ok(self.tracks(
            self.library(TRACK, &[])
                .await
                .context("cannot load the songs")?,
        ))
    }

    async fn set_track_saved(&self, track_id: &str, saved: bool) -> Result<()> {
        self.rate(track_id, saved)
            .await
            .with_context(|| format!("cannot change the like for {track_id}"))
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

    /// Counts a listen: the play count goes up and the track becomes the last one played. Plex
    /// records it as of now; it takes no date.
    async fn played(&self, track_id: &str, _at: SystemTime) -> Result<()> {
        let query = [
            ("key", track_id.to_owned()),
            ("identifier", LIBRARY.to_owned()),
        ];
        self.change(Method::GET, "/:/scrobble", &query)
            .await
            .with_context(|| format!("cannot record a play of {track_id}"))?;
        Ok(())
    }

    async fn playlists(&self) -> Result<Vec<Playlist>> {
        let items = self
            .all("/playlists", &[("playlistType", "audio")])
            .await
            .context("cannot load the playlists")?;
        Ok(self.playlists_of(items))
    }

    /// A new playlist with nothing in it, named after the library alone.
    async fn create_playlist(&self, name: &str) -> Result<String> {
        let query = [
            ("type", "audio".to_owned()),
            ("title", name.to_owned()),
            ("smart", "0".to_owned()),
            ("uri", library_uri(&self.server_id, &[])),
        ];
        let answer: Answer = self
            .change(Method::POST, "/playlists", &query)
            .await
            .context("cannot create the playlist")?
            .json()
            .await
            .map_err(|error| self.fail(error))
            .context("cannot read the new playlist")?;
        answer
            .container
            .metadata
            .into_iter()
            .next()
            .map(|item| item.rating_key)
            .filter(|id| !id.is_empty())
            .context("the plex server named no new playlist")
    }

    async fn rename_playlist(&self, playlist_id: &str, name: &str) -> Result<()> {
        let path = format!("/playlists/{}", crate::escape::component(playlist_id));
        self.change(Method::PUT, &path, &[("title", name.to_owned())])
            .await
            .context("cannot rename the playlist")?;
        Ok(())
    }

    async fn delete_playlist(&self, playlist_id: &str) -> Result<()> {
        let path = format!("/playlists/{}", crate::escape::component(playlist_id));
        self.change(Method::DELETE, &path, &[])
            .await
            .context("cannot delete the playlist")?;
        Ok(())
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

    async fn add_track_to_playlist(&self, playlist_id: &str, track_id: &str) -> Result<()> {
        self.add_tracks_to_playlist(playlist_id, &[track_id.to_owned()])
            .await
    }

    /// Adds the tracks in order, a hundred to a request.
    async fn add_tracks_to_playlist(&self, playlist_id: &str, track_ids: &[String]) -> Result<()> {
        let path = format!("/playlists/{}/items", crate::escape::component(playlist_id));
        for chunk in track_ids.chunks(IDS_PER_REQUEST) {
            let query = [("uri", library_uri(&self.server_id, chunk))];
            self.change(Method::PUT, &path, &query)
                .await
                .context("cannot add to the playlist")?;
        }
        Ok(())
    }

    /// Every entry of a playlist has an id of its own, so one copy goes and the others stay.
    async fn remove_track_from_playlist(
        &self,
        playlist_id: &str,
        track_id: &str,
        copy: usize,
    ) -> Result<()> {
        let path = format!("/playlists/{}/items", crate::escape::component(playlist_id));
        let items = self
            .all(&path, &[])
            .await
            .context("cannot load the playlist")?;
        let entry = entry_of(&items, track_id, copy).context("track is not in the playlist")?;
        self.change(
            Method::DELETE,
            &format!("{path}/{}", crate::escape::component(&entry)),
            &[],
        )
        .await
        .context("cannot remove the track from the playlist")?;
        Ok(())
    }

    async fn saved_albums(&self) -> Result<Vec<Album>> {
        Ok(self.albums(
            self.liked(ALBUM, "album")
                .await
                .context("cannot load the liked albums")?,
        ))
    }

    async fn all_albums(&self) -> Result<Vec<Album>> {
        Ok(self.albums(
            self.library(ALBUM, &[])
                .await
                .context("cannot load the albums")?,
        ))
    }

    async fn set_album_saved(&self, album_id: &str, saved: bool) -> Result<()> {
        self.rate(album_id, saved)
            .await
            .with_context(|| format!("cannot change the like for album {album_id}"))
    }

    async fn saved_artists(&self) -> Result<Vec<SavedArtist>> {
        let artists = self
            .liked(ARTIST, "artist")
            .await
            .context("cannot load the liked artists")?;
        Ok(self.artists(&artists))
    }

    async fn all_artists(&self) -> Result<Vec<SavedArtist>> {
        let artists = self
            .library(ARTIST, &[])
            .await
            .context("cannot load the artists")?;
        Ok(self.artists(&artists))
    }

    async fn set_artist_saved(&self, artist_id: &str, saved: bool) -> Result<()> {
        self.rate(artist_id, saved)
            .await
            .with_context(|| format!("cannot change the like for artist {artist_id}"))
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

    fn entry(id: &str, entry: &str) -> Metadata {
        Metadata {
            rating_key: id.into(),
            playlist_item_id: Some(entry.into()),
            ..Metadata::default()
        }
    }

    #[test]
    fn a_copy_of_a_track_is_removed_by_its_own_entry() {
        let items = [entry("1", "10"), entry("2", "11"), entry("1", "12")];
        assert_eq!(entry_of(&items, "1", 0).as_deref(), Some("10"));
        assert_eq!(entry_of(&items, "1", 1).as_deref(), Some("12"));
        assert_eq!(entry_of(&items, "1", 2), None);
        assert_eq!(entry_of(&items, "3", 0), None);
    }

    #[test]
    fn library_items_are_named_through_the_server() {
        assert_eq!(
            library_uri("abc", &["1".into(), "2".into()]),
            "server://abc/com.plexapp.plugins.library/library/metadata/1,2"
        );
        assert_eq!(
            library_uri("abc", &[]),
            "server://abc/com.plexapp.plugins.library"
        );
    }

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

    #[test]
    fn lyrics_read_as_lrc_are_synced_and_otherwise_plain() {
        let synced = read_lyrics("\u{feff}[00:01.00]First\n[00:04.50]Second\n").unwrap();
        let Lyrics::Synced { lines } = synced else {
            panic!("expected synced lyrics");
        };
        assert_eq!(lines[1].text, "Second");
        assert_eq!(lines[1].start, Duration::from_millis(4_500));
        assert_eq!(
            read_lyrics("First line\r\nSecond line\r\n"),
            Some(Lyrics::plain("First line\nSecond line"))
        );
        assert_eq!(read_lyrics("  \n"), None);
    }
}

/// Against a Plex Media Server of your own, by hand, as nothing public serves one:
/// `PLEX_SERVER=http://127.0.0.1:32400 PLEX_TOKEN=… cargo test -p music --lib plex_live -- --ignored`.
/// An empty token works for a server that lets this network in without signing in. The library
/// needs two tracks, one with an `.lrc` beside it. It stores nothing, never prints the token, and
/// undoes what it makes.
#[cfg(test)]
mod plex_live {
    use super::*;
    use crate::Codec;

    #[tokio::test]
    #[ignore = "reaches the Plex server in PLEX_SERVER"]
    async fn plex_live_browses_streams_likes_edits_reads_lyrics_and_plays() {
        let env = |key: &str| std::env::var(key).unwrap_or_default();
        let server = env("PLEX_SERVER").trim_end_matches('/').to_owned();
        let token = env("PLEX_TOKEN");
        let probe = PlexClient::new(&Credentials {
            server: server.clone(),
            addresses: vec![server.clone()],
            server_id: String::new(),
            server_name: String::new(),
            user_id: "live".into(),
            username: "live".into(),
            client_id: "cauce-live-check".into(),
            token: token.clone(),
        })
        .unwrap();
        let identity: serde_json::Value = probe
            .sent(probe.request(Method::GET, "/identity", &[]))
            .await
            .unwrap()
            .json()
            .await
            .unwrap();
        let machine = identity["MediaContainer"]["machineIdentifier"]
            .as_str()
            .unwrap()
            .to_owned();
        let client = PlexClient {
            server_id: machine,
            ..probe.clone()
        };
        let sections = client.music_sections().await.unwrap();
        let client = client.with_sections(sections);
        let tracks = client.all_tracks().await.unwrap();
        let albums = client.all_albums().await.unwrap();
        let artists = client.all_artists().await.unwrap();
        let genres = client.genres().await.unwrap();
        println!(
            "{} tracks, {} albums, {} artists, {} genres",
            tracks.len(),
            albums.len(),
            artists.len(),
            genres.len()
        );
        let found = client.search(&tracks[0].name).await.unwrap();
        let artist = client.artist(&artists[0].id).await.unwrap();
        let album = client.album(&albums[0].id).await.unwrap();
        let home = client.home().await.unwrap();
        println!(
            "search {}, artist {} top tracks and {} albums, album {} tracks, home {} shelves",
            found.len(),
            artist.top_tracks.len(),
            artist.albums.len(),
            album.tracks.len(),
            home.sections.len()
        );
        if let Some(genre) = genres.first() {
            println!(
                "genre {}: {} shelves",
                genre.name,
                client.genre(&genre.id).await.unwrap().sections.len()
            );
        }
        let ids: Vec<String> = tracks.iter().filter_map(|track| track.id.clone()).collect();
        let (first, second) = (ids[0].clone(), ids[1].clone());
        for transcode in [
            Transcode::default(),
            Transcode {
                codec: Some(Codec::Mp3),
                bitrate: Some(96),
            },
        ] {
            let (mut response, details) = client.open_stream(&first, transcode).await.unwrap();
            let chunk = response.chunk().await.unwrap().unwrap();
            println!(
                "{transcode:?} streams {:?}, first bytes {:02x?}, {details:?}",
                response.headers().get("content-type"),
                &chunk[..4]
            );
        }

        client.set_track_saved(&first, true).await.unwrap();
        client.set_album_saved(&albums[0].id, true).await.unwrap();
        client.set_artist_saved(&artists[0].id, true).await.unwrap();
        let liked = (
            client.saved_tracks().await.unwrap().len(),
            client.saved_albums().await.unwrap().len(),
            client.saved_artists().await.unwrap().len(),
        );
        client.set_track_saved(&first, false).await.unwrap();
        client.set_album_saved(&albums[0].id, false).await.unwrap();
        client
            .set_artist_saved(&artists[0].id, false)
            .await
            .unwrap();
        let unliked = client.saved_tracks().await.unwrap().len();
        println!("likes: {liked:?} then {unliked} tracks");

        let playlist = client.create_playlist("cauce-live-check").await.unwrap();
        let edits = async {
            client
                .add_tracks_to_playlist(&playlist, &[first.clone(), second.clone()])
                .await?;
            client.add_track_to_playlist(&playlist, &first).await?;
            client
                .remove_track_from_playlist(&playlist, &first, 1)
                .await?;
            client
                .rename_playlist(&playlist, "cauce-live-check renamed")
                .await?;
            let mine = client
                .playlists()
                .await?
                .into_iter()
                .find(|p| p.id == playlist);
            let detail = client.playlist(&playlist).await?;
            anyhow::Ok((mine.is_some_and(|p| p.owned), detail))
        }
        .await;
        client.delete_playlist(&playlist).await.unwrap();
        let gone = !client
            .playlists()
            .await
            .unwrap()
            .iter()
            .any(|p| p.id == playlist);
        let (owned, detail) = edits.unwrap();
        let left: Vec<String> = detail.tracks.iter().filter_map(|t| t.id.clone()).collect();
        println!("playlist: owned {owned}, left {}, gone {gone}", left.len());

        let mut lyrics = Vec::new();
        for id in &ids {
            if let Some(found) = client.lyrics(id).await.unwrap() {
                lyrics.push(found);
            }
        }
        println!("lyrics: {} tracks have some", lyrics.len());

        let before = client.track_playcount(&second).await.unwrap().unwrap_or(0);
        client.played(&second, SystemTime::now()).await.unwrap();
        let after = client.track_playcount(&second).await.unwrap().unwrap_or(0);
        println!("plays: {before} then {after}");

        assert!(!found.is_empty() && !album.tracks.is_empty() && !artist.albums.is_empty());
        assert!(liked.0 >= 1 && liked.1 >= 1 && liked.2 >= 1 && owned && gone);
        assert_eq!(left, [first, second.clone()]);
        assert_eq!(detail.playlist.name, "cauce-live-check renamed");
        assert!(after > before);
    }
}
