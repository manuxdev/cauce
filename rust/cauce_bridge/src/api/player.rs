use std::path::PathBuf;
use std::sync::{Mutex, OnceLock};
use std::time::Duration;

use anyhow::{Context as _, Result};
use music::{Encoding, GenreItem, HomeFeed, Lyrics, MediaKind, Track};
use cauce_core::{Cookie, Core, Item, Paths, PlayerState, Repeat, Status};

use crate::frb_generated::StreamSink;

// ponytail: one global core for the spike; becomes an opaque handle once the API grows.
static CORE: OnceLock<Core> = OnceLock::new();

/// How a provider signs in through a webview: open `url`, and once cookies for `domain` exist,
/// hand them all to `sign_in_with_cookies` until it answers a name.
pub struct WebLogin {
    pub url: String,
    pub landing: String,
    pub domain: String,
    /// The user agent the webview must present, when the provider's anti-bot wants one.
    pub agent: Option<String>,
}

/// One cookie from the webview's store.
pub struct WebCookie {
    pub name: String,
    pub value: String,
    pub domain: String,
}

/// A track as screens draw it, and as they hand it back to be queued. `source` is the provider
/// slug, or `local` for a file.
#[derive(Clone)]
pub struct TrackItem {
    pub source: String,
    pub id: String,
    pub title: String,
    pub artists: String,
    pub album: String,
    pub cover: Option<String>,
    /// The same cover asked for at full-screen size.
    pub cover_large: Option<String>,
    pub duration_ms: u64,
    pub playable: bool,
    /// Where "Go to album" leads, when the provider names the album.
    pub album_id: Option<String>,
    /// Where "Go to artist" leads: every credited artist the provider can open.
    pub artist_links: Vec<ArtistLink>,
}

#[derive(Clone)]
pub struct ArtistLink {
    pub id: String,
    pub name: String,
}

/// An artist's page: their best-known tracks and their releases.
pub struct ArtistPage {
    pub name: String,
    pub cover: Option<String>,
    pub top_tracks: Vec<TrackItem>,
    pub albums: Vec<MediaCard>,
}

pub enum CardKind {
    Track,
    Album,
    Playlist,
    Artist,
}

/// One tile on a home shelf. `track` is set for a track, which plays on a tap; the rest open
/// their tracks through `collection_tracks`.
pub struct MediaCard {
    pub kind: CardKind,
    pub id: String,
    pub title: String,
    pub subtitle: String,
    pub cover: Option<String>,
    pub track: Option<TrackItem>,
}

pub struct HomeShelf {
    pub title: String,
    pub cards: Vec<MediaCard>,
}

pub struct LyricWord {
    pub start_ms: u64,
    pub end_ms: u64,
    pub text: String,
}

pub struct LyricLine {
    pub start_ms: u64,
    pub end_ms: Option<u64>,
    pub text: String,
    /// Word timings for karaoke; empty when the line is only timed as a whole.
    pub words: Vec<LyricWord>,
}

/// Lyrics as the player draws them. Plain lyrics come as untimed lines with `synced` off.
pub struct LyricsView {
    pub synced: bool,
    pub lines: Vec<LyricLine>,
}

pub enum PlaybackStatus {
    Idle,
    Loading,
    Playing,
    Paused,
}

pub enum RepeatMode {
    Off,
    All,
    One,
}

pub struct PlayerSnapshot {
    pub track: Option<TrackItem>,
    pub index: Option<u32>,
    pub queue: Vec<TrackItem>,
    pub status: PlaybackStatus,
    pub position_ms: u64,
    pub duration_ms: u64,
    pub repeat: RepeatMode,
    /// How the stream is encoded, such as "AAC · 256 kbps", once the engine has said.
    pub quality: Option<String>,
    /// Playback rests once the current track ends.
    pub stops_after_current: bool,
    /// Playback stopped because several tracks in a row could not be played.
    pub stalled: bool,
}

/// Where player states go once Dart listens; until then they are dropped.
static STATES: Mutex<Option<StreamSink<PlayerSnapshot>>> = Mutex::new(None);

/// Starts the core once. Await it before any other call: everything else needs the core.
pub fn init(data_dir: String, cache_dir: String) -> Result<()> {
    if CORE.get().is_some() {
        return Ok(());
    }
    let paths = Paths {
        data: PathBuf::from(data_dir),
        cache: PathBuf::from(cache_dir),
    };
    let core = Core::start(paths, |state| {
        if let Some(states) = STATES
            .lock()
            .ok()
            .as_ref()
            .and_then(|states| states.as_ref())
        {
            states.add(snapshot(state)).ok();
        }
    })?;
    CORE.set(core).ok();
    Ok(())
}

/// Every change to the player from now on, starting with the current state.
pub fn player_states(states: StreamSink<PlayerSnapshot>) -> Result<()> {
    states.add(snapshot(core()?.state())).ok();
    *STATES
        .lock()
        .map_err(|_| anyhow::anyhow!("the player stream lock is poisoned"))? = Some(states);
    Ok(())
}

