//! What a Plex Media Server and plex.tv answer with, and how it becomes the app's models.

use serde::{Deserialize, Deserializer};

use crate::engine::Loudness;
use crate::escape;
use crate::{Album, ArtistRef, Codec, Genre, Playlist, ReleaseType, SavedArtist, Track, Transcode};

const COVER: u32 = 300;
const COVER_LARGE: u32 = 600;
/// The rating Plex keeps for five stars, out of ten. A liked item is one rated that, as the
/// thumbs up of Plexamp sets it.
pub const LIKED: f32 = 10.0;
/// What the engine decodes as it comes, so the server sends these files untouched.
const DIRECT: &[&str] = &[
    "mp3", "flac", "aac", "m4a", "mp4", "alac", "ogg", "oga", "opus", "webm", "wav", "aiff",
];
/// Plex's stream type for lyrics.
const LYRICS: u32 = 4;

/// Every answer of the server comes wrapped in a `MediaContainer`.
#[derive(Default, Deserialize)]
#[serde(default)]
pub struct Answer {
    #[serde(rename = "MediaContainer")]
    pub container: Container,
}

#[derive(Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Container {
    pub total_size: Option<usize>,
    #[serde(rename = "Metadata")]
    pub metadata: Vec<Metadata>,
    #[serde(rename = "Directory")]
    pub directory: Vec<Directory>,
    #[serde(rename = "Hub")]
    pub hub: Vec<Hub>,
}

/// One track, album, artist or playlist. Plex leaves out whatever it has nothing for.
#[derive(Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Metadata {
    #[serde(deserialize_with = "text")]
    pub rating_key: String,
    #[serde(rename = "type")]
    pub kind: Option<String>,
    pub title: Option<String>,
    pub parent_title: Option<String>,
    #[serde(deserialize_with = "maybe_text")]
    pub parent_rating_key: Option<String>,
    pub grandparent_title: Option<String>,
    #[serde(deserialize_with = "maybe_text")]
    pub grandparent_rating_key: Option<String>,
    /// The track's own artist, when it is not the album's.
    pub original_title: Option<String>,
    pub index: Option<u32>,
    pub parent_index: Option<u32>,
    /// In milliseconds.
    pub duration: Option<u64>,
    pub thumb: Option<String>,
    pub parent_thumb: Option<String>,
    /// A playlist's picture, made of its tracks' covers.
    pub composite: Option<String>,
    pub year: Option<i32>,
    pub added_at: Option<i64>,
    /// Out of ten, half a star a point.
    pub user_rating: Option<f32>,
    pub view_count: Option<u64>,
    pub leaf_count: Option<u32>,
    pub summary: Option<String>,
    pub smart: Option<bool>,
    pub playlist_type: Option<String>,
    /// Which entry of a playlist this is, from `/playlists/{id}/items`.
    #[serde(rename = "playlistItemID", deserialize_with = "maybe_text")]
    pub playlist_item_id: Option<String>,
    #[serde(rename = "Media")]
    pub media: Vec<Media>,
}

#[derive(Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Media {
    /// In kilobits per second.
    pub bitrate: Option<u32>,
    pub audio_codec: Option<String>,
    pub container: Option<String>,
    #[serde(rename = "Part")]
    pub part: Vec<Part>,
}

#[derive(Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Part {
    pub key: Option<String>,
    pub container: Option<String>,
    #[serde(rename = "Stream")]
    pub stream: Vec<Stream>,
}

#[derive(Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Stream {
    pub stream_type: Option<u32>,
    pub key: Option<String>,
    pub codec: Option<String>,
    pub format: Option<String>,
    /// The ReplayGain track gain in dB, once the server has analysed the loudness.
    pub gain: Option<f32>,
    pub peak: Option<f32>,
}

/// A library section or a genre.
#[derive(Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Directory {
    #[serde(deserialize_with = "text")]
    pub key: String,
    #[serde(rename = "type")]
    pub kind: Option<String>,
    pub title: Option<String>,
}

/// One kind of result of `/hubs/search`.
#[derive(Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Hub {
    #[serde(rename = "type")]
    pub kind: Option<String>,
    #[serde(rename = "Metadata")]
    pub metadata: Vec<Metadata>,
}

