//! Internet radio from Radio Browser (<https://api.radio-browser.info>), an open catalog of
//! stations that needs no account.
//!
//! A station is an endless live stream: it has no length, cannot seek, and is never kept. This
//! module lists stations and resolves the one about to play; [`playback`] plays it.

pub mod playback;

use std::sync::Arc;
use std::time::Duration;

use anyhow::{Context as _, Result, bail};
use serde::{Deserialize, Serialize};
use tokio::sync::OnceCell;

use crate::Track;

const AGENT: &str = concat!(
    "Cauce/",
    env!("CARGO_PKG_VERSION"),
    " (https://github.com/manuxdev/cause)"
);
/// Where the list of mirrors comes from.
const SERVERS: &str = "https://all.api.radio-browser.info/json/servers";
/// Mirrors to fall back on when the list cannot be had.
const FALLBACK: &[&str] = &[
    "de1.api.radio-browser.info",
    "de2.api.radio-browser.info",
    "fi1.api.radio-browser.info",
];
/// How many stations one listing asks for unless told otherwise.
const PAGE: u32 = 50;
/// How many countries, tags or languages a browse list shows, most stations first.
const FACETS: u32 = 120;
/// The codecs the decoder plays. Anything else, HLS above all, is left out.
const CODECS: &[&str] = &["MP3", "AAC", "AAC+", "OGG", "OPUS", "FLAC"];

/// One station, as the app shows and plays it.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Station {
    pub id: String,
    pub name: String,
    pub country: String,
    pub country_code: String,
    pub tags: Vec<String>,
    /// Only an https logo: a plain http one would be refused by the platform anyway.
    pub favicon: Option<String>,
    /// The stream, already resolved from any playlist.
    pub url: String,
    pub bitrate: u32,
    pub codec: String,
}

impl Station {
    /// The country and the first few tags, such as "Germany · pop, rock".
    pub fn subtitle(&self) -> String {
        let tags = self.tags.iter().take(3).cloned().collect::<Vec<_>>().join(", ");
        [self.country.as_str(), tags.as_str()]
            .into_iter()
            .filter(|part| !part.is_empty())
            .collect::<Vec<_>>()
            .join(" · ")
    }

    /// The station as a track: its name as the title, its subtitle as the artists, its logo as
    /// the cover, and no length.
    pub fn track(&self) -> Track {
        Track {
            id: Some(self.id.clone()),
            name: self.name.clone(),
            playable: true,
            artists: self.subtitle(),
            artist_refs: Vec::new(),
            album: String::new(),
            album_id: None,
            cover: self.favicon.clone(),
            duration: Duration::ZERO,
            added_at: None,
            added_by: None,
            playcount: None,
            popularity: 0,
            explicit: false,
            track_number: 0,
            disc_number: 0,
            tags: self.tags.clone(),
            languages: Vec::new(),
            credits: Vec::new(),
        }
    }
}

/// A country, tag or language to browse by, and how many stations it has.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Facet {
    pub name: String,
    /// The country's ISO 3166-1 code or the language's ISO 639 code; none for a tag.
    pub code: Option<String>,
    pub stations: u32,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum Order {
    #[default]
    Clicks,
    Votes,
}

impl Order {
    fn param(self) -> &'static str {
        match self {
            Self::Clicks => "clickcount",
            Self::Votes => "votes",
        }
    }
}

/// A station search. Every filter is optional; blank ones are left out.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Query {
    pub name: Option<String>,
    pub country_code: Option<String>,
    pub tag: Option<String>,
    pub language: Option<String>,
    pub order: Order,
    pub offset: u32,
    /// Zero asks for a page of the default size.
    pub limit: u32,
}