pub fn web_sign_in(slug: String) -> Result<Option<WebLogin>> {
    Ok(core()?.web_sign_in(&slug)?.map(|web| WebLogin {
        url: web.url.to_owned(),
        landing: web.landing.to_owned(),
        domain: web.domain.to_owned(),
        agent: web.agent.map(str::to_owned),
    }))
}

/// The display name of the account a provider stored, or `None` when there is none.
pub fn restore(slug: String) -> Result<Option<String>> {
    core()?.restore(&slug)
}

/// `None` while the cookies prove no session yet; the account's display name once signed in.
pub fn sign_in_with_cookies(slug: String, cookies: Vec<WebCookie>) -> Result<Option<String>> {
    let cookies: Vec<Cookie> = cookies
        .into_iter()
        .map(|cookie| Cookie {
            name: cookie.name,
            value: cookie.value,
            domain: cookie.domain,
        })
        .collect();
    core()?.sign_in_with_cookies(&slug, &cookies)
}

/// Whether `slug`'s account plays its own tracks. A free Spotify account only browses, and its
/// songs play from another connected service.
#[flutter_rust_bridge::frb(sync)]
pub fn streams(slug: String) -> Result<bool> {
    Ok(core()?.streams(&slug))
}

/// Whether `slug` has an account stored, without reaching it.
#[flutter_rust_bridge::frb(sync)]
pub fn stored(slug: String) -> Result<bool> {
    core()?.stored(&slug)
}

/// Where a sign-in stands: asking the listener to type `code` on the page at `url`, or, with no
/// code, to approve on that page, which hands the answer back to a local address; or, last,
/// signed in as `name`.
#[derive(Clone)]
pub struct SignInEvent {
    pub code: Option<String>,
    pub url: String,
    pub name: Option<String>,
}

/// Signs `slug` in. With a `server`, it signs in to that server with `username` and `password`;
/// otherwise the provider's own flow runs. Its prompts arrive on `events`, then the account's
/// name; a failure ends the stream with the error.
pub fn sign_in_flow(
    slug: String,
    server: String,
    username: String,
    password: String,
    events: StreamSink<SignInEvent>,
) -> Result<()> {
    let method = match server.is_empty() {
        true => music::SignIn::Default,
        false => music::SignIn::Credentials {
            server,
            username,
            password,
        },
    };
    let prompts = events.clone();
    let signed_in = core()?.sign_in(&slug, method, move |prompt| {
        let (code, url) = match prompt {
            music::SignInPrompt::Code { code, url } => (Some(code), url),
            music::SignInPrompt::Url(url) => (None, url),
            _ => return,
        };
        prompts
            .add(SignInEvent {
                code,
                url,
                name: None,
            })
            .ok();
    });
    // Dart runs this call unawaited and only listens to the stream, so a failure goes there too.
    let name = match signed_in {
        Ok(name) => name,
        Err(error) => {
            events.add_error(error).ok();
            return Ok(());
        }
    };
    events
        .add(SignInEvent {
            code: None,
            url: String::new(),
            name: Some(name),
        })
        .ok();
    Ok(())
}

/// Gives up on the sign-in `slug` is waiting on.
pub fn sign_in_cancel(slug: String) -> Result<()> {
    core()?.sign_in_cancel(&slug)
}

pub fn sign_out(slug: String) -> Result<()> {
    core()?.sign_out(&slug)
}

pub fn search(slug: String, query: String) -> Result<Vec<TrackItem>> {
    let tracks = core()?.search(&slug, query)?;
    Ok(tracks
        .into_iter()
        .filter_map(|track| track_item(&slug, &track))
        .collect())
}

/// Albums matching `query`, as cards that open their tracks.
pub fn search_albums(slug: String, query: String) -> Result<Vec<MediaCard>> {
    let albums = core()?.search_albums(&slug, query)?;
    Ok(albums
        .into_iter()
        .filter_map(|album| card(&slug, GenreItem::Album(album)))
        .collect())
}

/// A style to browse by. `cover` is a picture when the service has one.
pub struct GenreCard {
    pub id: String,
    pub name: String,
    pub cover: Option<String>,
}

pub fn genres(slug: String) -> Result<Vec<GenreCard>> {
    Ok(core()?
        .genres(&slug)?
        .into_iter()
        .map(|genre| GenreCard {
            id: genre.id,
            name: genre.name,
            cover: genre.cover,
        })
        .collect())
}

/// The shelf titles a genre page needs from the app, in the listener's language.
pub struct GenreTitles {
    pub tracks: String,
    pub albums: String,
    pub artists: String,
    pub playlists: String,
}

/// A style's page as shelves, like the home feed's.
pub fn genre_page(slug: String, id: String, titles: GenreTitles) -> Result<Vec<HomeShelf>> {
    let titles = cauce_core::genres::Titles {
        tracks: titles.tracks,
        albums: titles.albums,
        artists: titles.artists,
        playlists: titles.playlists,
    };
    let detail = core()?.genre(&slug, id, titles)?;
    Ok(detail
        .sections
        .into_iter()
        .map(|section| HomeShelf {
            title: section.title,
            cards: section
                .items
                .into_iter()
                .filter_map(|item| card(&slug, item))
                .collect(),
        })
        .filter(|shelf| !shelf.cards.is_empty())
        .collect())
}

