//! What the Audius API answers, and how it becomes Cauce's models.
//!
//! Only what Cauce shows is read. A track the artist gated behind a purchase or a follow, or one
//! the API will not stream to an app without its own key, is listed as unplayable: it is never
//! fetched another way. A deleted, unlisted or withdrawn one is not listed at all.

use std::time::Duration;

use serde::Deserialize;

use crate::{Album, ArtistRef, Genre, Playlist, ReleaseType, SavedArtist, Track};

/// What Audius is told the app is called on every request. Reading needs no key.
pub(crate) const APP_NAME: &str = "Cauce";

/// The API that lists the hosts to use, and the host used when it cannot be asked.
pub(crate) const DEFAULT_HOST: &str = "https://api.audius.co";

/// Where the listener finds a track, an artist or a collection on Audius itself.
const WEB: &str = "https://audius.co";

#[derive(Deserialize)]
pub(crate) struct Data<T> {
    pub data: T,
}

/// One of the hosts `GET https://api.audius.co` lists, picked by `seed` so installs spread over
/// them. Only an https host counts; with none, the default host serves.
pub(crate) fn pick_host(hosts: &[String], seed: usize) -> String {
    let usable: Vec<&str> = hosts
        .iter()
        .map(|host| host.trim().trim_end_matches('/'))
        .filter(|host| host.starts_with("https://") && host.len() > "https://".len())
        .collect();
    match usable.len() {
        0 => DEFAULT_HOST.to_owned(),
        count => usable[seed % count].to_owned(),
    }
}

/// The audio of track `id` on `host`. The API answers it with a redirect to a content node that
/// serves the file with range requests, so it seeks.
pub(crate) fn stream_url(host: &str, id: &str) -> String {
    let id = percent_encoding::utf8_percent_encode(id, percent_encoding::NON_ALPHANUMERIC);
    format!("{host}/v1/tracks/{id}/stream?app_name={APP_NAME}")
}

/// The page on audius.co for a `permalink` such as `/artist/track`.
pub(crate) fn web_url(permalink: &str) -> Option<String> {
    permalink
        .starts_with('/')
        .then(|| format!("{WEB}{permalink}"))
}

/// The sizes Audius renders an image at. Every size is a public url.
#[derive(Clone, Default, Deserialize)]
pub(crate) struct Artwork {
    #[serde(rename = "480x480")]
    medium: Option<String>,
    #[serde(rename = "1000x1000")]
    large: Option<String>,
}

#[derive(Default, Deserialize)]
struct Access {
    #[serde(default)]
    stream: bool,
}

#[derive(Clone, Deserialize)]
pub(crate) struct User {
    pub id: String,
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub handle: String,
    pub bio: Option<String>,
    pub profile_picture: Option<Artwork>,
    #[serde(default)]
    is_deactivated: bool,
    is_available: Option<bool>,
}

impl User {
    /// Whether the account is still there to show.
    pub fn listed(&self) -> bool {
        !self.is_deactivated && self.is_available != Some(false)
    }

    pub fn permalink(&self) -> String {
        format!("/{}", self.handle)
    }

    fn name(&self) -> String {
        match self.name.trim() {
            "" => self.handle.clone(),
            name => name.to_owned(),
        }
    }

    fn reference(&self) -> ArtistRef {
        ArtistRef {
            name: self.name(),
            id: Some(self.id.clone()),
        }
    }

    pub fn picture(&self) -> Option<String> {
        self.profile_picture.as_ref()?.medium.clone()
    }

    pub fn picture_large(&self) -> Option<String> {
        let picture = self.profile_picture.as_ref()?;
        picture.large.clone().or_else(|| picture.medium.clone())
    }

    pub fn artist(&self) -> SavedArtist {
        SavedArtist {
            id: self.id.clone(),
            name: self.name(),
            cover: self.picture(),
            added_at: None,
        }
    }
}

#[derive(Deserialize)]
pub(crate) struct WireTrack {
    pub id: String,
    #[serde(default)]
    title: String,
    #[serde(default)]
    duration: u64,
    pub permalink: Option<String>,
    pub play_count: Option<u64>,
    is_streamable: Option<bool>,
    #[serde(default)]
    is_stream_gated: bool,
    #[serde(default)]
    is_delete: bool,
    #[serde(default)]
    is_unlisted: bool,
    is_available: Option<bool>,
    access: Option<Access>,
    allowed_api_keys: Option<Vec<String>>,
    artwork: Option<Artwork>,
    pub user: User,
}

impl WireTrack {
    /// Whether the track is there to list at all.
    pub fn listed(&self) -> bool {
        !self.is_delete && !self.is_unlisted && self.is_available != Some(false)
    }

    /// Whether anyone may stream it without paying, following or an app key of its own. The
    /// API says so in `access`, worked out for a listener with no account.
    pub fn streamable(&self) -> bool {
        !self.is_stream_gated
            && self.access.as_ref().is_some_and(|access| access.stream)
            && self.is_streamable != Some(false)
            && self.allowed_api_keys.as_ref().is_none_or(Vec::is_empty)
    }