/// The parameters of `/json/stations/search` for `query`: the filters it sets, most popular
/// first, broken stations hidden.
pub fn search_params(query: &Query) -> Vec<(&'static str, String)> {
    let set = |value: &Option<String>| {
        value
            .as_deref()
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(str::to_owned)
    };
    let mut params = Vec::new();
    if let Some(name) = set(&query.name) {
        params.push(("name", name));
    }
    if let Some(code) = set(&query.country_code) {
        params.push(("countrycode", code.to_uppercase()));
    }
    if let Some(tag) = set(&query.tag) {
        params.push(("tag", tag));
        params.push(("tagExact", "true".to_owned()));
    }
    if let Some(language) = set(&query.language) {
        params.push(("language", language));
        params.push(("languageExact", "true".to_owned()));
    }
    let limit = if query.limit == 0 { PAGE } else { query.limit };
    params.extend([
        ("order", query.order.param().to_owned()),
        ("reverse", "true".to_owned()),
        ("hidebroken", "true".to_owned()),
        ("limit", limit.to_string()),
        ("offset", query.offset.to_string()),
    ]);
    params
}

/// A station as Radio Browser lists it, with only the fields the app reads.
#[derive(Deserialize)]
struct Wire {
    stationuuid: String,
    #[serde(default)]
    name: String,
    #[serde(default)]
    url_resolved: String,
    #[serde(default)]
    url: String,
    #[serde(default)]
    favicon: Option<String>,
    #[serde(default)]
    tags: Option<String>,
    #[serde(default)]
    country: Option<String>,
    #[serde(default)]
    countrycode: Option<String>,
    #[serde(default)]
    codec: Option<String>,
    #[serde(default)]
    bitrate: Option<u32>,
    #[serde(default)]
    hls: Option<u8>,
    #[serde(default)]
    lastcheckok: Option<u8>,
}

/// The playable stations in a Radio Browser listing: not broken at the last check, not HLS,
/// and in a codec the decoder plays.
pub fn stations(json: &[u8]) -> Result<Vec<Station>> {
    let listed: Vec<Wire> =
        serde_json::from_slice(json).context("cannot read the station list")?;
    Ok(listed.into_iter().filter_map(station).collect())
}

fn station(wire: Wire) -> Option<Station> {
    let url = Some(wire.url_resolved.trim())
        .filter(|url| !url.is_empty())
        .unwrap_or(wire.url.trim())
        .to_owned();
    let codec = wire.codec.unwrap_or_default().trim().to_uppercase();
    let playable = wire.lastcheckok == Some(1)
        && wire.hls != Some(1)
        && CODECS.contains(&codec.as_str())
        && url.starts_with("http")
        && !url.to_lowercase().split('?').next().unwrap_or("").ends_with(".m3u8");
    let name = wire.name.trim().to_owned();
    if !playable || name.is_empty() {
        return None;
    }
    Some(Station {
        id: wire.stationuuid,
        name,
        country: wire.country.unwrap_or_default().trim().to_owned(),
        country_code: wire.countrycode.unwrap_or_default().trim().to_uppercase(),
        tags: wire
            .tags
            .unwrap_or_default()
            .split(',')
            .map(str::trim)
            .filter(|tag| !tag.is_empty())
            .map(str::to_owned)
            .collect(),
        favicon: wire
            .favicon
            .map(|favicon| favicon.trim().to_owned())
            .filter(|favicon| favicon.starts_with("https://")),
        url,
        bitrate: wire.bitrate.unwrap_or(0),
        codec,
    })
}

#[derive(Deserialize)]
struct WireFacet {
    name: String,
    #[serde(default, alias = "iso_3166_1", alias = "iso_639")]
    code: Option<String>,
    #[serde(default)]
    stationcount: u32,
}

fn facets(json: &[u8]) -> Result<Vec<Facet>> {
    let listed: Vec<WireFacet> = serde_json::from_slice(json).context("cannot read the list")?;
    Ok(listed
        .into_iter()
        .filter(|facet| !facet.name.trim().is_empty() && facet.stationcount > 0)
        .map(|facet| Facet {
            name: facet.name.trim().to_owned(),
            code: facet.code.filter(|code| !code.is_empty()),
            stations: facet.stationcount,
        })
        .collect())
}

#[derive(Deserialize)]
struct Clicked {
    ok: bool,
    #[serde(default)]
    url: String,
}

/// The Radio Browser API, through one mirror picked at random for the session.
#[derive(Clone)]
pub struct RadioBrowser {
    http: reqwest::Client,
    server: Arc<OnceCell<String>>,
}