/// Plex sends some ids as numbers and others as text, and not always the same way.
fn maybe_text<'de, D: Deserializer<'de>>(deserializer: D) -> Result<Option<String>, D::Error> {
    Ok(
        match Option::<serde_json::Value>::deserialize(deserializer)? {
            Some(serde_json::Value::String(text)) => Some(text),
            Some(serde_json::Value::Number(number)) => Some(number.to_string()),
            _ => None,
        },
    )
}

fn text<'de, D: Deserializer<'de>>(deserializer: D) -> Result<String, D::Error> {
    Ok(maybe_text(deserializer)?.unwrap_or_default())
}

/// Where pictures come from. Plex serves none without the token, and an image widget sends no
/// headers, so a cover url carries it, as Subsonic's do.
pub struct Art<'a> {
    pub server: &'a str,
    pub token: &'a str,
}

impl Art<'_> {
    /// `thumb`, a path on the server, scaled down to `size` by the server.
    pub fn cover(&self, thumb: Option<&str>, size: u32) -> Option<String> {
        let thumb = thumb.filter(|thumb| !thumb.is_empty())?;
        Some(format!(
            "{}/photo/:/transcode?width={size}&height={size}&minSize=1&upscale=1&url={}&X-Plex-Token={}",
            self.server,
            escape::component(thumb),
            escape::component(self.token)
        ))
    }
}

fn some(text: &Option<String>) -> Option<String> {
    text.clone().filter(|text| !text.is_empty())
}

pub fn liked(item: &Metadata) -> bool {
    item.user_rating.is_some_and(|rating| rating >= LIKED)
}

pub fn track(item: Metadata, art: &Art) -> Track {
    let cover = art
        .cover(item.thumb.as_deref(), COVER)
        .or_else(|| art.cover(item.parent_thumb.as_deref(), COVER));
    let album_artist = some(&item.grandparent_title);
    let (artists, artist_refs) = match some(&item.original_title) {
        Some(own) if Some(&own) != album_artist.as_ref() => (
            own.clone(),
            vec![ArtistRef {
                name: own,
                id: None,
            }],
        ),
        _ => (
            album_artist.clone().unwrap_or_default(),
            album_artist
                .map(|name| ArtistRef {
                    name,
                    id: some(&item.grandparent_rating_key),
                })
                .into_iter()
                .collect(),
        ),
    };
    Track {
        id: Some(item.rating_key),
        name: item.title.unwrap_or_default(),
        playable: true,
        artists,
        artist_refs,
        album: item.parent_title.unwrap_or_default(),
        album_id: item.parent_rating_key.filter(|id| !id.is_empty()),
        cover,
        duration: std::time::Duration::from_millis(item.duration.unwrap_or(0)),
        added_at: item.added_at,
        added_by: None,
        playcount: item.view_count,
        popularity: 0,
        explicit: false,
        track_number: item.index.unwrap_or(0),
        disc_number: item.parent_index.unwrap_or(1).max(1),
        tags: Vec::new(),
        languages: Vec::new(),
        credits: Vec::new(),
    }
}

pub fn album(item: Metadata, art: &Art) -> Album {
    let artist = some(&item.parent_title);
    let year = item.year.unwrap_or(0);
    Album {
        cover: art.cover(item.thumb.as_deref(), COVER),
        cover_large: art.cover(item.thumb.as_deref(), COVER_LARGE),
        id: item.rating_key,
        name: item.title.unwrap_or_default(),
        artists: artist.clone().unwrap_or_default(),
        artist_refs: artist
            .map(|name| ArtistRef {
                name,
                id: item.parent_rating_key.filter(|id| !id.is_empty()),
            })
            .into_iter()
            .collect(),
        release_type: ReleaseType::Album,
        year,
        track_count: item.leaf_count.unwrap_or(0),
        release_date: match year {
            0 => String::new(),
            _ => year.to_string(),
        },
        label: String::new(),
        copyrights: Vec::new(),
        added_at: item.added_at,
    }
}

pub fn artist(item: &Metadata, art: &Art) -> SavedArtist {
    SavedArtist {
        id: item.rating_key.clone(),
        name: item.title.clone().unwrap_or_default(),
        cover: art.cover(item.thumb.as_deref(), COVER_LARGE),
        added_at: item.added_at,
    }
}