/// A playlist a track can be added to.
pub struct PlaylistItem {
    pub id: String,
    pub name: String,
    pub cover: Option<String>,
    pub track_count: u32,
}

pub fn own_playlists(slug: String) -> Result<Vec<PlaylistItem>> {
    Ok(core()?
        .own_playlists(&slug)?
        .into_iter()
        .map(|playlist| PlaylistItem {
            id: playlist.id,
            name: playlist.name,
            cover: playlist.cover,
            track_count: playlist.track_count,
        })
        .collect())
}

/// Makes a playlist called `name` and answers its id.
pub fn create_playlist(slug: String, name: String) -> Result<String> {
    core()?.create_playlist(&slug, name)
}

pub fn add_to_playlist(slug: String, playlist_id: String, track_id: String) -> Result<()> {
    core()?.add_to_playlist(&slug, playlist_id, track_id)
}

pub fn rename_playlist(slug: String, playlist_id: String, name: String) -> Result<()> {
    core()?.rename_playlist(&slug, playlist_id, name)
}

pub fn delete_playlist(slug: String, playlist_id: String) -> Result<()> {
    core()?.delete_playlist(&slug, playlist_id)
}

/// The provider's recommendations as shelves: quick picks, listen again, then its own.
pub fn home(slug: String) -> Result<Vec<HomeShelf>> {
    Ok(shelves(&slug, core()?.home(&slug)?))
}

pub fn saved_tracks(slug: String) -> Result<Vec<TrackItem>> {
    let tracks = core()?.saved_tracks(&slug)?;
    Ok(tracks
        .iter()
        .filter_map(|track| track_item(&slug, track))
        .collect())
}

pub fn set_saved(slug: String, track_id: String, saved: bool) -> Result<()> {
    core()?.set_saved(&slug, track_id, saved)
}

/// The tracks behind an album, playlist or artist card.
pub fn collection_tracks(slug: String, kind: CardKind, id: String) -> Result<Vec<TrackItem>> {
    let kind = match kind {
        CardKind::Track => MediaKind::Track,
        CardKind::Album => MediaKind::Album,
        CardKind::Playlist => MediaKind::Playlist,
        CardKind::Artist => MediaKind::Artist,
    };
    let tracks = core()?.collection_tracks(&slug, kind, id)?;
    Ok(tracks
        .iter()
        .filter_map(|track| track_item(&slug, track))
        .collect())
}

pub fn artist_page(slug: String, id: String) -> Result<ArtistPage> {
    let artist = core()?.artist(&slug, id)?;
    Ok(ArtistPage {
        name: artist.name,
        cover: artist.cover_large,
        top_tracks: artist
            .top_tracks
            .iter()
            .filter_map(|track| track_item(&slug, track))
            .collect(),
        albums: artist
            .albums
            .into_iter()
            .filter_map(|album| card(&slug, GenreItem::Album(album)))
            .collect(),
    })
}

/// Lyrics for `track`, the sources tried in the order of `sources` (`provider`, `server`, `lrclib`, `lrc`).
pub fn lyrics(track: TrackItem, sources: Vec<String>) -> Result<Option<LyricsView>> {
    let Some(lyrics) = core()?.lyrics(&item(track), &sources)? else {
        return Ok(None);
    };
    let millis = |duration: Duration| duration.as_millis() as u64;
    Ok(Some(match lyrics {
        Lyrics::Plain { text, .. } => LyricsView {
            synced: false,
            lines: text
                .lines()
                .map(|line| LyricLine {
                    start_ms: 0,
                    end_ms: None,
                    text: line.to_owned(),
                    words: Vec::new(),
                })
                .collect(),
        },
        Lyrics::Synced { lines } => LyricsView {
            synced: true,
            lines: lines
                .iter()
                .map(|line| LyricLine {
                    start_ms: millis(line.start),
                    end_ms: line.end.map(millis),
                    text: line.text.clone(),
                    words: karaoke(&line.text, line.words.as_deref().unwrap_or_default()),
                })
                .collect(),
        },
    }))
}

/// Makes `tracks` the queue and plays `start`.
pub fn play_queue(tracks: Vec<TrackItem>, start: u32) -> Result<()> {
    core()?.play_queue(tracks.into_iter().map(item).collect(), start as usize)
}

/// Makes the files at `paths` the queue and plays `start`. Files that do not read as audio are
/// left out.
pub fn play_files(paths: Vec<String>, start: u32) -> Result<()> {
    let core = core()?;
    let chosen = paths.get(start as usize).cloned();
    let items: Vec<Item> = paths
        .into_iter()
        .filter_map(|path| core.file_item(PathBuf::from(path)).ok())
        .collect();
    let start = chosen
        .and_then(|chosen| items.iter().position(|item| item.id.ends_with(&chosen)))
        .unwrap_or(0);
    core.play_queue(items, start)
}