impl Default for RadioBrowser {
    fn default() -> Self {
        Self::new()
    }
}

impl RadioBrowser {
    pub fn new() -> Self {
        Self {
            http: reqwest::Client::builder()
                .user_agent(AGENT)
                .connect_timeout(Duration::from_secs(10))
                .timeout(Duration::from_secs(20))
                .build()
                .unwrap_or_default(),
            server: Arc::default(),
        }
    }

    /// The mirror for this session, asked for once.
    async fn base(&self) -> String {
        let server = self
            .server
            .get_or_init(|| async {
                let listed = async {
                    let servers: Vec<WireServer> =
                        self.http.get(SERVERS).send().await?.json().await?;
                    anyhow::Ok(servers)
                };
                let mut names: Vec<String> = match listed.await {
                    Ok(servers) => servers.into_iter().map(|server| server.name).collect(),
                    Err(error) => {
                        log::warn!("radio: cannot list the mirrors: {error:#}");
                        Vec::new()
                    }
                };
                names.sort();
                names.dedup();
                if names.is_empty() {
                    names = FALLBACK.iter().map(|name| (*name).to_owned()).collect();
                }
                let picked = names.swap_remove(fastrand::usize(..names.len()));
                log::info!("radio: using {picked}");
                picked
            })
            .await;
        format!("https://{server}/json")
    }

    async fn get(&self, path: &str, params: &[(&str, String)]) -> Result<Vec<u8>> {
        let url = format!("{}{path}", self.base().await);
        let response = self
            .http
            .get(url)
            .query(params)
            .send()
            .await
            .map_err(reqwest::Error::without_url)
            .context("cannot reach Radio Browser")?;
        let status = response.status();
        if !status.is_success() {
            bail!("Radio Browser answered with status {status}");
        }
        Ok(response
            .bytes()
            .await
            .map_err(reqwest::Error::without_url)?
            .to_vec())
    }

    pub async fn search(&self, query: &Query) -> Result<Vec<Station>> {
        stations(&self.get("/stations/search", &search_params(query)).await?)
    }

    /// The most played or the most voted stations.
    pub async fn top(&self, order: Order, limit: u32) -> Result<Vec<Station>> {
        let path = match order {
            Order::Clicks => "/stations/topclick",
            Order::Votes => "/stations/topvote",
        };
        let params = [
            ("hidebroken", "true".to_owned()),
            ("limit", limit.max(1).to_string()),
        ];
        stations(&self.get(path, &params).await?)
    }

    pub async fn countries(&self) -> Result<Vec<Facet>> {
        self.facets("/countries").await
    }

    pub async fn tags(&self) -> Result<Vec<Facet>> {
        self.facets("/tags").await
    }

    pub async fn languages(&self) -> Result<Vec<Facet>> {
        self.facets("/languages").await
    }

    async fn facets(&self, path: &str) -> Result<Vec<Facet>> {
        let params = [
            ("order", "stationcount".to_owned()),
            ("reverse", "true".to_owned()),
            ("hidebroken", "true".to_owned()),
            ("limit", FACETS.to_string()),
        ];
        facets(&self.get(path, &params).await?)
    }

    /// Counts a play of station `id`, as Radio Browser asks every client to, and answers the
    /// stream it resolves to.
    pub async fn click(&self, id: &str) -> Result<String> {
        let clicked: Clicked = serde_json::from_slice(&self.get(&format!("/url/{id}"), &[]).await?)
            .context("cannot read the station's stream")?;
        if !clicked.ok || !clicked.url.starts_with("http") {
            bail!("Radio Browser has no stream for that station");
        }
        Ok(clicked.url)
    }
}