/// A playlist of the listener's: Plex keeps each account's playlists to itself. A smart one is
/// filled by its rules, so its tracks cannot be edited and it does not count as theirs to change.
pub fn playlist(item: Metadata, art: &Art) -> Playlist {
    Playlist {
        cover: art
            .cover(item.composite.as_deref(), COVER)
            .or_else(|| art.cover(item.thumb.as_deref(), COVER)),
        id: item.rating_key,
        name: item.title.unwrap_or_default(),
        owner: String::new(),
        owner_id: String::new(),
        owned: item.smart != Some(true),
        collaborative: false,
        blend: false,
        public: false,
        track_count: item.leaf_count.unwrap_or(0),
        modified_at: None,
    }
}

/// A genre of `section`. Its id names the section too, since a genre's key only means something
/// within one.
pub fn genre(section: &str, directory: Directory) -> Genre {
    Genre {
        id: format!("{section}:{}", genre_key(&directory.key)),
        name: directory.title.unwrap_or_default(),
        cover: None,
    }
}

/// A genre's own key. Older servers hand over the path that lists it instead.
fn genre_key(key: &str) -> &str {
    key.rsplit_once("genre=").map_or(key, |(_, id)| id)
}

/// The music libraries among a server's sections.
pub fn music_sections(sections: Vec<Directory>) -> Vec<String> {
    sections
        .into_iter()
        .filter(|section| section.kind.as_deref() == Some("artist"))
        .map(|section| section.key)
        .filter(|key| !key.is_empty())
        .collect()
}

fn streams(item: &Metadata) -> impl Iterator<Item = &Stream> {
    item.media
        .iter()
        .flat_map(|media| &media.part)
        .flat_map(|part| &part.stream)
}

/// The track's ReplayGain from the server's loudness analysis.
pub fn loudness(item: &Metadata) -> Option<Loudness> {
    let audio = streams(item).find(|stream| stream.gain.is_some())?;
    Some(Loudness::replay_gain(audio.gain?, audio.peak))
}

/// Where the track's lyrics are read: a `.lrc` or `.txt` beside it, or lyrics in its tags.
pub fn lyrics_key(item: &Metadata) -> Option<String> {
    streams(item)
        .filter(|stream| stream.stream_type == Some(LYRICS))
        .find(|stream| {
            let kind = stream.codec.as_deref().or(stream.format.as_deref());
            matches!(kind, Some("lrc" | "txt"))
        })
        .and_then(|stream| stream.key.clone())
        .filter(|key| key.starts_with('/'))
}

/// How a track is fetched.
#[derive(Debug, PartialEq, Eq)]
pub enum Plan {
    /// The file as it is, from this path on the server.
    Direct(String),
    /// Converted to MP3 at this many kilobits per second.
    Convert(u32),
}

/// What highest bitrate a conversion is asked for when only a codec was chosen.
const CONVERTED: u32 = 320;

/// How to fetch `item` as `transcode` asks. A file the engine decodes goes untouched unless it is
/// over the ceiling or not in the chosen codec. Plex converts music for a progressive download
/// only to MP3, so whatever codec is chosen, a conversion is MP3.
pub fn plan(item: &Metadata, transcode: Transcode) -> Option<Plan> {
    let media = item.media.first();
    let part = media.and_then(|media| media.part.first());
    let key = part
        .and_then(|part| part.key.clone())
        .filter(|key| key.starts_with('/'));
    let container = part
        .and_then(|part| part.container.clone())
        .or_else(|| media.and_then(|media| media.container.clone()))
        .unwrap_or_default()
        .to_lowercase();
    let codec = media
        .and_then(|media| media.audio_codec.clone())
        .unwrap_or_default();
    let bitrate = media.and_then(|media| media.bitrate);
    let convert = Plan::Convert(transcode.bitrate.unwrap_or(CONVERTED));
    let decodable = DIRECT.contains(&container.as_str());
    let under = match transcode.bitrate {
        None => true,
        Some(ceiling) => bitrate.is_some_and(|bitrate| bitrate <= ceiling),
    };
    let wanted = match transcode.codec {
        None => true,
        Some(Codec::Mp3) => codec.eq_ignore_ascii_case("mp3"),
        Some(Codec::Aac) => codec.eq_ignore_ascii_case("aac"),
        Some(Codec::Opus) => codec.eq_ignore_ascii_case("opus"),
    };
    match key {
        Some(key) if decodable && under && wanted => Some(Plan::Direct(key)),
        _ if !item.rating_key.is_empty() => Some(convert),
        _ => None,
    }
}