pub fn next() -> Result<()> {
    core()?.next()
}

pub fn previous() -> Result<()> {
    core()?.previous()
}

pub fn jump(index: u32) -> Result<()> {
    core()?.jump(index as usize)
}

pub fn set_repeat(repeat: RepeatMode) -> Result<()> {
    core()?.set_repeat(match repeat {
        RepeatMode::Off => Repeat::Off,
        RepeatMode::All => Repeat::All,
        RepeatMode::One => Repeat::One,
    });
    Ok(())
}

/// The playback preferences. `bands` holds the ten graphic equalizer gains in dB.
pub struct PlaybackSettings {
    pub normalisation: bool,
    pub gapless: bool,
    pub quality: String,
    pub quality_cellular: String,
    pub data_saver: bool,
    pub continue_similar: bool,
    pub remember_repeat: bool,
    pub resume_on_connect: bool,
    pub downloads_wifi_only: bool,
    pub download_likes: bool,
    /// The quality id downloads are fetched at.
    pub download_quality: String,
    /// Downloads not played for 90 days are removed on their own.
    pub free_space: bool,
    /// The last queue comes back, paused, on the next launch.
    pub resume_last: bool,
    pub equalizer: bool,
    pub bands: Vec<f64>,
    pub keep_tracks: bool,
    pub cache_gb: u32,
}

/// One stream level a service serves: `id` to store, `encoding` to show.
pub struct QualityOption {
    pub id: String,
    pub encoding: String,
    /// The encoding is the most a track comes at.
    pub up_to: bool,
}

pub struct EqualizerPreset {
    pub id: String,
    pub bands: Vec<f64>,
}

pub struct StorageUsage {
    pub cache_bytes: u64,
    pub download_bytes: u64,
}

pub fn playback_settings() -> Result<PlaybackSettings> {
    let settings = core()?.playback_settings();
    Ok(PlaybackSettings {
        normalisation: settings.normalisation,
        gapless: settings.gapless,
        quality: settings.quality,
        quality_cellular: settings.quality_cellular,
        data_saver: settings.data_saver,
        continue_similar: settings.continue_similar,
        remember_repeat: settings.remember_repeat,
        resume_on_connect: settings.resume_on_connect,
        downloads_wifi_only: settings.downloads_wifi_only,
        download_likes: settings.download_likes,
        download_quality: settings.download_quality,
        free_space: settings.free_space,
        resume_last: settings.resume_last,
        equalizer: settings.equalizer,
        bands: settings.bands.to_vec(),
        keep_tracks: settings.keep_tracks,
        cache_gb: settings.cache_gb as u32,
    })
}

pub fn set_playback_settings(settings: PlaybackSettings) -> Result<()> {
    let mut bands = [0.; 10];
    for (band, gain) in bands.iter_mut().zip(settings.bands) {
        *band = gain;
    }
    core()?.set_playback_settings(cauce_core::settings::PlaybackSettings {
        normalisation: settings.normalisation,
        gapless: settings.gapless,
        quality: settings.quality,
        quality_cellular: settings.quality_cellular,
        data_saver: settings.data_saver,
        continue_similar: settings.continue_similar,
        remember_repeat: settings.remember_repeat,
        resume_on_connect: settings.resume_on_connect,
        downloads_wifi_only: settings.downloads_wifi_only,
        download_likes: settings.download_likes,
        download_quality: settings.download_quality,
        free_space: settings.free_space,
        resume_last: settings.resume_last,
        equalizer: settings.equalizer,
        bands,
        keep_tracks: settings.keep_tracks,
        cache_gb: u64::from(settings.cache_gb),
    });
    Ok(())
}

/// The cache sizes the slider allows, in GB.
#[flutter_rust_bridge::frb(sync)]
pub fn cache_gb_range() -> (u32, u32) {
    let (low, high) = cauce_core::settings::CACHE_GB_RANGE;
    (low as u32, high as u32)
}

pub fn qualities(slug: String) -> Result<Vec<QualityOption>> {
    Ok(core()?
        .qualities(&slug)
        .into_iter()
        .map(|offer| QualityOption {
            id: offer.quality.id().to_owned(),
            encoding: encoding(offer.encoding),
            up_to: offer.up_to,
        })
        .collect())
}

#[flutter_rust_bridge::frb(sync)]
pub fn equalizer_presets() -> Vec<EqualizerPreset> {
    cauce_core::settings::presets()
        .into_iter()
        .map(|(id, bands)| EqualizerPreset {
            id: id.to_owned(),
            bands: bands.to_vec(),
        })
        .collect()
}

pub fn storage_usage() -> Result<StorageUsage> {
    let (cache_bytes, download_bytes) = core()?.storage_usage()?;
    Ok(StorageUsage {
        cache_bytes,
        download_bytes,
    })
}

pub fn clear_cache() -> Result<()> {
    core()?.clear_cache();
    Ok(())
}