    pub fn track(self) -> Track {
        let playable = self.streamable();
        let artwork = self.artwork.unwrap_or_default();
        Track {
            id: Some(self.id),
            name: self.title,
            playable,
            artists: self.user.name(),
            artist_refs: vec![self.user.reference()],
            album: String::new(),
            album_id: None,
            cover: artwork.medium.or(artwork.large),
            duration: Duration::from_secs(self.duration),
            added_at: None,
            added_by: None,
            playcount: self.play_count,
            popularity: 0,
            explicit: false,
            track_number: 0,
            disc_number: 1,
            tags: Vec::new(),
            languages: Vec::new(),
            credits: Vec::new(),
        }
    }
}

/// The tracks worth listing, in order, the gated ones unplayable.
pub(crate) fn tracks(items: Vec<WireTrack>) -> Vec<Track> {
    items
        .into_iter()
        .filter(WireTrack::listed)
        .map(WireTrack::track)
        .collect()
}

/// A playlist or an album: Audius keeps both as playlists and tells them apart by `is_album`.
#[derive(Deserialize)]
pub(crate) struct Collection {
    pub id: String,
    #[serde(default)]
    playlist_name: String,
    #[serde(default)]
    pub is_album: bool,
    #[serde(default)]
    is_private: bool,
    #[serde(default)]
    is_delete: bool,
    artwork: Option<Artwork>,
    #[serde(default)]
    track_count: u32,
    pub permalink: Option<String>,
    release_date: Option<String>,
    pub user: User,
}

impl Collection {
    pub fn listed(&self) -> bool {
        !self.is_private && !self.is_delete
    }

    pub fn album(self) -> Album {
        let artwork = self.artwork.unwrap_or_default();
        let date = self
            .release_date
            .as_deref()
            .and_then(|date| date.get(..10))
            .unwrap_or_default()
            .to_owned();
        Album {
            id: self.id,
            name: self.playlist_name,
            artists: self.user.name(),
            artist_refs: vec![self.user.reference()],
            cover: artwork.medium.clone().or(artwork.large.clone()),
            cover_large: artwork.large.or(artwork.medium),
            release_type: ReleaseType::Album,
            year: date
                .get(..4)
                .and_then(|year| year.parse().ok())
                .unwrap_or(0),
            track_count: self.track_count,
            release_date: date,
            label: String::new(),
            copyrights: vec![format!("© {}", self.user.name())],
            added_at: None,
        }
    }

    pub fn playlist(self) -> Playlist {
        let artwork = self.artwork.unwrap_or_default();
        Playlist {
            id: self.id,
            name: self.playlist_name,
            owner: self.user.name(),
            owner_id: self.user.id.clone(),
            owned: false,
            collaborative: false,
            blend: false,
            public: true,
            cover: artwork.medium.or(artwork.large),
            track_count: self.track_count,
            modified_at: None,
        }
    }
}

/// The listed collections, albums apart from playlists, each in order.
pub(crate) fn collections(items: Vec<Collection>) -> (Vec<Album>, Vec<Playlist>) {
    let mut albums = Vec::new();
    let mut playlists = Vec::new();
    for item in items.into_iter().filter(Collection::listed) {
        match item.is_album {
            true => albums.push(item.album()),
            false => playlists.push(item.playlist()),
        }
    }
    (albums, playlists)
}

#[derive(Deserialize)]
pub(crate) struct WireGenre {
    name: String,
}

