use std::collections::{HashMap, HashSet};
use std::time::{Duration, SystemTime};

use anyhow::{Context as _, Result, anyhow};
use async_trait::async_trait;
use reqwest::header::{HeaderName, HeaderValue};
use reqwest::{Method, StatusCode};
use serde::de::DeserializeOwned;

use crate::engine::Loudness;
use crate::jellyfin::Flavor;
use crate::jellyfin::auth::{self, Credentials};
use crate::jellyfin::lyrics::{self, Answer};
use crate::jellyfin::wire::{
    self, Authenticated, Item, Items, PlaylistEntries, PlaylistUser, Removal, User,
};
use crate::{
    Album, AlbumDetail, Artist, ArtistProfile, Codec, Genre, GenreDetail, GenreItem, GenreSection,
    HomeFeed, Lyrics, MediaKind, MusicApi, Playlist, PlaylistDetail, SavedArtist, Track, Transcode,
    UserProfile, distinct_covers,
};

/// The server has no library of other people's playlists to save to or drop from.
const NO_LIBRARY: &str = "the server has no library of saved playlists";
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
        HeaderValue::from_str(authorization).context("cannot build the server authorization")?;
    value.set_sensitive(true);
    Ok(value)
}

fn header_name(flavor: Flavor) -> HeaderName {
    HeaderName::from_static(auth::header_name(flavor))
}

/// Where the signed-in account is read: Emby has no `/Users/Me`.
pub(crate) fn profile_path(flavor: Flavor, user_id: &str) -> String {
    match flavor {
        Flavor::Jellyfin => "/Users/Me".to_owned(),
        Flavor::Emby => format!("/Users/{}", crate::escape::component(user_id)),
    }
}

/// Where one item is read for the user: Emby has no `/Items/{id}`.
pub(crate) fn item_path(flavor: Flavor, user_id: &str, id: &str) -> String {
    let id = crate::escape::component(id);
    match flavor {
        Flavor::Jellyfin => format!("/Items/{id}"),
        Flavor::Emby => format!("/Users/{}/Items/{id}", crate::escape::component(user_id)),
    }
}

/// What an `Ids=` lookup adds: Emby finds no album or artist by id unless asked for its kind.
pub(crate) fn ids_query(flavor: Flavor) -> Vec<(&'static str, &'static str)> {
    match flavor {
        Flavor::Jellyfin => Vec::new(),
        Flavor::Emby => vec![
            ("Recursive", "true"),
            ("IncludeItemTypes", "Audio,MusicAlbum,MusicArtist"),
        ],
    }
}