/// `/api/v2/pins`: a code waiting for the listener to approve it on plex.tv.
#[derive(Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Pin {
    pub id: u64,
    pub code: String,
    pub auth_token: Option<String>,
}

/// `/api/v2/user`: the plex.tv account a token belongs to.
#[derive(Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Account {
    #[serde(deserialize_with = "text")]
    pub id: String,
    pub username: String,
    pub title: String,
}

/// One of `/api/v2/resources`: a server or player the account can reach.
#[derive(Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Resource {
    pub name: String,
    pub client_identifier: String,
    pub provides: String,
    pub owned: bool,
    pub access_token: Option<String>,
    pub connections: Vec<Connection>,
}

#[derive(Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Connection {
    pub uri: String,
    pub local: bool,
    pub relay: bool,
}

impl Resource {
    pub fn is_server(&self) -> bool {
        self.provides.split(',').any(|role| role.trim() == "server")
    }

    /// The addresses to try, best first: on the same network, then over the internet, then
    /// through Plex's relay, which is slow and capped.
    pub fn addresses(&self) -> Vec<String> {
        let rank = |connection: &Connection| match (connection.relay, connection.local) {
            (false, true) => 0,
            (false, false) => 1,
            (true, _) => 2,
        };
        let mut connections: Vec<&Connection> = self
            .connections
            .iter()
            .filter(|connection| !connection.uri.is_empty())
            .collect();
        connections.sort_by_key(|connection| rank(connection));
        let mut addresses: Vec<String> = Vec::new();
        for connection in connections {
            let uri = connection.uri.trim_end_matches('/').to_owned();
            if !addresses.contains(&uri) {
                addresses.push(uri);
            }
        }
        addresses
    }
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use super::*;

    const ART: Art = Art {
        server: "http://192.168.1.4:32400",
        token: "tok/en",
    };