pub fn clear_downloads() -> Result<()> {
    core()?.clear_downloads();
    Ok(())
}

pub enum DownloadState {
    Queued,
    Running,
    Done,
    Failed,
}

/// One listed download. `progress` runs from 0 to 1 while it downloads, once the player can tell.
pub struct DownloadItem {
    pub track: TrackItem,
    pub state: DownloadState,
    pub progress: Option<f32>,
}

/// Downloads `tracks`, each from its own provider. Ones already listed are left alone, and
/// failed ones try again. A track whose account cannot download is skipped, and the last such
/// refusal is answered once the rest are asked for.
pub fn download_tracks(tracks: Vec<TrackItem>) -> Result<()> {
    let core = core()?;
    let mut refused = Ok(());
    for track in tracks {
        let item = item(track);
        if let Err(error) = core.download(&item.source, vec![item.track]) {
            refused = Err(error);
        }
    }
    refused
}

/// A scrobbling service as its settings row shows it.
pub struct ScrobbleRow {
    pub id: String,
    /// What linking asks for: `keys` (an API key and secret, then approval), `token` or `server`.
    pub link: String,
    pub linked: bool,
    pub enabled: bool,
    /// The account's name on the service, once linked.
    pub user: String,
    /// Where the listener creates what linking asks for.
    pub signup: Option<String>,
}

/// What the listener typed to link a service; the fields its `link` does not use stay empty.
pub struct ScrobbleSecret {
    pub key: String,
    pub secret: String,
    pub token: String,
    pub server: String,
}

/// The scrobbling services offered, and whether local files are sent too.
pub fn scrobbling() -> Result<(Vec<ScrobbleRow>, bool)> {
    let saved = core()?.scrobbling();
    let rows = music::scrobble::services()
        .into_iter()
        .filter(|service| cauce_core::scrobbling::SHOWN.contains(&service.id()))
        .map(|service| {
            let account = saved
                .accounts
                .get(service.id())
                .cloned()
                .unwrap_or_default();
            ScrobbleRow {
                id: service.id().to_owned(),
                link: match service.link() {
                    music::scrobble::Link::Keys => "keys",
                    music::scrobble::Link::Browser => "browser",
                    music::scrobble::Link::Token => "token",
                    music::scrobble::Link::Server => "server",
                }
                .to_owned(),
                linked: account.linked(),
                enabled: account.enabled,
                user: account.name,
                signup: service.signup().map(str::to_owned),
            }
        })
        .collect();
    Ok((rows, saved.local_files))
}

fn secret(link: &str, typed: ScrobbleSecret) -> music::scrobble::Secret {
    use music::scrobble::Secret;
    match link {
        "keys" => Secret::Keys {
            key: typed.key,
            secret: typed.secret,
        },
        "token" => Secret::Token(typed.token),
        "server" => Secret::Server {
            url: typed.server,
            key: typed.key,
        },
        _ => Secret::None,
    }
}

/// The page where the listener approves linking `service`, for the app to show.
pub fn scrobble_approval(
    service: String,
    link: String,
    typed: ScrobbleSecret,
) -> Result<Option<String>> {
    Ok(core()?.scrobble_approval(&service, &secret(&link, typed)))
}

/// Links `service`; one that needs approval waits for it, up to five minutes.
pub fn scrobble_connect(service: String, link: String, typed: ScrobbleSecret) -> Result<()> {
    core()?.scrobble_connect(&service, secret(&link, typed))
}

pub fn scrobble_cancel() -> Result<()> {
    core()?.scrobble_cancel();
    Ok(())
}

pub fn scrobble_disconnect(service: String) -> Result<()> {
    core()?.scrobble_disconnect(&service);
    Ok(())
}

pub fn scrobble_enable(service: String, enabled: bool) -> Result<()> {
    core()?.scrobble_enable(&service, enabled);
    Ok(())
}

pub fn scrobble_local_files(on: bool) -> Result<()> {
    core()?.scrobble_local_files(on);
    Ok(())
}

/// Tells the scrobbling accounts `track` started.
pub fn scrobble_now_playing(track: TrackItem) -> Result<()> {
    core()?.scrobble_now_playing(&item(track));
    Ok(())
}

/// Sends a finished listen of `track` that started `started_secs` after the epoch.
pub fn scrobble(track: TrackItem, started_secs: u64) -> Result<()> {
    let at = std::time::UNIX_EPOCH + Duration::from_secs(started_secs);
    core()?.scrobble(&item(track), at);
    Ok(())
}

/// Finds lyrics for a downloaded `track` and keeps them for offline, answering whether any were
/// found.
pub fn keep_lyrics(track: TrackItem, sources: Vec<String>) -> Result<bool> {
    core()?.keep_lyrics(&item(track), &sources)
}

/// Downloads the `tracks` not listed yet, as keeping likes downloaded does. Failed ones wait to
/// be asked for by hand.
pub fn download_missing(tracks: Vec<TrackItem>) -> Result<()> {
    let core = core()?;
    let mut refused = Ok(());
    for track in tracks {
        let item = item(track);
        if let Err(error) = core.download_missing(&item.source, vec![item.track]) {
            refused = Err(error);
        }
    }
    refused
}

