//! The Audius API as a [`MusicApi`]: an open catalog read with no account. Likes live on the
//! phone, and nothing is ever written to Audius.

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use anyhow::{Context as _, Result};
use async_trait::async_trait;
use serde::de::DeserializeOwned;

use super::likes::Likes;
use super::wire::{self, APP_NAME, Collection, Data, User, WireGenre, WireTrack};
use crate::{
    Album, AlbumDetail, Artist, ArtistProfile, GenreDetail, GenreItem, GenreSection, HomeFeed,
    MediaKind, MusicApi, Playlist, PlaylistDetail, SavedArtist, Throttled, Track, UserProfile,
};

/// How long one request may take.
const PATIENCE: Duration = Duration::from_secs(20);
/// How many tracks a shelf, a search or an artist's top list asks for.
const PAGE: &str = "30";

/// Editing a playlist or liking on Audius takes an Audius account, which Cauce does not hold.
const READ_ONLY: &str = "audius playlists are only edited on audius.co";

#[derive(Clone)]
pub struct AudiusClient {
    http: reqwest::Client,
    host: Arc<str>,
    /// Where the likes are kept.
    folder: PathBuf,
    likes: Arc<Mutex<Likes>>,
    /// The audius.co page of each track, artist and collection read so far, by id, which is
    /// how a link back to Audius is made without asking again.
    permalinks: Arc<Mutex<HashMap<String, String>>>,
}