    /// A track of `/library/metadata/{id}`, trimmed, with its loudness and a sidecar `.lrc`.
    const TRACK: &str = r#"{"MediaContainer":{"size":1,"Metadata":[{
        "ratingKey":"1203","key":"/library/metadata/1203","parentRatingKey":"1202",
        "grandparentRatingKey":"1201","type":"track","title":"Tide","grandparentTitle":"Waves",
        "parentTitle":"Shore","originalTitle":"Waves","index":2,"parentIndex":1,"userRating":10.0,
        "viewCount":4,"thumb":"/library/metadata/1202/thumb/1761600000","parentThumb":"/library/metadata/1202/thumb/1761600000",
        "duration":181000,"addedAt":1761600000,
        "Media":[{"id":11,"duration":181000,"bitrate":933,"audioChannels":2,"audioCodec":"flac","container":"flac",
          "Part":[{"id":21,"key":"/library/parts/21/1761600000/file.flac","duration":181000,"file":"/music/Waves/Shore/02 Tide.flac","size":21000000,"container":"flac",
            "Stream":[
              {"id":31,"streamType":2,"selected":true,"codec":"flac","gain":-7.5,"albumGain":-7.1,"peak":0.98,"loudness":-10.5},
              {"id":32,"streamType":4,"key":"/library/streams/32","codec":"lrc","format":"lrc","provider":"com.plexapp.agents.localmedia"}
            ]}]}]}]}}"#;

    fn first(json: &str) -> Metadata {
        let answer: Answer = serde_json::from_str(json).unwrap();
        answer.container.metadata.into_iter().next().unwrap()
    }

    #[test]
    fn a_track_reads_its_album_artist_and_numbers() {
        let track = track(first(TRACK), &ART);
        assert_eq!(track.id.as_deref(), Some("1203"));
        assert_eq!(track.name, "Tide");
        assert_eq!(track.artists, "Waves");
        assert_eq!(track.artist_refs[0].id.as_deref(), Some("1201"));
        assert_eq!(track.album, "Shore");
        assert_eq!(track.album_id.as_deref(), Some("1202"));
        assert_eq!(track.duration, Duration::from_secs(181));
        assert_eq!((track.track_number, track.disc_number), (2, 1));
        assert_eq!(track.playcount, Some(4));
        assert_eq!(track.added_at, Some(1_761_600_000));
    }

    #[test]
    fn a_track_by_a_guest_names_them_without_a_link() {
        let mut item = first(TRACK);
        item.original_title = Some("Guest".into());
        let track = track(item, &ART);
        assert_eq!(track.artists, "Guest");
        assert_eq!(track.artist_refs[0].id, None);
    }

    #[test]
    fn a_cover_is_scaled_by_the_server_and_carries_the_token() {
        let track = track(first(TRACK), &ART);
        assert_eq!(
            track.cover.as_deref(),
            Some(
                "http://192.168.1.4:32400/photo/:/transcode?width=300&height=300&minSize=1&upscale=1&url=%2Flibrary%2Fmetadata%2F1202%2Fthumb%2F1761600000&X-Plex-Token=tok%2Fen"
            )
        );
        assert_eq!(ART.cover(Some(""), 300), None);
    }

    #[test]
    fn five_stars_is_a_like() {
        let mut item = first(TRACK);
        assert!(liked(&item));
        item.user_rating = Some(8.0);
        assert!(!liked(&item));
        item.user_rating = None;
        assert!(!liked(&item));
    }

    #[test]
    fn the_loudness_and_lyrics_come_from_the_streams() {
        let item = first(TRACK);
        let loudness = loudness(&item).unwrap();
        assert_eq!(loudness.peak, Some(0.98));
        assert_eq!(
            loudness.lufs,
            Loudness::replay_gain(-7.5, None).lufs,
            "the gain is ReplayGain's"
        );
        assert_eq!(lyrics_key(&item).as_deref(), Some("/library/streams/32"));
    }

    #[test]
    fn lyrics_in_a_format_other_than_lrc_or_text_are_left_alone() {
        let mut item = first(TRACK);
        item.media[0].part[0].stream[1].codec = Some("xml".into());
        item.media[0].part[0].stream[1].format = Some("xml".into());
        assert_eq!(lyrics_key(&item), None);
    }

    #[test]
    fn a_decodable_file_under_the_ceiling_plays_untouched() {
        let item = first(TRACK);
        let direct = Plan::Direct("/library/parts/21/1761600000/file.flac".into());
        assert_eq!(plan(&item, Transcode::default()), Some(direct));
    }

    #[test]
    fn over_the_ceiling_or_in_another_codec_converts_to_mp3() {
        let item = first(TRACK);
        let capped = Transcode {
            codec: None,
            bitrate: Some(320),
        };
        assert_eq!(plan(&item, capped), Some(Plan::Convert(320)));
        let mp3 = Transcode {
            codec: Some(Codec::Mp3),
            bitrate: None,
        };
        assert_eq!(plan(&item, mp3), Some(Plan::Convert(320)));
        let mut low = item.clone();
        low.media[0].bitrate = Some(128);
        assert!(matches!(plan(&low, capped), Some(Plan::Direct(_))));
    }

    #[test]
    fn a_file_the_engine_cannot_decode_is_converted() {
        let mut item = first(TRACK);
        item.media[0].container = Some("wma".into());
        item.media[0].part[0].container = Some("wma".into());
        assert_eq!(plan(&item, Transcode::default()), Some(Plan::Convert(320)));
    }

    /// An album of `/library/sections/{id}/all?type=9`, with its key as a number.
    const ALBUM: &str = r#"{"MediaContainer":{"size":1,"totalSize":40,"Metadata":[{
        "ratingKey":1202,"type":"album","title":"Shore","parentRatingKey":"1201","parentTitle":"Waves",
        "year":2024,"leafCount":9,"addedAt":1761600000,"thumb":"/library/metadata/1202/thumb/1"}]}}"#;

    #[test]
    fn an_album_reads_its_artist_year_and_size() {
        let answer: Answer = serde_json::from_str(ALBUM).unwrap();
        assert_eq!(answer.container.total_size, Some(40));
        let album = album(answer.container.metadata[0].clone(), &ART);
        assert_eq!(album.id, "1202");
        assert_eq!(album.artists, "Waves");
        assert_eq!(album.artist_refs[0].id.as_deref(), Some("1201"));
        assert_eq!((album.year, album.track_count), (2024, 9));
        assert_eq!(album.release_date, "2024");
        assert!(album.cover_large.unwrap().contains("width=600"));
    }

    #[test]
    fn a_smart_playlist_is_not_the_listeners_to_change() {
        let json = r#"{"MediaContainer":{"Metadata":[
            {"ratingKey":"7","title":"Mine","smart":false,"playlistType":"audio","leafCount":3,"composite":"/playlists/7/composite/1"},
            {"ratingKey":"8","title":"Top rated","smart":true,"playlistType":"audio"}]}}"#;
        let answer: Answer = serde_json::from_str(json).unwrap();
        let lists: Vec<Playlist> = answer
            .container
            .metadata
            .into_iter()
            .map(|item| playlist(item, &ART))
            .collect();
        assert!(lists[0].owned && !lists[1].owned);
        assert_eq!(lists[0].track_count, 3);
        assert!(lists[0].cover.as_deref().unwrap().contains("composite"));
    }

    #[test]
    fn playlist_entries_read_their_own_ids() {
        let json = r#"{"MediaContainer":{"Metadata":[
            {"ratingKey":"1203","playlistItemID":55},{"ratingKey":"1203","playlistItemID":"56"}]}}"#;
        let answer: Answer = serde_json::from_str(json).unwrap();
        let ids: Vec<_> = answer
            .container
            .metadata
            .iter()
            .map(|item| item.playlist_item_id.clone())
            .collect();
        assert_eq!(ids, [Some("55".to_owned()), Some("56".to_owned())]);
    }

    #[test]
    fn only_music_sections_are_libraries_and_genres_name_theirs() {
        let json = r#"{"MediaContainer":{"Directory":[
            {"key":"1","type":"movie","title":"Films"},{"key":"3","type":"artist","title":"Music"}]}}"#;
        let answer: Answer = serde_json::from_str(json).unwrap();
        assert_eq!(music_sections(answer.container.directory), ["3"]);
        let rock = Directory {
            key: "/library/sections/3/all?genre=88".into(),
            kind: None,
            title: Some("Rock".into()),
        };
        assert_eq!(genre("3", rock).id, "3:88");
        let jazz = Directory {
            key: "89".into(),
            kind: None,
            title: Some("Jazz".into()),
        };
        let jazz = genre("3", jazz);
        assert_eq!((jazz.id.as_str(), jazz.name.as_str()), ("3:89", "Jazz"));
    }

    /// `/api/v2/resources`, trimmed: a server with its addresses, and a player.
    const RESOURCES: &str = r#"[
        {"name":"Den","product":"Plex Media Server","clientIdentifier":"abc123","provides":"server",
         "owned":true,"accessToken":"server-token","connections":[
            {"protocol":"https","address":"52.1.1.1","port":32400,"uri":"https://52-1-1-1.x.plex.direct:8443","local":false,"relay":false},
            {"protocol":"https","address":"52.2.2.2","port":8443,"uri":"https://52-2-2-2.x.plex.direct:8443","local":false,"relay":true},
            {"protocol":"https","address":"192.168.1.4","port":32400,"uri":"https://192-168-1-4.x.plex.direct:32400","local":true,"relay":false}]},
        {"name":"Phone","product":"Plexamp","clientIdentifier":"p1","provides":"client,player","owned":true,"connections":[]}
    ]"#;

    #[test]
    fn servers_are_reached_locally_then_remotely_then_through_the_relay() {
        let resources: Vec<Resource> = serde_json::from_str(RESOURCES).unwrap();
        assert!(resources[0].is_server() && !resources[1].is_server());
        assert_eq!(
            resources[0].addresses(),
            [
                "https://192-168-1-4.x.plex.direct:32400",
                "https://52-1-1-1.x.plex.direct:8443",
                "https://52-2-2-2.x.plex.direct:8443"
            ]
        );
        assert_eq!(resources[0].access_token.as_deref(), Some("server-token"));
    }

    #[test]
    fn a_pin_reads_its_id_code_and_token_once_approved() {
        let waiting: Pin = serde_json::from_str(
            r#"{"id":4242,"code":"abcd1234","authToken":null,"expiresIn":1800}"#,
        )
        .unwrap();
        assert_eq!((waiting.id, waiting.code.as_str()), (4242, "abcd1234"));
        assert_eq!(waiting.auth_token, None);
        let approved: Pin =
            serde_json::from_str(r#"{"id":4242,"code":"abcd1234","authToken":"t0k"}"#).unwrap();
        assert_eq!(approved.auth_token.as_deref(), Some("t0k"));
    }

    #[test]
    fn an_account_reads_its_name() {
        let account: Account = serde_json::from_str(
            r#"{"id":99,"uuid":"u","username":"listener","title":"Listener"}"#,
        )
        .unwrap();
        assert_eq!(
            (account.id.as_str(), account.username.as_str()),
            ("99", "listener")
        );
    }
}