/// An album or playlist kept downloaded.
pub struct KeptCollection {
    pub slug: String,
    pub kind: CardKind,
    pub id: String,
}

/// Keeps an album or playlist downloaded with the `tracks` it has now, downloading those not
/// listed yet. Asked again whenever it opens.
pub fn keep_collection(
    slug: String,
    kind: CardKind,
    id: String,
    tracks: Vec<TrackItem>,
) -> Result<()> {
    let tracks = tracks.into_iter().map(|track| item(track).track).collect();
    core()?.keep_collection(&slug, matches!(kind, CardKind::Album), &id, tracks)
}

/// Stops keeping it downloaded; what is downloaded stays.
pub fn unkeep_collection(slug: String, kind: CardKind, id: String) -> Result<()> {
    core()?.unkeep_collection(&slug, matches!(kind, CardKind::Album), &id);
    Ok(())
}

pub fn kept_collections() -> Result<Vec<KeptCollection>> {
    Ok(core()?
        .kept_collections()
        .into_iter()
        .map(|kept| KeptCollection {
            slug: kept.source,
            kind: if kept.album {
                CardKind::Album
            } else {
                CardKind::Playlist
            },
            id: kept.id,
        })
        .collect())
}

pub fn remove_download(source: String, id: String) -> Result<()> {
    core()?.remove_download(&source, &id);
    Ok(())
}

/// Every listed download, oldest first. Screens ask again while any is unfinished.
pub fn downloads() -> Result<Vec<DownloadItem>> {
    Ok(core()?
        .downloads()
        .into_iter()
        .filter_map(|download| {
            Some(DownloadItem {
                track: track_item(&download.source, &download.track)?,
                state: match download.state {
                    cauce_core::downloads::State::Queued => DownloadState::Queued,
                    cauce_core::downloads::State::Running => DownloadState::Running,
                    cauce_core::downloads::State::Done => DownloadState::Done,
                    cauce_core::downloads::State::Failed => DownloadState::Failed,
                },
                progress: download.progress,
            })
        })
        .collect())
}

/// What a level streams as, the way a listener reads it.
fn encoding(encoding: music::Encoding) -> String {
    use music::Encoding;
    match encoding {
        Encoding::Flac { depth, rate } => {
            format!("FLAC {depth}-bit / {:.1} kHz", rate as f64 / 1000.)
        }
        Encoding::Alac { depth } => format!("ALAC {depth}-bit"),
        Encoding::Pcm { depth } => format!("PCM {depth}-bit"),
        Encoding::Aac { kbps } => format!("AAC {kbps} kbps"),
        Encoding::Vorbis { kbps } => format!("Ogg Vorbis {kbps} kbps"),
        Encoding::Mp3 { kbps } => format!("MP3 {kbps} kbps"),
        Encoding::Opus { kbps } => format!("Opus {kbps} kbps"),
        Encoding::Other => String::new(),
    }
}

pub fn play() -> Result<()> {
    core()?.play()
}

/// Words the page a sign-in's browser lands on, in the app's language.
pub fn set_return_page(title: String, line: String) {
    music::set_return_page(cauce_core::return_page(&title, &line));
}

/// A line from the platform side in Cauce's log, such as an audio route change.
pub fn note(message: String) {
    log::info!("ios: {message}");
}

/// Starts the audio output over, after another app took the audio. The next play loads the
/// track where it was.
pub fn reopen_output() -> Result<()> {
    core()?.reopen_output();
    Ok(())
}

/// Whether the phone is on mobile data, as the platform reports it.
pub fn set_cellular(cellular: bool) -> Result<()> {
    core()?.set_cellular(cellular);
    Ok(())
}

/// Whether the app stays off the network: the phone has none, or offline mode is on.
pub fn set_offline(offline: bool) -> Result<()> {
    core()?.set_offline(offline);
    Ok(())
}

/// Rest once the current track ends, or not, as a sleep timer at the end of a track does.
pub fn set_stop_after_current(stop: bool) -> Result<()> {
    core()?.set_stop_after_current(stop);
    Ok(())
}

pub fn pause() -> Result<()> {
    core()?.pause();
    Ok(())
}

/// A command for the system's player, which plays Apple Music on iOS. `kind` is `load`, `cue`
/// (load and stay paused), `play`, `pause`, `seek` or `stop`; `id` and `at_ms` are empty and zero
/// where the kind needs neither.
pub struct NativeCommand {
    pub kind: String,
    pub id: String,
    pub at_ms: u32,
}

/// Every command for the system's player from now on.
pub fn native_commands(commands: StreamSink<NativeCommand>) {
    cauce_core::native::on_command(move |command| {
        commands.add(native_command(command)).ok();
    });
}