#[derive(Deserialize)]
struct WireServer {
    name: String,
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Trimmed from a real `/json/stations/search` answer, with a broken, an HLS and an
    /// unknown-codec station added the way the catalog lists them.
    const LISTED: &str = r#"[
      {"changeuuid":"c7162475-4f4c-41ed-be3b-19ad8f87e4ac","stationuuid":"d28420a4-eccf-47a2-ace1-088c7e7cb7e0","serveruuid":null,"name":"101 SMOOTH JAZZ","url":"http://www.101smoothjazz.com/101-smoothjazz.m3u","url_resolved":"http://jking.cdnstream1.com/b22139_128mp3","homepage":"http://101smoothjazz.com/","favicon":"http://101smoothjazz.com/favicon.ico","tags":"easy listening,jazz,smooth jazz","country":"The United States Of America","countrycode":"US","state":"California","language":"english","languagecodes":"en","votes":90915,"codec":"MP3","bitrate":192,"hls":0,"lastcheckok":1,"clickcount":539,"ssl_error":0,"geo_lat":null,"geo_long":null,"has_extended_info":false},
      {"stationuuid":"ea8059be-d119-4de3-b27b-0d9bd6aedb17","name":"Adroit Jazz Underground","url":"https://icecast.walmradio.com:8443/jazz","url_resolved":"https://icecast.walmradio.com:8443/jazz","favicon":"https://icecast.walmradio.com:8443/jazz.jpg","tags":"avant-garde,bebop,big band,bop","country":"The United States Of America","countrycode":"US","codec":"MP3","bitrate":320,"hls":0,"lastcheckok":1},
      {"stationuuid":"broken","name":"Gone FM","url_resolved":"https://example.com/gone","codec":"MP3","bitrate":128,"hls":0,"lastcheckok":0},
      {"stationuuid":"hls","name":"Segments FM","url_resolved":"https://example.com/live/playlist.m3u8","codec":"AAC","bitrate":96,"hls":1,"lastcheckok":1},
      {"stationuuid":"unflagged-hls","name":"Quiet Segments","url_resolved":"https://example.com/live.m3u8?token=1","codec":"AAC","bitrate":96,"hls":0,"lastcheckok":1},
      {"stationuuid":"unknown","name":"Mystery FM","url_resolved":"https://example.com/mystery","codec":"UNKNOWN","bitrate":0,"hls":0,"lastcheckok":1},
      {"stationuuid":"video","name":"Telly FM","url_resolved":"https://example.com/tv","codec":"AAC,H.264","bitrate":0,"hls":0,"lastcheckok":1},
      {"stationuuid":"opus","name":"  Opus Radio ","url":"https://example.com/opus","url_resolved":"","favicon":"","tags":"","country":"","countrycode":"de","codec":"opus","hls":0,"lastcheckok":1}
    ]"#;

    #[test]
    fn a_listing_keeps_only_the_stations_that_play() {
        let ids: Vec<String> = stations(LISTED.as_bytes())
            .unwrap()
            .into_iter()
            .map(|station| station.id)
            .collect();
        assert_eq!(
            ids,
            [
                "d28420a4-eccf-47a2-ace1-088c7e7cb7e0",
                "ea8059be-d119-4de3-b27b-0d9bd6aedb17",
                "opus"
            ]
        );
    }

    #[test]
    fn a_station_maps_to_the_apps_model() {
        let listed = stations(LISTED.as_bytes()).unwrap();
        let jazz = &listed[1];
        assert_eq!(jazz.name, "Adroit Jazz Underground");
        assert_eq!(jazz.url, "https://icecast.walmradio.com:8443/jazz");
        assert_eq!(jazz.codec, "MP3");
        assert_eq!(jazz.bitrate, 320);
        assert_eq!(
            jazz.favicon.as_deref(),
            Some("https://icecast.walmradio.com:8443/jazz.jpg")
        );
        assert_eq!(
            jazz.subtitle(),
            "The United States Of America · avant-garde, bebop, big band"
        );
        let track = jazz.track();
        assert_eq!(track.id.as_deref(), Some(jazz.id.as_str()));
        assert_eq!(track.name, jazz.name);
        assert_eq!(track.artists, jazz.subtitle());
        assert_eq!(track.cover, jazz.favicon);
        assert_eq!(track.duration, Duration::ZERO, "a station has no length");
        assert!(track.playable);
    }

    #[test]
    fn a_station_without_a_usable_logo_or_resolved_url_still_plays() {
        let listed = stations(LISTED.as_bytes()).unwrap();
        // A plain http logo would be refused by the platform: the placeholder shows instead.
        assert_eq!(listed[0].favicon, None);
        let opus = &listed[2];
        assert_eq!(opus.name, "Opus Radio");
        assert_eq!(opus.url, "https://example.com/opus", "falls back on `url`");
        assert_eq!(opus.favicon, None);
        assert_eq!(opus.country_code, "DE");
        assert_eq!(opus.codec, "OPUS");
        assert!(opus.tags.is_empty());
        assert_eq!(opus.subtitle(), "");
    }

    #[test]
    fn a_listing_that_is_not_one_is_an_error() {
        assert!(stations(b"{\"error\":true}").is_err());
    }

    #[test]
    fn facets_read_countries_tags_and_languages() {
        let countries = facets(
            br#"[{"name":"Germany","iso_3166_1":"DE","stationcount":6589},{"name":"","iso_3166_1":"XX","stationcount":3}]"#,
        )
        .unwrap();
        assert_eq!(
            countries,
            [Facet {
                name: "Germany".to_owned(),
                code: Some("DE".to_owned()),
                stations: 6589
            }]
        );
        let tags = facets(br#"[{"name":"pop","stationcount":6239},{"name":"none","stationcount":0}]"#).unwrap();
        assert_eq!(tags.len(), 1);
        assert_eq!(tags[0].code, None);
        let languages = facets(br#"[{"name":"spanish","iso_639":"es","stationcount":5923}]"#).unwrap();
        assert_eq!(languages[0].code.as_deref(), Some("es"));
    }

    #[test]
    fn a_search_sets_only_its_filters_most_popular_first() {
        let params = search_params(&Query {
            name: Some(" jazz ".to_owned()),
            country_code: Some("us".to_owned()),
            tag: Some("   ".to_owned()),
            language: None,
            order: Order::Votes,
            offset: 50,
            limit: 25,
        });
        let expected: Vec<(&str, String)> = vec![
            ("name", "jazz".to_owned()),
            ("countrycode", "US".to_owned()),
            ("order", "votes".to_owned()),
            ("reverse", "true".to_owned()),
            ("hidebroken", "true".to_owned()),
            ("limit", "25".to_owned()),
            ("offset", "50".to_owned()),
        ];
        assert_eq!(params, expected);
    }

    #[test]
    fn a_search_by_tag_or_language_matches_it_exactly_and_pages_by_default() {
        let params = search_params(&Query {
            tag: Some("rock".to_owned()),
            language: Some("spanish".to_owned()),
            ..Query::default()
        });
        assert!(params.contains(&("tag", "rock".to_owned())));
        assert!(params.contains(&("tagExact", "true".to_owned())));
        assert!(params.contains(&("language", "spanish".to_owned())));
        assert!(params.contains(&("languageExact", "true".to_owned())));
        assert!(params.contains(&("order", "clickcount".to_owned())));
        assert!(params.contains(&("limit", PAGE.to_string())));
        assert!(!params.iter().any(|(key, _)| *key == "name"));
    }

    /// Searches for a well-known station, resolves it the way a play does, and reads the first
    /// bytes of its stream. Needs the network: `cargo test -p music radio -- --ignored`.
    #[tokio::test]
    #[ignore]
    async fn live_a_known_station_resolves_and_streams() {
        let browser = RadioBrowser::new();
        let found = browser
            .search(&Query {
                name: Some("Radio Paradise".to_owned()),
                ..Query::default()
            })
            .await
            .unwrap();
        let station = found.first().expect("Radio Paradise is listed");
        let url = browser.click(&station.id).await.unwrap();
        let mut response = reqwest::Client::new()
            .get(url)
            .header("Icy-MetaData", "1")
            .send()
            .await
            .unwrap();
        assert!(response.status().is_success());
        let first = response.chunk().await.unwrap().expect("the stream sends bytes");
        assert!(!first.is_empty());
        println!(
            "{} ({} {} kbps): {} bytes, {:?}",
            station.name,
            station.codec,
            station.bitrate,
            first.len(),
            response.headers().get("content-type")
        );
    }
}