/// Where a listen is counted, and its date in the form each server reads.
pub(crate) fn played_request(
    flavor: Flavor,
    user_id: &str,
    track_id: &str,
    at: SystemTime,
) -> (String, Vec<(&'static str, String)>) {
    let track = crate::escape::component(track_id);
    match flavor {
        Flavor::Jellyfin => (
            format!("/UserPlayedItems/{track}"),
            vec![
                ("userId", user_id.to_owned()),
                ("datePlayed", wire::iso_8601(at)),
            ],
        ),
        Flavor::Emby => (
            format!(
                "/Users/{}/PlayedItems/{track}",
                crate::escape::component(user_id)
            ),
            vec![("DatePlayed", wire::emby_date(at))],
        ),
    }
}

/// Signs in with the password and answers what to store. The password goes in the body of this
/// one request and nowhere else.
pub async fn authenticate(
    flavor: Flavor,
    server: &str,
    username: &str,
    password: &str,
    device_id: &str,
) -> Result<Credentials> {
    let response = reqwest::Client::new()
        .post(format!("{server}/Users/AuthenticateByName"))
        .header(
            header_name(flavor),
            header(&auth::authorization(device_id, None))?,
        )
        .json(&serde_json::json!({ "Username": username, "Pw": password }))
        .send()
        .await
        .map_err(|error| failed(error, ""))
        .with_context(|| format!("cannot reach the {} server", flavor.slug()))?;
    if response.status() == reqwest::StatusCode::UNAUTHORIZED {
        anyhow::bail!(
            "the {} server refused the username or password",
            flavor.slug()
        );
    }
    let answer: Authenticated = response
        .error_for_status()
        .map_err(|error| failed(error, ""))
        .with_context(|| format!("the {} server refused the sign-in", flavor.slug()))?
        .json()
        .await
        .map_err(|error| failed(error, ""))
        .with_context(|| format!("cannot read the {} sign-in answer", flavor.slug()))?;
    Ok(wire::credentials(answer, server, device_id, flavor))
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
            .header(header_name(credentials.flavor), value)
            .send()?
            .error_for_status()?;
        Ok(())
    });
    if let Err(error) = sent {
        log::info!(
            "{}: the server did not take the sign-out: {}",
            credentials.flavor.slug(),
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
    flavor: Flavor,
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
            flavor: credentials.flavor,
        })
    }

    /// The account and server this client plays from. A track id only means something on its
    /// own server, so this tells apart two servers' tracks that share one.
    pub fn identity(&self) -> String {
        format!("{}@{}", self.user_id, self.server)
    }

    pub fn flavor(&self) -> Flavor {
        self.flavor
    }

    fn fail(&self, error: reqwest::Error) -> anyhow::Error {
        failed(error, &self.token)
    }

    fn request(
        &self,
        method: Method,
        path: &str,
        query: &[(&str, String)],
    ) -> reqwest::RequestBuilder {
        self.http
            .request(method, format!("{}{path}", self.server))
            .header(header_name(self.flavor), self.authorization.clone())
            .query(query)
    }

    async fn sent(&self, request: reqwest::RequestBuilder) -> Result<reqwest::Response> {
        request
            .send()
            .await
            .map_err(|error| self.fail(error))?
            .error_for_status()
            .map_err(|error| self.fail(error))
    }

    async fn send(&self, path: &str, query: &[(&str, String)]) -> Result<reqwest::Response> {
        self.sent(self.request(Method::GET, path, query)).await
    }

    /// A change: `method` on `path`, with `body` as JSON when there is one.
    async fn change(
        &self,
        method: Method,
        path: &str,
        query: &[(&str, String)],
        body: Option<serde_json::Value>,
    ) -> Result<reqwest::Response> {
        let mut request = self.request(method, path, query);
        if let Some(body) = body {
            request = request.json(&body);
        }
        self.sent(request).await
    }

    fn user(&self) -> [(&'static str, String); 1] {
        [("userId", self.user_id.clone())]
    }

    /// Likes or unlikes any item. Jellyfin 10.9 and later take `/UserFavoriteItems`; an older
    /// server that answers 404 there, and Emby, get the route under the user.
    async fn favorite(&self, id: &str, saved: bool) -> Result<()> {
        let method = match saved {
            true => Method::POST,
            false => Method::DELETE,
        };
        let id = crate::escape::component(id);
        let user = crate::escape::component(&self.user_id);
        let old = format!("/Users/{user}/FavoriteItems/{id}");
        if self.flavor == Flavor::Emby {
            self.change(method, &old, &[], None).await?;
            return Ok(());
        }
        let current = self
            .request(
                method.clone(),
                &format!("/UserFavoriteItems/{id}"),
                &self.user(),
            )
            .send()
            .await
            .map_err(|error| self.fail(error))?;
        if current.status() != StatusCode::NOT_FOUND {
            current
                .error_for_status()
                .map_err(|error| self.fail(error))?;
            return Ok(());
        }
        self.change(method, &old, &[], None).await?;
        Ok(())
    }

    /// Every liked item of `kind`, by name.
    async fn favorites(&self, kind: &str) -> Result<Vec<Item>> {
        let items = self
            .all(
                "/Items",
                &[
                    ("Filters", "IsFavorite"),
                    ("Recursive", "true"),
                    ("IncludeItemTypes", kind),
                    ("SortBy", "SortName"),
                ],
            )
            .await?;
        Ok(wire::favorites(items))
    }

    /// Whether the listener may change the playlist. The server forbids asking about one they
    /// may not, which reads as no.
    async fn playlist_user(&self, playlist_id: &str) -> Option<PlaylistUser> {
        let path = format!(
            "/Playlists/{}/Users/{}",
            crate::escape::component(playlist_id),
            crate::escape::component(&self.user_id)
        );
        self.get(&path, &[]).await.ok()
    }

    /// Changes a playlist through the 10.9+ update, which takes only the fields it is given.
    async fn update_playlist(&self, playlist_id: &str, body: serde_json::Value) -> Result<()> {
        let path = format!("/Playlists/{}", crate::escape::component(playlist_id));
        self.change(Method::POST, &path, &[], Some(body)).await?;
        Ok(())
    }

    /// The lyrics the server holds for a track, or none when it has none.
    pub(crate) async fn lyrics(&self, track_id: &str) -> Result<Option<Answer>> {
        let path = format!("/Audio/{}/Lyrics", crate::escape::component(track_id));
        let response = self
            .request(Method::GET, &path, &[])
            .send()
            .await
            .map_err(|error| self.fail(error))?;
        if response.status() == StatusCode::NOT_FOUND {
            return Ok(None);
        }
        let answer = response
            .error_for_status()
            .map_err(|error| self.fail(error))?
            .json()
            .await
            .map_err(|error| self.fail(error))?;
        Ok(Some(answer))
    }

    /// The lyrics the server holds for a track, or none when it has none. Emby has no lyrics
    /// route: it lists them as a subtitle of the track, read here with their times.
    pub(crate) async fn server_lyrics(&self, track_id: &str) -> Result<Option<Lyrics>> {
        if self.flavor == Flavor::Jellyfin {
            return Ok(self.lyrics(track_id).await?.and_then(lyrics::lyrics));
        }
        let path = item_path(self.flavor, &self.user_id, track_id);
        let item: Item = self
            .get(&path, &[("Fields", "MediaSources".to_owned())])
            .await?;
        let Some((source, index)) = wire::lyrics_stream(&item) else {
            return Ok(None);
        };
        let path = format!(
            "/Items/{}/{}/Subtitles/{index}/Stream.srt",
            crate::escape::component(track_id),
            crate::escape::component(&source)
        );
        let text = self
            .send(&path, &[])
            .await?
            .text()
            .await
            .map_err(|error| self.fail(error))?;
        Ok(lyrics::srt(&text))
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
            &item_path(self.flavor, &self.user_id, id),
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
            let mut query = ids_query(self.flavor);
            query.push(("Ids", ids.as_str()));
            items.extend(self.page("/Items", &query, 0, chunk.len()).await?.items);
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
            .map(|item| wire::playlist(item, &self.server, None))
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
            .get(&profile_path(self.flavor, &self.user_id), &[])
            .await
            .with_context(|| format!("cannot reach the {} server", self.flavor.slug()))?;
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
            log::warn!(
                "{}: cannot load the artist's albums: {error:#}",
                self.flavor.slug()
            );
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
        Ok(self.tracks(
            self.favorites("Audio")
                .await
                .context("cannot load the liked songs")?,
        ))
    }

    async fn all_tracks(&self) -> Result<Vec<Track>> {
        Ok(self.tracks(
            self.library("Audio")
                .await
                .context("cannot load the songs")?,
        ))
    }

    async fn set_track_saved(&self, track_id: &str, saved: bool) -> Result<()> {
        self.favorite(track_id, saved)
            .await
            .with_context(|| format!("cannot change the like for {track_id}"))
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

    /// Every playlist the listener sees, their own marked so. Jellyfin names no owner on a
    /// listed playlist, so each one is asked whether the listener may change it. Emby lists only
    /// the listener's own.
    // ponytail: one request per playlist; a shared playlist the listener may edit counts as
    // their own, so deleting it fails on the server. Tell the two apart if shares get used.
    async fn playlists(&self) -> Result<Vec<Playlist>> {
        let items = self
            .library("Playlist")
            .await
            .context("cannot load the playlists")?;
        if self.flavor == Flavor::Emby {
            let mine = || Some(PlaylistUser { can_edit: true });
            return Ok(items
                .into_iter()
                .map(|item| wire::playlist(item, &self.server, mine()))
                .collect());
        }
        let users =
            futures::future::join_all(items.iter().map(|item| self.playlist_user(&item.id))).await;
        Ok(items
            .into_iter()
            .zip(users)
            .map(|(item, user)| wire::playlist(item, &self.server, user))
            .collect())
    }

    async fn create_playlist(&self, name: &str) -> Result<String> {
        #[derive(serde::Deserialize)]
        #[serde(rename_all = "PascalCase")]
        struct Created {
            id: String,
        }
        // Emby takes the new playlist in the query and fails on a body.
        let (query, body) = match self.flavor {
            Flavor::Jellyfin => (
                Vec::new(),
                Some(serde_json::json!({
                    "Name": name,
                    "UserId": self.user_id,
                    "MediaType": "Audio",
                    "Ids": [],
                })),
            ),
            Flavor::Emby => (
                vec![
                    ("Name", name.to_owned()),
                    ("UserId", self.user_id.clone()),
                    ("MediaType", "Audio".to_owned()),
                ],
                None,
            ),
        };
        let created: Created = self
            .change(Method::POST, "/Playlists", &query, body)
            .await
            .context("cannot create the playlist")?
            .json()
            .await
            .map_err(|error| self.fail(error))
            .context("cannot read the new playlist")?;
        Ok(created.id)
    }

    /// Emby has no playlist update, so it takes the whole item back with the new name.
    async fn rename_playlist(&self, playlist_id: &str, name: &str) -> Result<()> {
        if self.flavor == Flavor::Jellyfin {
            return self
                .update_playlist(playlist_id, serde_json::json!({ "Name": name }))
                .await
                .context("cannot rename the playlist");
        }
        let mut item: serde_json::Value = self
            .get(&item_path(self.flavor, &self.user_id, playlist_id), &[])
            .await
            .context("cannot load the playlist")?;
        item["Name"] = name.into();
        let path = format!("/Items/{}", crate::escape::component(playlist_id));
        self.change(Method::POST, &path, &[], Some(item))
            .await
            .context("cannot rename the playlist")?;
        Ok(())
    }

    async fn delete_playlist(&self, playlist_id: &str) -> Result<()> {
        let path = format!("/Items/{}", crate::escape::component(playlist_id));
        self.change(Method::DELETE, &path, &[], None)
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

    async fn set_playlist_public(&self, playlist_id: &str, public: bool) -> Result<()> {
        if self.flavor == Flavor::Emby {
            anyhow::bail!("emby playlists have no public setting");
        }
        self.update_playlist(playlist_id, serde_json::json!({ "IsPublic": public }))
            .await
            .context("cannot change the playlist visibility")
    }

    async fn add_track_to_playlist(&self, playlist_id: &str, track_id: &str) -> Result<()> {
        self.add_tracks_to_playlist(playlist_id, &[track_id.to_owned()])
            .await
    }

    /// Adds the tracks in order, a hundred to a request.
    async fn add_tracks_to_playlist(&self, playlist_id: &str, track_ids: &[String]) -> Result<()> {
        let path = format!("/Playlists/{}/Items", crate::escape::component(playlist_id));
        for chunk in track_ids.chunks(IDS_PER_LOOKUP) {
            let query = [("ids", chunk.join(",")), ("userId", self.user_id.clone())];
            self.change(Method::POST, &path, &query, None)
                .await
                .context("cannot add to the playlist")?;
        }
        Ok(())
    }

    async fn remove_track_from_playlist(
        &self,
        playlist_id: &str,
        track_id: &str,
        copy: usize,
    ) -> Result<()> {
        let escaped = crate::escape::component(playlist_id);
        let path = format!("/Playlists/{escaped}/Items");
        let entries = self
            .get::<Items>(&path, &self.user())
            .await
            .context("cannot load the playlist")?
            .items;
        match wire::removal(&entries, track_id, copy).context("track is not in the playlist")? {
            Removal::Entry(entry) => {
                self.change(Method::DELETE, &path, &[("entryIds", entry)], None)
                    .await
                    .context("cannot remove the track from the playlist")?;
            }
            Removal::Rewrite => {
                let listed: PlaylistEntries = self
                    .get(&format!("/Playlists/{escaped}"), &[])
                    .await
                    .context("cannot load the playlist")?;
                let ids = wire::without(listed.item_ids, track_id, copy)
                    .context("track is not in the playlist")?;
                self.update_playlist(playlist_id, serde_json::json!({ "Ids": ids }))
                    .await
                    .context("cannot remove the track from the playlist")?;
            }
        }
        Ok(())
    }

    async fn saved_albums(&self) -> Result<Vec<Album>> {
        Ok(self.albums(
            self.favorites("MusicAlbum")
                .await
                .context("cannot load the liked albums")?,
        ))
    }

    async fn all_albums(&self) -> Result<Vec<Album>> {
        Ok(self.albums(
            self.library("MusicAlbum")
                .await
                .context("cannot load the albums")?,
        ))
    }

    async fn set_album_saved(&self, album_id: &str, saved: bool) -> Result<()> {
        self.favorite(album_id, saved)
            .await
            .with_context(|| format!("cannot change the like for album {album_id}"))
    }

    async fn saved_artists(&self) -> Result<Vec<SavedArtist>> {
        let artists = self
            .favorites("MusicArtist")
            .await
            .context("cannot load the liked artists")?;
        Ok(artists
            .iter()
            .map(|item| wire::artist(item, &self.server))
            .collect())
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

    async fn set_artist_saved(&self, artist_id: &str, saved: bool) -> Result<()> {
        self.favorite(artist_id, saved)
            .await
            .with_context(|| format!("cannot change the like for artist {artist_id}"))
    }

    /// Counts a listen: the play count goes up and the track becomes the last one played.
    async fn played(&self, track_id: &str, at: SystemTime) -> Result<()> {
        let (path, query) = played_request(self.flavor, &self.user_id, track_id, at);
        self.change(Method::POST, &path, &query, None)
            .await
            .with_context(|| format!("cannot record a play of {track_id}"))?;
        Ok(())
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
        let mut playlist = wire::playlist(item, &self.server, None);
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
                .inspect_err(|error| {
                    log::warn!("{}: a home shelf failed: {error:#}", self.flavor.slug())
                })
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
mod flavor_tests {
    use super::*;

    #[test]
    fn emby_reads_users_and_items_through_the_user() {
        assert_eq!(profile_path(Flavor::Jellyfin, "u"), "/Users/Me");
        assert_eq!(profile_path(Flavor::Emby, "u"), "/Users/u");
        assert_eq!(item_path(Flavor::Jellyfin, "u", "i"), "/Items/i");
        assert_eq!(item_path(Flavor::Emby, "u", "i"), "/Users/u/Items/i");
    }

    #[test]
    fn emby_looks_folders_up_by_id_only_when_told_their_kind() {
        assert!(ids_query(Flavor::Jellyfin).is_empty());
        let query = ids_query(Flavor::Emby);
        assert!(query.contains(&("Recursive", "true")));
        assert!(query.contains(&("IncludeItemTypes", "Audio,MusicAlbum,MusicArtist")));
    }

    #[test]
    fn emby_counts_a_listen_on_the_users_played_items() {
        let at = std::time::UNIX_EPOCH + Duration::from_secs(1_793_131_200);
        let (path, query) = played_request(Flavor::Emby, "u", "t", at);
        assert_eq!(path, "/Users/u/PlayedItems/t");
        assert_eq!(query, [("DatePlayed", "20261027200000".to_owned())]);
        let (path, query) = played_request(Flavor::Jellyfin, "u", "t", at);
        assert_eq!(path, "/UserPlayedItems/t");
        assert_eq!(
            query,
            [
                ("userId", "u".to_owned()),
                ("datePlayed", "2026-10-27T20:00:00Z".to_owned())
            ]
        );
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
        let credentials = authenticate(Flavor::Jellyfin, &server, "demo", "", "cauce-live-check")
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

    /// Likes, a playlist's whole life, lyrics and a listen. The demo is shared, so whatever it
    /// makes is undone before anything is checked.
    #[tokio::test]
    #[ignore = "reaches demo.jellyfin.org"]
    async fn jellyfin_demo_likes_edits_playlists_reads_lyrics_and_reports_a_play() {
        let server = auth::normalize_server("demo.jellyfin.org/stable").unwrap();
        let credentials = authenticate(Flavor::Jellyfin, &server, "demo", "", "cauce-live-check")
            .await
            .unwrap();
        let client = JellyfinClient::new(&credentials).unwrap();
        let tracks = client.all_tracks().await.unwrap();
        let ids: Vec<String> = tracks.iter().filter_map(|track| track.id.clone()).collect();
        let (first, second) = (ids[0].clone(), ids[1].clone());
        let album = client.all_albums().await.unwrap()[0].id.clone();
        let artist = client.all_artists().await.unwrap()[0].id.clone();

        let liked_before = client
            .saved_tracks()
            .await
            .unwrap()
            .iter()
            .any(|t| t.id.as_ref() == Some(&first));
        client.set_track_saved(&first, true).await.unwrap();
        client.set_album_saved(&album, true).await.unwrap();
        client.set_artist_saved(&artist, true).await.unwrap();
        let liked_track = client
            .saved_tracks()
            .await
            .unwrap()
            .iter()
            .any(|t| t.id.as_ref() == Some(&first));
        let liked_album = client
            .saved_albums()
            .await
            .unwrap()
            .iter()
            .any(|a| a.id == album);
        let liked_artist = client
            .saved_artists()
            .await
            .unwrap()
            .iter()
            .any(|a| a.id == artist);
        if !liked_before {
            client.set_track_saved(&first, false).await.unwrap();
        }
        client.set_album_saved(&album, false).await.unwrap();
        client.set_artist_saved(&artist, false).await.unwrap();
        let unliked_album = !client
            .saved_albums()
            .await
            .unwrap()
            .iter()
            .any(|a| a.id == album);
        println!("likes: track {liked_track}, album {liked_album}, artist {liked_artist}");

        let playlist = client.create_playlist("cauce-live-check").await.unwrap();
        let edits = async {
            client
                .add_tracks_to_playlist(&playlist, &[first.clone(), second.clone()])
                .await?;
            client.add_track_to_playlist(&playlist, &first).await?;
            let mine = client
                .playlists()
                .await?
                .into_iter()
                .find(|p| p.id == playlist);
            client
                .remove_track_from_playlist(&playlist, &first, 1)
                .await?;
            client
                .rename_playlist(&playlist, "cauce-live-check renamed")
                .await?;
            client.set_playlist_public(&playlist, false).await?;
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
        println!(
            "playlist: owned {owned}, left {}, named {:?}, gone {gone}",
            left.len(),
            detail.playlist.name
        );

        let mut lyrics = None;
        for id in &ids {
            if let Some(found) = client
                .lyrics(id)
                .await
                .unwrap()
                .and_then(super::super::lyrics::lyrics)
            {
                lyrics = Some(found);
                break;
            }
        }
        match &lyrics {
            Some(crate::Lyrics::Synced { lines }) => {
                println!("lyrics: synced, {} lines", lines.len())
            }
            Some(_) => println!("lyrics: plain"),
            None => println!("lyrics: no demo track has any"),
        }

        let before = client.track_playcount(&second).await.unwrap().unwrap_or(0);
        client.played(&second, SystemTime::now()).await.unwrap();
        let after = client.track_playcount(&second).await.unwrap().unwrap_or(0);
        println!("plays: {before} then {after}");

        std::thread::spawn(move || logout(&credentials))
            .join()
            .unwrap();
        assert!(liked_track && liked_album && liked_artist && unliked_album);
        assert!(owned && gone);
        assert_eq!(left, [first, second.clone()]);
        assert_eq!(detail.playlist.name, "cauce-live-check renamed");
        assert!(after > before);
    }
}

/// Against an Emby server of your own, by hand, as nothing public serves one:
/// `EMBY_SERVER=… EMBY_USER=… EMBY_PASSWORD=… cargo test -p music --lib emby_live -- --ignored`.
/// The library needs two tracks, one with an `.lrc` beside it. It stores nothing, never prints
/// the token, and undoes what it makes.
#[cfg(test)]
mod emby_live {
    use super::*;

    #[tokio::test]
    #[ignore = "reaches the Emby server in EMBY_SERVER"]
    async fn emby_live_signs_in_browses_streams_likes_edits_reads_lyrics_and_plays() {
        let env = |key: &str| std::env::var(key).unwrap_or_default();
        let server = auth::normalize_server(&env("EMBY_SERVER")).unwrap();
        let credentials = authenticate(
            Flavor::Emby,
            &server,
            &env("EMBY_USER"),
            &env("EMBY_PASSWORD"),
            "cauce-live-check",
        )
        .await
        .unwrap();
        let client = JellyfinClient::new(&credentials).unwrap();
        let profile = client.profile().await.unwrap();
        let tracks = client.all_tracks().await.unwrap();
        let albums = client.all_albums().await.unwrap();
        let artists = client.all_artists().await.unwrap();
        let genres = client.genres().await.unwrap();
        println!(
            "{}: {} tracks, {} albums, {} artists, {} genres",
            profile.display_name,
            tracks.len(),
            albums.len(),
            artists.len(),
            genres.len()
        );
        let found = client.search(&tracks[0].name).await.unwrap();
        let artist = client.artist(&artists[0].id).await.unwrap();
        let album = client.album(&albums[0].id).await.unwrap();
        let genre = client.genre(&genres[0].id).await.unwrap();
        let home = client.home().await.unwrap();
        println!(
            "search {}, artist {} with {} albums, album {} tracks, genre {} shelves, home {}",
            found.len(),
            artist.top_tracks.len(),
            artist.albums.len(),
            album.tracks.len(),
            genre.sections.len(),
            home.sections.len()
        );
        let ids: Vec<String> = tracks.iter().filter_map(|track| track.id.clone()).collect();
        let (first, second) = (ids[0].clone(), ids[1].clone());
        for transcode in [
            Transcode::default(),
            Transcode {
                codec: Some(Codec::Opus),
                bitrate: Some(96),
            },
        ] {
            let mut response = client.open_stream(&first, transcode).await.unwrap();
            let chunk = response.chunk().await.unwrap().unwrap();
            println!(
                "streams {:?}, first bytes {:02x?}",
                response.headers().get("content-type"),
                &chunk[..4]
            );
        }
        println!("details: {:?}", client.details(&first).await);

        client.set_track_saved(&first, true).await.unwrap();
        client.set_album_saved(&albums[0].id, true).await.unwrap();
        client.set_artist_saved(&artists[0].id, true).await.unwrap();
        let liked = client.saved_tracks().await.unwrap().len()
            + client.saved_albums().await.unwrap().len()
            + client.saved_artists().await.unwrap().len();
        client.set_track_saved(&first, false).await.unwrap();
        client.set_album_saved(&albums[0].id, false).await.unwrap();
        client
            .set_artist_saved(&artists[0].id, false)
            .await
            .unwrap();
        let unliked = client.saved_tracks().await.unwrap().len();
        println!("likes: {liked} then {unliked} tracks");

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
            if let Some(found) = client.server_lyrics(id).await.unwrap() {
                lyrics.push(found);
            }
        }
        println!(
            "lyrics: {} tracks have some, synced {}",
            lyrics.len(),
            lyrics
                .iter()
                .filter(|l| matches!(l, Lyrics::Synced { .. }))
                .count()
        );

        let before = client.track_playcount(&second).await.unwrap().unwrap_or(0);
        client.played(&second, SystemTime::now()).await.unwrap();
        let after = client.track_playcount(&second).await.unwrap().unwrap_or(0);
        println!("plays: {before} then {after}");

        std::thread::spawn(move || logout(&credentials))
            .join()
            .unwrap();
        assert!(!found.is_empty() && !album.tracks.is_empty() && !artist.albums.is_empty());
        assert!(liked >= 3 && owned && gone);
        assert_eq!(left, [first, second.clone()]);
        assert_eq!(detail.playlist.name, "cauce-live-check renamed");
        assert!(!lyrics.is_empty());
        assert!(after > before);
    }
}