fn native_command(command: cauce_core::native::Command) -> NativeCommand {
    use cauce_core::native::Command;
    let millis = |at: Duration| at.as_millis().min(u32::MAX as u128) as u32;
    let (kind, id, at_ms) = match command {
        Command::Load { id, at, play } => (if play { "load" } else { "cue" }, id, millis(at)),
        Command::Play => ("play", String::new(), 0),
        Command::Pause => ("pause", String::new(), 0),
        Command::Seek(at) => ("seek", String::new(), millis(at)),
        Command::Stop => ("stop", String::new(), 0),
    };
    NativeCommand {
        kind: kind.to_owned(),
        id,
        at_ms,
    }
}

/// What the system's player did with track `id`: `loading`, `playing`, `paused`, `position`,
/// `seeked`, `length` (with `duration_ms`), `ended` or `unavailable`.
#[flutter_rust_bridge::frb(sync)]
pub fn native_event(kind: String, id: String, at_ms: u32, duration_ms: u32) {
    cauce_core::native::event(&kind, id, at_ms.into(), duration_ms.into());
}

/// How loud the left and right channels are now, each 0 to 1; read about 30 times a second
/// while a design that draws them is on screen.
#[flutter_rust_bridge::frb(sync)]
pub fn levels() -> Vec<f32> {
    core()
        .map(|core| core.levels().to_vec())
        .unwrap_or_else(|_| vec![0.0, 0.0])
}

pub fn seek(millis: u64) -> Result<()> {
    core()?.seek(Duration::from_millis(millis));
    Ok(())
}

/// Moves a queued track from `from` to `to`.
pub fn move_queued(from: u32, to: u32) -> Result<()> {
    core()?.move_queued(from as usize, to as usize);
    Ok(())
}

/// Mixes what is still to play.
pub fn shuffle_upcoming() -> Result<()> {
    core()?.shuffle_upcoming();
    Ok(())
}

/// Takes the queued track at `index` out; the one playing stays.
pub fn remove_queued(index: u32) -> Result<()> {
    core()?.remove_queued(index as usize);
    Ok(())
}

/// Queues `tracks` right after the current one, or plays them when nothing is playing.
pub fn play_next(tracks: Vec<TrackItem>) -> Result<()> {
    core()?.play_next(tracks.into_iter().map(item).collect())
}

/// Queues `tracks` at the end, or plays them when nothing is playing.
pub fn add_to_queue(tracks: Vec<TrackItem>) -> Result<()> {
    core()?.add_to_queue(tracks.into_iter().map(item).collect())
}

/// Writes what is playing and where, for an app going to the background.
pub fn save_session() -> Result<()> {
    core()?.save_session();
    Ok(())
}

/// Drops what is still to play.
pub fn clear_upcoming() -> Result<()> {
    core()?.clear_upcoming();
    Ok(())
}

fn snapshot(state: PlayerState) -> PlayerSnapshot {
    let transport = state.transport;
    let draw = |item: &Item| track_item(&item.source, &item.track);
    PlayerSnapshot {
        track: transport.item.as_ref().and_then(draw),
        index: transport.index.map(|index| index as u32),
        queue: transport.items.iter().filter_map(draw).collect(),
        status: match transport.status {
            Status::Idle => PlaybackStatus::Idle,
            Status::Loading => PlaybackStatus::Loading,
            Status::Playing => PlaybackStatus::Playing,
            Status::Paused => PlaybackStatus::Paused,
        },
        position_ms: transport.position.as_millis() as u64,
        duration_ms: transport.duration.as_millis() as u64,
        repeat: match transport.repeat {
            Repeat::Off => RepeatMode::Off,
            Repeat::All => RepeatMode::All,
            Repeat::One => RepeatMode::One,
        },
        quality: state.encoding.and_then(quality),
        stops_after_current: transport.stop_after_current,
        stalled: transport.stalled,
    }
}

/// An encoding as the player shows it.
fn quality(encoding: Encoding) -> Option<String> {
    Some(match encoding {
        Encoding::Flac { depth, rate } => format!("FLAC · {depth}/{}", rate as f32 / 1000.0),
        Encoding::Alac { depth } => format!("ALAC · {depth} bit"),
        Encoding::Pcm { depth } => format!("PCM · {depth} bit"),
        Encoding::Aac { kbps } => format!("AAC · {kbps} kbps"),
        Encoding::Vorbis { kbps } => format!("Vorbis · {kbps} kbps"),
        Encoding::Mp3 { kbps } => format!("MP3 · {kbps} kbps"),
        Encoding::Opus { kbps } => format!("Opus · {kbps} kbps"),
        Encoding::Other => return None,
    })
}

fn track_item(source: &str, track: &Track) -> Option<TrackItem> {
    Some(TrackItem {
        source: source.to_owned(),
        id: track.id.clone()?,
        title: track.name.clone(),
        artists: track.artists.clone(),
        album: track.album.clone(),
        cover: track.cover.clone(),
        cover_large: track.cover.as_deref().map(cauce_core::artwork::large),
        duration_ms: track.duration.as_millis() as u64,
        playable: track.playable,
        album_id: track.album_id.clone(),
        artist_links: track
            .artist_refs
            .iter()
            .filter_map(|artist| {
                Some(ArtistLink {
                    id: artist.id.clone()?,
                    name: artist.name.clone(),
                })
            })
            .collect(),
    })
}