/// A genre is known by its name, which is what trending filters by.
pub(crate) fn genres(items: Vec<WireGenre>) -> Vec<Genre> {
    items
        .into_iter()
        .filter(|genre| !genre.name.trim().is_empty())
        .map(|genre| Genre {
            id: genre.name.clone(),
            name: genre.name,
            cover: None,
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture<T: serde::de::DeserializeOwned>(json: &str) -> T {
        serde_json::from_str::<Data<T>>(json).unwrap().data
    }

    fn sample_tracks() -> Vec<WireTrack> {
        fixture(include_str!("fixtures/tracks.json"))
    }

    #[test]
    fn a_host_is_one_of_the_listed_https_hosts() {
        let hosts: Vec<String> = fixture(include_str!("fixtures/hosts.json"));
        assert_eq!(pick_host(&hosts, 7), "https://api.audius.co");
        let hosts = vec![
            "http://plain.example.com".to_owned(),
            "https://a.example.com/".to_owned(),
            "https://b.example.com".to_owned(),
        ];
        assert_eq!(pick_host(&hosts, 0), "https://a.example.com");
        assert_eq!(pick_host(&hosts, 1), "https://b.example.com");
        assert_eq!(pick_host(&hosts, 2), "https://a.example.com");
    }

    #[test]
    fn with_no_usable_host_the_default_serves() {
        assert_eq!(pick_host(&[], 3), DEFAULT_HOST);
        assert_eq!(
            pick_host(&["http://x.example.com".to_owned()], 0),
            DEFAULT_HOST
        );
        assert_eq!(pick_host(&["https://".to_owned()], 0), DEFAULT_HOST);
    }

    #[test]
    fn a_stream_is_asked_for_by_id_and_names_the_app() {
        assert_eq!(
            stream_url("https://api.audius.co", "mzXmz1"),
            "https://api.audius.co/v1/tracks/mzXmz1/stream?app_name=Cauce"
        );
        assert_eq!(
            stream_url("https://api.audius.co", "a/b?c"),
            "https://api.audius.co/v1/tracks/a%2Fb%3Fc/stream?app_name=Cauce"
        );
    }

    #[test]
    fn a_web_link_needs_a_permalink() {
        assert_eq!(
            web_url("/ciaragraves/on-the-floor").as_deref(),
            Some("https://audius.co/ciaragraves/on-the-floor")
        );
        assert_eq!(web_url("https://evil.example.com"), None);
        assert_eq!(web_url(""), None);
    }

    #[test]
    fn a_free_track_reads_with_its_artist_and_cover() {
        let track = sample_tracks().remove(0).track();
        assert_eq!(track.id.as_deref(), Some("mzXmz1"));
        assert_eq!(track.name, "On The Floor");
        assert!(track.playable);
        assert_eq!(track.artists, "Ciara Graves");
        assert_eq!(track.artist_refs[0].id.as_deref(), Some("aWvp71"));
        assert_eq!(track.duration, Duration::from_secs(180));
        assert!(track.cover.unwrap().ends_with("/480x480.jpg"));
    }

    #[test]
    fn a_purchase_gated_track_is_listed_but_never_playable() {
        let tracks = tracks(sample_tracks());
        assert_eq!(tracks.len(), 3);
        let gated = tracks
            .iter()
            .find(|track| track.id.as_deref() == Some("722A8Bv"))
            .unwrap();
        assert!(!gated.playable);
    }

    #[test]
    fn a_track_streams_only_when_access_allows_it_without_a_key() {
        let free = || sample_tracks().remove(0);
        assert!(free().streamable());
        let mut gated = free();
        gated.is_stream_gated = true;
        assert!(!gated.streamable());
        let mut no_access = free();
        no_access.access = None;
        assert!(!no_access.streamable());
        let mut keyed = free();
        keyed.allowed_api_keys = Some(vec!["0xabc".to_owned()]);
        assert!(!keyed.streamable());
        let mut open_list = free();
        open_list.allowed_api_keys = Some(Vec::new());
        assert!(open_list.streamable());
        let mut not_streamable = free();
        not_streamable.is_streamable = Some(false);
        assert!(!not_streamable.streamable());
    }

    #[test]
    fn deleted_unlisted_and_withdrawn_tracks_are_left_out() {
        let mut items = sample_tracks();
        items[0].is_delete = true;
        items[1].is_unlisted = true;
        items[2].is_available = Some(false);
        assert!(tracks(items).is_empty());
    }

    #[test]
    fn collections_split_into_albums_and_playlists_with_the_artist_credited() {
        let mut items: Vec<Collection> = fixture(include_str!("fixtures/playlists.json"));
        items[1].is_album = true;
        let (albums, playlists) = collections(items);
        assert_eq!(playlists.len(), 1);
        assert_eq!(playlists[0].id, "M2Qd5Eo");
        assert_eq!(playlists[0].name, "Flight of The Butterfly");
        assert_eq!(playlists[0].owner_id, "bQ3Kk");
        assert_eq!(playlists[0].track_count, 15);
        assert!(!playlists[0].owned);
        assert_eq!(albums.len(), 1);
        assert_eq!(
            albums[0].copyrights,
            vec![format!("© {}", albums[0].artists)]
        );
        assert!(
            albums[0]
                .cover_large
                .as_deref()
                .unwrap()
                .ends_with("/1000x1000.jpg")
        );
    }

    #[test]
    fn private_and_deleted_collections_are_left_out() {
        let mut items: Vec<Collection> = fixture(include_str!("fixtures/playlists.json"));
        items[0].is_private = true;
        items[1].is_delete = true;
        let (albums, playlists) = collections(items);
        assert!(albums.is_empty() && playlists.is_empty());
    }

    #[test]
    fn an_artist_reads_with_picture_and_link() {
        let user: User = fixture(include_str!("fixtures/user.json"));
        assert!(user.listed());
        let artist = user.artist();
        assert_eq!(artist.id, "aWvp71");
        assert_eq!(artist.name, "Ciara Graves");
        assert!(artist.cover.unwrap().ends_with("/480x480.jpg"));
        assert_eq!(user.permalink(), "/ciaragraves");
    }

    #[test]
    fn genres_are_known_by_name() {
        let genres = genres(fixture(include_str!("fixtures/genres.json")));
        assert_eq!(genres[0].id, "Electronic");
        assert_eq!(genres[1].name, "Hip-Hop/Rap");
        assert_eq!(genres.len(), 5);
    }
}