fn lock<T>(mutex: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    mutex
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

impl AudiusClient {
    pub fn new(host: String, folder: PathBuf) -> Self {
        let likes = Likes::load(&folder);
        Self {
            http: reqwest::Client::builder()
                .user_agent(crate::radio::AGENT)
                .timeout(PATIENCE)
                .build()
                .unwrap_or_default(),
            host: host.into(),
            folder,
            likes: Arc::new(Mutex::new(likes)),
            permalinks: Arc::default(),
        }
    }

    pub(crate) fn host(&self) -> &str {
        &self.host
    }

    async fn get<T: DeserializeOwned>(&self, path: &str, query: &[(&str, &str)]) -> Result<T> {
        let response = self
            .http
            .get(format!("{}/v1{path}", self.host))
            .query(&[("app_name", APP_NAME)])
            .query(query)
            .send()
            .await
            .map_err(reqwest::Error::without_url)
            .context("cannot reach audius")?;
        let status = response.status();
        if status == reqwest::StatusCode::TOO_MANY_REQUESTS {
            return Err(anyhow::Error::new(Throttled)).context("audius is limiting requests");
        }
        if !status.is_success() {
            anyhow::bail!("audius answered with status {status}");
        }
        let body: Data<T> = response
            .json()
            .await
            .map_err(reqwest::Error::without_url)
            .context("audius sent an answer that does not read")?;
        Ok(body.data)
    }

    fn remember(&self, id: &str, permalink: Option<&str>) {
        if let Some(permalink) = permalink {
            lock(&self.permalinks).insert(id.to_owned(), permalink.to_owned());
        }
    }

    fn tracks_of(&self, items: Vec<WireTrack>) -> Vec<Track> {
        for item in &items {
            self.remember(&item.id, item.permalink.as_deref());
            self.remember(&item.user.id, Some(&item.user.permalink()));
        }
        wire::tracks(items)
    }

    fn collections_of(&self, items: Vec<Collection>) -> (Vec<Album>, Vec<Playlist>) {
        for item in &items {
            self.remember(&item.id, item.permalink.as_deref());
        }
        wire::collections(items)
    }

    async fn track_list(&self, path: &str, query: &[(&str, &str)]) -> Result<Vec<Track>> {
        Ok(self.tracks_of(self.get(path, query).await?))
    }

    async fn user_of(&self, id: &str) -> Result<User> {
        let user: User = self.get(&format!("/users/{}", escape(id)), &[]).await?;
        if !user.listed() {
            anyhow::bail!("that audius artist is gone");
        }
        self.remember(&user.id, Some(&user.permalink()));
        Ok(user)
    }

    async fn collection(&self, id: &str) -> Result<(Collection, Vec<Track>)> {
        let id = escape(id);
        let (one, its_tracks) = (
            format!("/playlists/{id}"),
            format!("/playlists/{id}/tracks"),
        );
        let (found, tracks) = tokio::join!(
            self.get::<Vec<Collection>>(&one, &[]),
            self.track_list(&its_tracks, &[])
        );
        let found = found?
            .into_iter()
            .find(Collection::listed)
            .context("that audius playlist is gone")?;
        self.remember(&found.id, found.permalink.as_deref());
        Ok((found, tracks?))
    }

    async fn search_collections(&self, query: &str) -> Result<(Vec<Album>, Vec<Playlist>)> {
        let found = self
            .get("/playlists/search", &[("query", query), ("limit", PAGE)])
            .await?;
        Ok(self.collections_of(found))
    }

    fn save_likes(&self, change: impl FnOnce(&mut Likes)) -> Result<()> {
        let mut likes = lock(&self.likes);
        change(&mut likes);
        likes.save(&self.folder)
    }
}

/// An id as one segment of a path.
fn escape(id: &str) -> String {
    percent_encoding::utf8_percent_encode(id, percent_encoding::NON_ALPHANUMERIC).to_string()
}

fn shelf(title: &str, items: Vec<GenreItem>) -> Option<GenreSection> {
    (!items.is_empty()).then(|| GenreSection {
        title: title.to_owned(),
        items,
    })
}

fn track_items(tracks: Vec<Track>) -> Vec<GenreItem> {
    tracks.into_iter().map(GenreItem::Track).collect()
}

#[async_trait]
impl MusicApi for AudiusClient {
    fn share_url(&self, _kind: MediaKind, id: &str) -> Option<String> {
        wire::web_url(lock(&self.permalinks).get(id)?)
    }

    async fn profile(&self) -> Result<UserProfile> {
        Ok(UserProfile {
            id: "audius".to_owned(),
            display_name: "Audius".to_owned(),
            avatar: None,
        })
    }

    async fn artist(&self, artist_id: &str) -> Result<Artist> {
        let id = escape(artist_id);
        let (its_tracks, its_albums) =
            (format!("/users/{id}/tracks"), format!("/users/{id}/albums"));
        let popular = [
            ("sort_method", "plays"),
            ("sort_direction", "desc"),
            ("limit", "20"),
        ];
        let (user, top, albums) = tokio::join!(
            self.user_of(artist_id),
            self.track_list(&its_tracks, &popular),
            self.get::<Vec<Collection>>(&its_albums, &[("limit", "50")])
        );
        let user = user?;
        Ok(Artist {
            name: user.artist().name,
            cover_large: user.picture_large(),
            biography: user.bio.clone().filter(|bio| !bio.trim().is_empty()),
            monthly_listeners: None,
            top_tracks: top?,
            albums: self.collections_of(albums.unwrap_or_default()).0,
        })
    }

    async fn artist_profile(&self, artist_id: &str) -> Result<ArtistProfile> {
        let user = self.user_of(artist_id).await?;
        Ok(ArtistProfile {
            name: user.artist().name,
            cover_large: user.picture_large(),
            biography: user.bio.clone().filter(|bio| !bio.trim().is_empty()),
        })
    }

    async fn artist_images(&self, ids: Vec<String>) -> Result<HashMap<String, String>> {
        if ids.is_empty() {
            return Ok(HashMap::new());
        }
        let query: Vec<(&str, &str)> = ids.iter().map(|id| ("id", id.as_str())).collect();
        let users: Vec<User> = self.get("/users", &query).await?;
        Ok(users
            .into_iter()
            .filter_map(|user| Some((user.id.clone(), user.picture()?)))
            .collect())
    }

    async fn saved_tracks(&self) -> Result<Vec<Track>> {
        Ok(lock(&self.likes).tracks.clone())
    }

    async fn set_track_saved(&self, track_id: &str, saved: bool) -> Result<()> {
        let track = match saved {
            true => Some(self.track(track_id).await?),
            false => None,
        };
        self.save_likes(|likes| likes.track(track_id, track))
    }

    async fn track(&self, track_id: &str) -> Result<Track> {
        let item: WireTrack = self
            .get(&format!("/tracks/{}", escape(track_id)), &[])
            .await?;
        self.tracks_of(vec![item])
            .pop()
            .context("that audius track is gone")
    }

    async fn track_playcount(&self, track_id: &str) -> Result<Option<u64>> {
        Ok(self.track(track_id).await?.playcount)
    }

    async fn playlists(&self) -> Result<Vec<Playlist>> {
        Ok(lock(&self.likes).playlists.clone())
    }

    async fn create_playlist(&self, _name: &str) -> Result<String> {
        anyhow::bail!(READ_ONLY)
    }

    async fn rename_playlist(&self, _playlist_id: &str, _name: &str) -> Result<()> {
        anyhow::bail!(READ_ONLY)
    }

    async fn delete_playlist(&self, _playlist_id: &str) -> Result<()> {
        anyhow::bail!(READ_ONLY)
    }

    async fn remove_playlist_from_library(&self, playlist_id: &str) -> Result<()> {
        self.save_likes(|likes| likes.playlist(playlist_id, None))
    }

    async fn add_playlist_to_library(&self, playlist_id: &str) -> Result<()> {
        let (found, _) = self.collection(playlist_id).await?;
        self.save_likes(|likes| likes.playlist(playlist_id, Some(found.playlist())))
    }

    async fn set_playlist_public(&self, _playlist_id: &str, _public: bool) -> Result<()> {
        anyhow::bail!(READ_ONLY)
    }

    async fn add_track_to_playlist(&self, _playlist_id: &str, _track_id: &str) -> Result<()> {
        anyhow::bail!(READ_ONLY)
    }

    async fn remove_track_from_playlist(
        &self,
        _playlist_id: &str,
        _track_id: &str,
        _copy: usize,
    ) -> Result<()> {
        anyhow::bail!(READ_ONLY)
    }

    async fn saved_albums(&self) -> Result<Vec<Album>> {
        Ok(lock(&self.likes).albums.clone())
    }

    async fn set_album_saved(&self, album_id: &str, saved: bool) -> Result<()> {
        let album = match saved {
            true => Some(self.collection(album_id).await?.0.album()),
            false => None,
        };
        self.save_likes(|likes| likes.album(album_id, album))
    }

    async fn saved_artists(&self) -> Result<Vec<SavedArtist>> {
        Ok(lock(&self.likes).artists.clone())
    }

    async fn set_artist_saved(&self, artist_id: &str, saved: bool) -> Result<()> {
        let artist = match saved {
            true => Some(self.user_of(artist_id).await?.artist()),
            false => None,
        };
        self.save_likes(|likes| likes.artist(artist_id, artist))
    }

    async fn album(&self, album_id: &str) -> Result<AlbumDetail> {
        let (found, tracks) = self.collection(album_id).await?;
        let mut album = found.album();
        album.track_count = tracks.len() as u32;
        Ok(AlbumDetail { album, tracks })
    }

    async fn album_tracks(&self, album_id: &str) -> Result<Vec<Track>> {
        Ok(self.collection(album_id).await?.1)
    }

    async fn playlist(&self, playlist_id: &str) -> Result<PlaylistDetail> {
        let (found, tracks) = self.collection(playlist_id).await?;
        Ok(PlaylistDetail {
            playlist: found.playlist(),
            tracks,
            continuation: None,
        })
    }

    async fn playlist_tracks(&self, playlist_id: &str) -> Result<Vec<Track>> {
        Ok(self.collection(playlist_id).await?.1)
    }

    async fn playlist_covers(&self, playlist_id: &str, wanted: usize) -> Result<Vec<String>> {
        Ok(crate::distinct_covers(
            &self.playlist_tracks(playlist_id).await?,
            wanted,
        ))
    }

    /// Audius has no stations.
    async fn track_radio(
        &self,
        _track_id: &str,
        _from: Option<&str>,
    ) -> Result<(Vec<Track>, Option<String>)> {
        Ok((Vec::new(), None))
    }

    async fn search(&self, query: &str) -> Result<Vec<Track>> {
        self.track_list("/tracks/search", &[("query", query), ("limit", PAGE)])
            .await
    }

    async fn search_albums(&self, query: &str) -> Result<Vec<Album>> {
        Ok(self.search_collections(query).await?.0)
    }

    async fn search_playlists(&self, query: &str) -> Result<Vec<Playlist>> {
        Ok(self.search_collections(query).await?.1)
    }

    /// Trending this week, the underground's trending and the trending playlists and albums. A
    /// shelf that fails is left out, unless they all do.
    async fn home(&self) -> Result<HomeFeed> {
        let (trending, underground, playlists, albums) = tokio::join!(
            self.track_list("/tracks/trending", &[("time", "week"), ("limit", PAGE)]),
            self.track_list("/tracks/trending/underground", &[("limit", PAGE)]),
            self.get::<Vec<Collection>>(
                "/playlists/trending",
                &[
                    ("time", "week"),
                    ("type", "playlist"),
                    ("omit_tracks", "true"),
                    ("limit", "20")
                ]
            ),
            self.get::<Vec<Collection>>(
                "/playlists/trending",
                &[
                    ("time", "week"),
                    ("type", "album"),
                    ("omit_tracks", "true"),
                    ("limit", "20")
                ]
            ),
        );
        if let (Err(error), Err(_), Err(_), Err(_)) = (&trending, &underground, &playlists, &albums)
        {
            anyhow::bail!("{error:#}");
        }
        let playlists = self.collections_of(playlists.unwrap_or_default()).1;
        let albums = self.collections_of(albums.unwrap_or_default()).0;
        let sections = [
            shelf(
                "Trending this week",
                track_items(trending.unwrap_or_default()),
            ),
            shelf(
                "Underground trending",
                track_items(underground.unwrap_or_default()),
            ),
            shelf(
                "Trending playlists",
                playlists.into_iter().map(GenreItem::Playlist).collect(),
            ),
            shelf(
                "Trending albums",
                albums.into_iter().map(GenreItem::Album).collect(),
            ),
        ];
        Ok(HomeFeed {
            sections: sections.into_iter().flatten().collect(),
            ..HomeFeed::default()
        })
    }

    async fn genres(&self) -> Result<Vec<crate::Genre>> {
        let found: Vec<WireGenre> = self.get("/genres/popular", &[("limit", "40")]).await?;
        Ok(wire::genres(found))
    }

    /// A genre's trending tracks this week and of all time.
    async fn genre(&self, genre_id: &str) -> Result<GenreDetail> {
        let week = [("genre", genre_id), ("time", "week"), ("limit", PAGE)];
        let ever = [("genre", genre_id), ("time", "allTime"), ("limit", PAGE)];
        let (week, ever) = tokio::join!(
            self.track_list("/tracks/trending", &week),
            self.track_list("/tracks/trending", &ever),
        );
        let sections = [
            shelf("Trending this week", track_items(week?)),
            shelf("All-time trending", track_items(ever.unwrap_or_default())),
        ];
        Ok(GenreDetail {
            name: genre_id.to_owned(),
            sections: sections.into_iter().flatten().collect(),
        })
    }
}

/// Reaches the real Audius API. Run with `cargo test audius_live -- --ignored --nocapture`.
#[cfg(test)]
mod audius_live {
    use super::*;
    use crate::audius::select_host;

    #[tokio::test]
    #[ignore = "reaches api.audius.co"]
    async fn audius_live_trends_searches_and_streams_a_range() {
        let folder = tempfile::tempdir().unwrap();
        let host = select_host().await;
        println!("host {host}");
        let client = AudiusClient::new(host.clone(), folder.path().to_owned());
        let home = client.home().await.unwrap();
        for section in &home.sections {
            println!("{}: {} items", section.title, section.items.len());
        }
        let GenreItem::Track(first) = &home.sections[0].items[0] else {
            panic!("the first shelf holds tracks");
        };
        let found = client.search(&first.name).await.unwrap();
        println!("search {:?}: {} tracks", first.name, found.len());
        assert!(!found.is_empty());
        let playable = found.iter().find(|track| track.playable).unwrap();
        let id = playable.id.clone().unwrap();
        println!("share {:?}", client.share_url(MediaKind::Track, &id));
        let artist = client
            .artist(&playable.artist_refs[0].id.clone().unwrap())
            .await
            .unwrap();
        println!(
            "artist {}: {} top tracks",
            artist.name,
            artist.top_tracks.len()
        );
        let genres = client.genres().await.unwrap();
        let genre = client.genre(&genres[0].id).await.unwrap();
        println!("genre {}: {} shelves", genre.name, genre.sections.len());
        let response = client
            .http
            .get(wire::stream_url(&host, &id))
            .header("range", "bytes=1000-1999")
            .send()
            .await
            .unwrap();
        println!(
            "stream {} {:?} {:?}",
            response.status(),
            response.headers().get("content-range"),
            response.headers().get("content-type")
        );
        assert_eq!(response.status(), reqwest::StatusCode::PARTIAL_CONTENT);
        assert_eq!(response.bytes().await.unwrap().len(), 1000);
        client.set_track_saved(&id, true).await.unwrap();
        assert_eq!(
            client.saved_tracks().await.unwrap()[0].id.as_deref(),
            Some(id.as_str())
        );
    }
}