/// A line's word timings laid over its own text; empty when the words do not fit the line.
fn karaoke(text: &str, words: &[music::LyricsWord]) -> Vec<LyricWord> {
    let millis = |duration: Duration| duration.as_millis() as u64;
    let texts: Vec<&str> = words.iter().map(|word| word.text.as_str()).collect();
    cauce_core::karaoke::fit(text, &texts)
        .unwrap_or_default()
        .into_iter()
        .map(|piece| LyricWord {
            start_ms: millis(words[piece.index].start),
            end_ms: millis(words[piece.index].end),
            text: piece.text,
        })
        .collect()
}

fn shelves(slug: &str, feed: HomeFeed) -> Vec<HomeShelf> {
    let mut shelves = Vec::new();
    if let Some(picks) = feed.quick_picks.filter(|picks| !picks.is_empty()) {
        shelves.push(HomeShelf {
            title: "Quick picks".to_owned(),
            cards: picks
                .iter()
                .filter_map(|track| card(slug, GenreItem::Track(track.clone())))
                .collect(),
        });
    }
    if !feed.listen_again.is_empty() {
        shelves.push(HomeShelf {
            title: "Listen again".to_owned(),
            cards: feed
                .listen_again
                .into_iter()
                .filter_map(|item| card(slug, item))
                .collect(),
        });
    }
    shelves.extend(feed.sections.into_iter().map(|section| {
        HomeShelf {
            title: section.title,
            cards: section
                .items
                .into_iter()
                .filter_map(|item| card(slug, item))
                .collect(),
        }
    }));
    shelves.retain(|shelf| !shelf.cards.is_empty());
    shelves
}

/// A shelf item as a card. Genres open a page of their own, which the app has none of yet.
fn card(slug: &str, item: GenreItem) -> Option<MediaCard> {
    Some(match item {
        GenreItem::Track(track) => {
            let drawn = track_item(slug, &track)?;
            MediaCard {
                kind: CardKind::Track,
                id: drawn.id.clone(),
                title: drawn.title.clone(),
                subtitle: drawn.artists.clone(),
                cover: drawn.cover.clone(),
                track: Some(drawn),
            }
        }
        GenreItem::Album(album) => MediaCard {
            kind: CardKind::Album,
            id: album.id,
            title: album.name,
            subtitle: album.artists,
            cover: album.cover_large.or(album.cover),
            track: None,
        },
        GenreItem::Playlist(playlist) => MediaCard {
            kind: CardKind::Playlist,
            id: playlist.id,
            title: playlist.name,
            subtitle: playlist.owner,
            cover: playlist.cover,
            track: None,
        },
        GenreItem::Artist(artist) => MediaCard {
            kind: CardKind::Artist,
            id: artist.id,
            title: artist.name,
            subtitle: "Artist".to_owned(),
            cover: artist.cover,
            track: None,
        },
        GenreItem::Genre(_) => return None,
    })
}

/// A drawn track back as a queue item. Only the fields a screen carries survive the trip, which
/// is all the engine and the player screen read.
fn item(track: TrackItem) -> Item {
    Item {
        source: track.source,
        id: track.id.clone(),
        track: Track {
            id: Some(track.id),
            name: track.title,
            playable: track.playable,
            artists: track.artists,
            artist_refs: track
                .artist_links
                .into_iter()
                .map(|artist| music::ArtistRef {
                    name: artist.name,
                    id: Some(artist.id),
                })
                .collect(),
            album: track.album,
            album_id: track.album_id,
            cover: track.cover,
            duration: Duration::from_millis(track.duration_ms),
            added_at: None,
            added_by: None,
            playcount: None,
            popularity: 0,
            explicit: false,
            track_number: 0,
            disc_number: 0,
            tags: Vec::new(),
            languages: Vec::new(),
            credits: Vec::new(),
        },
    }
}

fn core() -> Result<&'static Core> {
    CORE.get().context("the core has not started")
}

#[flutter_rust_bridge::frb(init)]
pub fn init_app() {
    // Not `setup_default_user_utils`: its console logger would take the one global logger slot
    // the core's log file needs.
    flutter_rust_bridge::setup_backtrace();
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn qualities_read_as_the_player_shows_them() {
        assert_eq!(
            quality(Encoding::Aac { kbps: 256 }).as_deref(),
            Some("AAC · 256 kbps")
        );
        assert_eq!(
            quality(Encoding::Flac {
                depth: 24,
                rate: 96_000
            })
            .as_deref(),
            Some("FLAC · 24/96")
        );
        assert_eq!(
            quality(Encoding::Flac {
                depth: 16,
                rate: 44_100
            })
            .as_deref(),
            Some("FLAC · 16/44.1")
        );
        assert_eq!(quality(Encoding::Other), None);
    }
}
