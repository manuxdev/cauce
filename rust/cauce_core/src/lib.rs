//! The core of Cauce: the vendored `music` and `storage` crates, driven without a window.

pub mod artwork;
pub mod cookies;
pub mod downloads;
pub mod genres;
pub mod home;
pub mod karaoke;
pub mod levels;
pub mod logging;
pub mod lyrics_shelf;
pub mod native;
pub mod queue;
pub mod radio;
pub mod scrobbling;
pub mod session;
pub mod settings;
mod stand_in;
pub mod transport;

use std::collections::HashMap;
use std::future::Future;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::time::Duration;

use anyhow::{Context as _, Result};
use downloads::{Downloads, State};
use music::equalizer::{Edit, EqualizerWriter};
use music::jellyfin::quick_connect;
use music::plex;
use music::local::LocalProvider;
use music::vault::Vault;
use music::{
    Analyzer, Artist, Capabilities, Fraction, GenreDetail, GenreItem, GenreSection, HomeFeed,
    Lyrics, LyricsProvider, LyricsQuery, MediaKind, MusicApi, MusicProvider, PlaybackConfig,
    PlaybackFactory, Player, SignIn, SignInPrompt, Track, TrackKey, WebSignIn,
};
use music::{Encoding, Meter, Offer, PlaybackEvent, Quality, Transcode};
use settings::PlaybackSettings;
use tokio::runtime::{Handle, Runtime};

pub use cookies::Cookie;
pub use queue::Repeat;
pub use transport::{Item, Snapshot, Status};

use transport::{Command, Transport};

/// How often the engine reports the position. Enough for a seek bar, rare enough for a battery.
const POSITION_INTERVAL: Duration = Duration::from_millis(500);
/// How long one lyrics service may take before its answer is given up on.
const LYRICS_TIMEOUT: Duration = Duration::from_secs(8);
/// The source a file on disk plays through.
pub const LOCAL: &str = "local";

/// Where the app keeps its files. The host passes its own sandbox folders, since upstream's
/// desktop defaults mean nothing on a phone.
pub struct Paths {
    pub data: PathBuf,
    pub cache: PathBuf,
}

/// Everything a player screen draws.
#[derive(Clone, Debug, PartialEq)]
pub struct PlayerState {
    pub transport: Snapshot,
    /// How the current track's stream is encoded, once its engine has said.
    pub encoding: Option<Encoding>,
    /// The song a live station says it is playing, when its stream sends titles.
    pub now_playing: Option<String>,
}

type StateSink = Arc<dyn Fn(PlayerState) + Send + Sync>;

/// A provider with an account in, and the engine factory its tracks play through.
struct Connected {
    api: Arc<dyn MusicApi>,
    playback: Arc<dyn PlaybackFactory>,
    capabilities: Capabilities,
}

/// The one engine running now, and whose tracks it plays.
struct Engine {
    source: String,
    /// What it streams at; a track wanting another level gets a new engine.
    quality: Quality,
    player: Box<dyn Player>,
}

/// A prefetch running on an engine, which stops when dropped.
type Fetching = std::pin::Pin<Box<dyn Future<Output = Result<()>> + Send>>;

/// What the runtime's tasks share with the core.
struct Inner {
    runtime: Handle,
    local: LocalProvider,
    /// The station catalog, and the engine factory stations play through.
    radio: music::radio::RadioBrowser,
    stations: Arc<music::radio::playback::Factory>,
    favourites: Mutex<radio::Favourites>,
    providers: Vec<Arc<dyn MusicProvider>>,
    lyrics: Vec<Arc<dyn LyricsProvider>>,
    /// Lyrics kept for downloaded tracks.
    shelf: lyrics_shelf::Shelf,
    scrobbling: Mutex<scrobbling::Scrobbling>,
    /// The scrobbling link waiting for the listener's approval, to give up on.
    linking: Mutex<Option<tokio::task::AbortHandle>>,
    plex: Mutex<PlexSignIn>,
    sessions: Mutex<HashMap<String, Connected>>,
    /// The input of each sign-in waiting on the listener; dropping it cancels that sign-in.
    signing: Mutex<HashMap<String, tokio::sync::mpsc::UnboundedSender<String>>>,
    /// Engine factories built from a stored account before it was reached, so its downloads
    /// play offline. A session that connects later takes over.
    offline: Mutex<HashMap<String, Arc<dyn PlaybackFactory>>>,
    transport: Mutex<Transport>,
    /// When the queue and position are next worth writing to the session file.
    saver: Mutex<session::Saver>,
    engine: Mutex<Option<Engine>>,
    /// How each recently started track is encoded, by id.
    encodings: Mutex<HashMap<String, Encoding>>,
    /// Whether the phone is on mobile data, as the host last said.
    cellular: AtomicBool,
    /// Where the settings file lives.
    data: PathBuf,
    settings: Mutex<PlaybackSettings>,
    /// Feeds every engine's equalizer, so a change is heard without a restart.
    equalizer: Mutex<EqualizerWriter>,
    vault: Arc<Vault>,
    /// For the public APIs a provider does not cover, such as Deezer's genres.
    http: reqwest::Client,
    downloads: Mutex<Downloads>,
    /// How far each running download has got.
    fractions: Mutex<HashMap<(String, String), Fraction>>,
    /// Engines started only to download, for a provider other than the one playing. They go once
    /// nothing is left to download.
    downloaders: Mutex<HashMap<String, Box<dyn Player>>>,
    /// The round fetching upcoming tracks into the cache, to stop when the queue moves on.
    prefetching: Mutex<Option<tokio::task::AbortHandle>>,
    on_change: StateSink,
}

/// A plex.tv sign-in under way: the PIN waiting for the listener's approval, then the account
/// token it carried, held here only until a server is picked. Neither is ever stored or logged,
/// and neither leaves the core.
#[derive(Default)]
struct PlexSignIn {
    pin: Option<plex::pin::Pin>,
    token: Option<String>,
}

/// Where a plex.tv sign-in stands.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PlexPin {
    Waiting,
    /// The account is in reach: its servers can be listed.
    Approved,
    /// plex.tv no longer knows the PIN.
    Expired,
}

/// One listed download as a screen draws it.
#[derive(Clone, Debug)]
pub struct Download {
    pub source: String,
    pub track: Track,
    pub state: State,
    /// From 0 to 1 while it runs, once the player can tell.
    pub progress: Option<f32>,
}

/// One running core: the runtime every network and engine task lives on, the providers, the
/// queue and the player.
pub struct Core {
    runtime: Runtime,
    inner: Arc<Inner>,
}

impl Core {
    /// Starts the runtime. `on_change` hears the player's state whenever it changes, on a
    /// runtime thread.
    pub fn start(
        paths: Paths,
        on_change: impl Fn(PlayerState) + Send + Sync + 'static,
    ) -> Result<Self> {
        music::set_return_page(return_page(
            "Connected",
            "You can go back to Cauce. This page closes by itself.",
        ));
        trust_roots(&paths.cache);
        log_panics();
        #[cfg(target_os = "android")]
        app_dirs(&paths);
        // librespot, oauth2 and ytmusic ask rustls for ring, reqwest for aws-lc-rs, and rustls
        // refuses to guess. A second install only means another crate got there first.
        rustls::crypto::ring::default_provider()
            .install_default()
            .ok();
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .thread_name("cauce-io")
            .enable_all()
            .build()
            .context("cannot start the runtime")?;
        std::fs::create_dir_all(&paths.cache).ok();
        logging::init(&paths.cache);
        log::info!("cauce: core started");
        let database = storage::Database::at(paths.data.join("state.sqlite"));
        let cache = storage::Cache::at(paths.cache.join("cache.sqlite"));
        let providers: Vec<Arc<dyn MusicProvider>> = vec![
            Arc::new(music::deezer::DeezerProvider::new()),
            Arc::new(music::youtube::YouTubeProvider::new()),
            // A free account is kept to browse; its songs play from another service.
            Arc::new(music::spotify::SpotifyProvider::new(
                music::spotify::AuthConfig {
                    allow_free: true,
                    ..music::spotify::AuthConfig::default()
                },
            )),
            Arc::new(music::tidal::TidalProvider::new()),
            Arc::new(music::subsonic::SubsonicProvider::new()),
            Arc::new(music::jellyfin::JellyfinProvider::new()),
            Arc::new(music::jellyfin::JellyfinProvider::emby()),
            Arc::new(music::plex::PlexProvider::new()),
            // Apple Music is mobile only: on iOS its songs play through the system's player, on
            // Android its license comes from the system's MediaDrm.
            #[cfg(any(target_os = "ios", target_os = "android"))]
            Arc::new(music::apple::AppleProvider::new()),
        ];
        let lyrics: Vec<Arc<dyn LyricsProvider>> = vec![
            Arc::new(music::local::LocalLyrics),
            Arc::new(music::youtube::YouTubeLyrics::new()),
            Arc::new(music::binimum::Binimum::new()),
            Arc::new(music::musixmatch::Musixmatch::new()),
            Arc::new(music::subsonic::SubsonicLyrics::new()),
            Arc::new(music::jellyfin::JellyfinLyrics::new()),
            Arc::new(music::jellyfin::JellyfinLyrics::emby()),
            Arc::new(music::lrclib::LrcLib::new()),
            Arc::new(music::kugou::Kugou::new()),
            Arc::new(music::netease::NetEase::new()),
        ];
        let settings = PlaybackSettings::load(&paths.data);
        let vault = Arc::new(Vault::new(
            paths.cache.join("vault"),
            paths.data.join("downloads"),
            settings.cache_bytes(),
        ));
        vault.set_caching(settings.keep_tracks);
        match vault_key(&paths.data) {
            Ok(key) => vault.unlock(&key),
            Err(error) => {
                log::warn!("vault: no key, tracks are not kept: {error:#}");
                vault.stay_locked();
            }
        }
        let equalizer = EqualizerWriter::new(settings.equalizer, settings.curve());
        let data = paths.data.clone();
        let data_folder = paths.data.clone();
        TIDAL_PREVIEWS.store(
            data_folder.join(TIDAL_PREVIEWS_FILE).exists(),
            Ordering::Relaxed,
        );
        let radio_browser = music::radio::RadioBrowser::new();
        let inner = Arc::new(Inner {
            runtime: runtime.handle().clone(),
            local: LocalProvider::new(paths.cache, database, cache),
            radio: radio_browser.clone(),
            stations: Arc::new(music::radio::playback::Factory::new(radio_browser)),
            favourites: Mutex::new(radio::Favourites::load(&data_folder)),
            providers,
            lyrics,
            shelf: lyrics_shelf::Shelf::at(data_folder.join("lyrics")),
            scrobbling: Mutex::new(scrobbling::Scrobbling::load(&data_folder)),
            linking: Mutex::default(),
            plex: Mutex::default(),
            sessions: Mutex::default(),
            signing: Mutex::default(),
            offline: Mutex::default(),
            transport: Mutex::new(resumed_transport(&paths.data, &settings)),
            saver: Mutex::default(),
            engine: Mutex::default(),
            encodings: Mutex::default(),
            cellular: AtomicBool::new(false),
            data,
            settings: Mutex::new(settings),
            equalizer: Mutex::new(equalizer),
            vault,
            http: reqwest::Client::new(),
            downloads: Mutex::new(Downloads::load(&data_folder)),
            fractions: Mutex::default(),
            downloaders: Mutex::default(),
            prefetching: Mutex::default(),
            on_change: Arc::new(on_change),
        });
        let freeing = inner.clone();
        inner.runtime.spawn_blocking(move || freeing.free_up());
        Ok(Self { runtime, inner })
    }

    /// How a provider signs in through a webview, or `None` when it has no cookie sign-in.
    pub fn web_sign_in(&self, slug: &str) -> Result<Option<WebSignIn>> {
        Ok(self.inner.provider(slug)?.web_sign_in())
    }

    /// Brings back the account a provider stored. Answers its display name, or `None` when there
    /// is no usable account.
    pub fn restore(&self, slug: &str) -> Result<Option<String>> {
        reachable(self.inner.vault.offline())?;
        let provider = self.inner.provider(slug)?;
        let restored = self.run(async move { provider.restore().await });
        match &restored {
            Ok(Some(_)) => log::info!("session: {slug} restored"),
            Ok(None) => log::info!("session: {slug} has no usable stored account"),
            Err(error) => log::warn!("session: cannot restore {slug}: {error:#}"),
        }
        let Some(session) = restored? else {
            return Ok(None);
        };
        let name = session.profile.display_name.clone();
        self.inner
            .connect(slug, session.api, session.playback, session.capabilities);
        Ok(Some(name))
    }

    /// Signs in with what the webview holds. Answers `None` while the cookies prove no session
    /// yet, so the host keeps polling, and the account's display name once signed in.
    pub fn sign_in_with_cookies(&self, slug: &str, cookies: &[Cookie]) -> Result<Option<String>> {
        reachable(self.inner.vault.offline())?;
        let provider = self.inner.provider(slug)?;
        let web = provider
            .web_sign_in()
            .context("this provider has no cookie sign-in")?;
        let Some(header) = cookies::signed_in_header(cookies, web.domain, web.proof) else {
            // Names and domains only: the values are credentials.
            let seen: Vec<String> = cookies
                .iter()
                .filter(|cookie| cookie.domain.contains(web.domain))
                .map(|cookie| {
                    format!(
                        "{}@{}{}",
                        cookie.name,
                        cookie.domain,
                        if cookie.value.is_empty() {
                            "(empty)"
                        } else {
                            ""
                        }
                    )
                })
                .collect();
            log::debug!(
                "session: {slug} not signed in yet, {} cookies, for {}: {seen:?}",
                cookies.len(),
                web.domain
            );
            return Ok(None);
        };
        log::info!("session: {slug} cookies prove a session, signing in");
        let (input, receiver) = tokio::sync::mpsc::unbounded_channel();
        input.send(header).ok();
        let started = std::time::Instant::now();
        let session = self.run(async move {
            provider
                .sign_in(SignIn::Secret, Arc::new(|_| {}), receiver)
                .await
        });
        match &session {
            Ok(_) => log::info!("session: {slug} signed in after {:?}", started.elapsed()),
            Err(error) => log::warn!(
                "session: {slug} sign-in failed after {:?}: {error:#}",
                started.elapsed()
            ),
        }
        let session = session?;
        let name = session.profile.display_name.clone();
        self.inner
            .connect(slug, session.api, session.playback, session.capabilities);
        Ok(Some(name))
    }

    /// Signs in with `method`, handing every prompt (a code to type, a page to approve on) to
    /// `on_prompt`. Blocks until the account is in, and answers its display name.
    pub fn sign_in(
        &self,
        slug: &str,
        method: SignIn,
        on_prompt: impl Fn(SignInPrompt) + Send + Sync + 'static,
    ) -> Result<String> {
        reachable(self.inner.vault.offline())?;
        let provider = self.inner.provider(slug)?;
        let (input, receiver) = tokio::sync::mpsc::unbounded_channel();
        lock(&self.inner.signing).insert(slug.to_owned(), input);
        let session = self.run(async move {
            provider
                .sign_in(method, Arc::new(on_prompt), receiver)
                .await
        });
        lock(&self.inner.signing).remove(slug);
        match &session {
            Ok(_) => log::info!("session: {slug} signed in"),
            Err(error) => log::warn!("session: {slug} sign-in failed: {error:#}"),
        }
        let session = session?;
        let name = session.profile.display_name.clone();
        self.inner
            .connect(slug, session.api, session.playback, session.capabilities);
        Ok(name)
    }

    /// Gives up on the sign-in `slug` is waiting on.
    pub fn sign_in_cancel(&self, slug: &str) -> Result<()> {
        lock(&self.inner.signing).remove(slug);
        self.inner.provider(slug)?.abandon();
        Ok(())
    }

    /// Whether the Jellyfin server at `server` offers Quick Connect.
    pub fn quick_connect_enabled(&self, server: String) -> Result<bool> {
        reachable(self.inner.vault.offline())?;
        self.run(async move { quick_connect::enabled(&server).await })
    }

    /// A Quick Connect code for the listener to authorize on a device already signed in.
    pub fn quick_connect_start(&self, server: String) -> Result<quick_connect::Code> {
        reachable(self.inner.vault.offline())?;
        self.run(async move { quick_connect::initiate(&server).await })
    }

    /// Where the Quick Connect code with `secret` stands. Once authorized, signing in with
    /// [`SignIn::QuickConnect`] trades it for the account.
    pub fn quick_connect_check(&self, server: String, secret: String) -> Result<quick_connect::Check> {
        reachable(self.inner.vault.offline())?;
        self.run(async move { quick_connect::check(&server, &secret).await })
    }

    /// Starts a plex.tv sign-in, and answers the page where the listener approves it.
    pub fn plex_start(&self) -> Result<String> {
        reachable(self.inner.vault.offline())?;
        let client_id = plex::auth::client_id();
        let asked = client_id.clone();
        let pin = self.run(async move { plex::pin::create(&asked).await })?;
        let page = plex::pin::approval_url(&client_id, &pin);
        *lock(&self.inner.plex) = PlexSignIn {
            pin: Some(pin),
            token: None,
        };
        Ok(page)
    }

    /// Where the plex.tv sign-in under way stands. Once approved, the account token stays in
    /// the core for [`Self::plex_servers`] and [`Self::plex_sign_in`].
    pub fn plex_check(&self) -> Result<PlexPin> {
        reachable(self.inner.vault.offline())?;
        let pin = lock(&self.inner.plex)
            .pin
            .clone()
            .context("no plex sign-in is under way")?;
        let client_id = plex::auth::client_id();
        let checked = self.run(async move { plex::pin::check(&client_id, &pin).await })?;
        let mut held = lock(&self.inner.plex);
        Ok(match checked {
            plex::pin::Check::Waiting => PlexPin::Waiting,
            plex::pin::Check::Approved(token) => {
                *held = PlexSignIn {
                    pin: None,
                    token: Some(token),
                };
                PlexPin::Approved
            }
            plex::pin::Check::Expired => {
                *held = PlexSignIn::default();
                PlexPin::Expired
            }
        })
    }

    /// The servers of the account the approved PIN signed in, its own first.
    pub fn plex_servers(&self) -> Result<Vec<plex::pin::Server>> {
        reachable(self.inner.vault.offline())?;
        let token = self.plex_token()?;
        let client_id = plex::auth::client_id();
        self.run(async move { plex::pin::servers(&client_id, &token).await })
    }

    /// Signs in to the account's server `server_id`, and answers the account's name. The account
    /// token is dropped once the server is in, and kept for another try until then.
    pub fn plex_sign_in(&self, server_id: String) -> Result<String> {
        let token = self.plex_token()?;
        let name = self.sign_in(
            plex::auth::SLUG,
            SignIn::Plex {
                token,
                server: server_id,
            },
            |_| {},
        )?;
        *lock(&self.inner.plex) = PlexSignIn::default();
        Ok(name)
    }

    /// Gives up the plex.tv sign-in under way, forgetting its PIN and token.
    pub fn plex_cancel(&self) {
        *lock(&self.inner.plex) = PlexSignIn::default();
    }

    fn plex_token(&self) -> Result<String> {
        lock(&self.inner.plex)
            .token
            .clone()
            .context("the plex sign-in is not approved")
    }

    pub fn sign_out(&self, slug: &str) -> Result<()> {
        self.inner.provider(slug)?.sign_out();
        lock(&self.inner.sessions).remove(slug);
        lock(&self.inner.offline).remove(slug);
        if slug == "tidal" {
            TIDAL_PREVIEWS.store(false, Ordering::Relaxed);
            std::fs::remove_file(self.inner.data.join(TIDAL_PREVIEWS_FILE)).ok();
        }
        // What was playing leaves the player rather than linger in it, unless it is downloaded and
        // so still plays from the vault.
        let playing = lock(&self.inner.transport).snapshot().item;
        if playing.is_some_and(|item| {
            item.source == slug && !lock(&self.inner.downloads).kept(&item.source, &item.id)
        }) {
            lock(&self.inner.transport).clear();
            *lock(&self.inner.engine) = None;
            session::Session::forget(&self.inner.data);
            self.inner.changed();
        }
        Ok(())
    }

    /// Whether `slug`'s account plays its own tracks. A free Spotify account only browses, and
    /// its songs play from another connected service. True for a provider not signed in.
    pub fn streams(&self, slug: &str) -> bool {
        self.inner.streams(slug)
    }

    /// Whether `slug` has an account stored, without reaching it.
    pub fn stored(&self, slug: &str) -> Result<bool> {
        Ok(self.inner.provider(slug)?.stored())
    }

    pub fn search(&self, slug: &str, query: String) -> Result<Vec<Track>> {
        let api = self.inner.api(slug)?;
        self.run(async move { api.search(&query).await })
    }

    /// The styles to browse the service by: Deezer's genres, YouTube Music's moods and genres.
    pub fn genres(&self, slug: &str) -> Result<Vec<music::Genre>> {
        if slug == "deezer" {
            let http = self.inner.http.clone();
            return self.run(async move { genres::genres(&http).await });
        }
        let api = self.inner.api(slug)?;
        self.run(async move { api.genres().await })
    }

    /// A style's shelves. `titles` names Deezer's chart shelves; YouTube names its own.
    pub fn genre(&self, slug: &str, id: String, titles: genres::Titles) -> Result<GenreDetail> {
        if slug == "deezer" {
            let http = self.inner.http.clone();
            return self.run(async move { genres::genre(&http, &id, &titles).await });
        }
        let api = self.inner.api(slug)?;
        self.run(async move { api.genre(&id).await })
    }

    pub fn search_albums(&self, slug: &str, query: String) -> Result<Vec<music::Album>> {
        let api = self.inner.api(slug)?;
        self.run(async move { api.search_albums(&query).await })
    }

    /// The playlists the account owns, which are the ones a track can go into.
    pub fn own_playlists(&self, slug: &str) -> Result<Vec<music::Playlist>> {
        let api = self.inner.api(slug)?;
        self.run(async move {
            let mut playlists = api.playlists().await?;
            playlists.retain(|playlist| playlist.owned || playlist.collaborative);
            Ok(playlists)
        })
    }

    /// Makes a playlist called `name` and answers its id.
    pub fn create_playlist(&self, slug: &str, name: String) -> Result<String> {
        let api = self.inner.api(slug)?;
        self.run(async move { api.create_playlist(&name).await })
    }

    pub fn add_to_playlist(&self, slug: &str, playlist_id: String, track_id: String) -> Result<()> {
        let api = self.inner.api(slug)?;
        self.run(async move { api.add_track_to_playlist(&playlist_id, &track_id).await })
    }

    /// Removes the `copy`-th entry of `track_id` (from 0) from the playlist.
    pub fn remove_from_playlist(&self, slug: &str, playlist_id: String, track_id: String, copy: usize) -> Result<()> {
        let api = self.inner.api(slug)?;
        self.run(async move { api.remove_track_from_playlist(&playlist_id, &track_id, copy).await })
    }

    pub fn rename_playlist(&self, slug: &str, playlist_id: String, name: String) -> Result<()> {
        let api = self.inner.api(slug)?;
        self.run(async move { api.rename_playlist(&playlist_id, &name).await })
    }

    pub fn delete_playlist(&self, slug: &str, playlist_id: String) -> Result<()> {
        let api = self.inner.api(slug)?;
        self.run(async move { api.delete_playlist(&playlist_id).await })
    }

    /// What the provider recommends: listen again, quick picks and its shelves.
    /// Falls back to the user's own library when the provider recommends nothing.
    pub fn home(&self, slug: &str) -> Result<HomeFeed> {
        let api = self.inner.api(slug)?;
        self.run(async move {
            let feed = api.home().await?;
            if !home::empty(&feed) {
                return Ok(feed);
            }
            let (saved, playlists, albums, artists) = tokio::join!(
                api.saved_tracks(),
                api.playlists(),
                api.saved_albums(),
                api.saved_artists(),
            );
            let saved = saved.unwrap_or_default();
            let seeds = home::seeds(&saved, 4);
            // One radio per seed: the first is quick picks, the rest are named mixes.
            let handles: Vec<_> = seeds
                .iter()
                .map(|seed| {
                    let api = api.clone();
                    let id = seed.id.clone().unwrap_or_default();
                    tokio::spawn(
                        async move { api.track_radio(&id, None).await.map(|(radio, _)| radio) },
                    )
                })
                .collect();
            let mut radios = Vec::with_capacity(handles.len());
            for handle in handles {
                radios.push(handle.await.ok().and_then(Result::ok).unwrap_or_default());
            }
            let mut radios = radios.into_iter();
            let quick = radios.next().unwrap_or_default();
            let mut recommended: Vec<GenreSection> = seeds
                .iter()
                .skip(1)
                .zip(radios)
                .map(|(seed, radio)| GenreSection {
                    title: format!("{} mix", lead_artist(seed)),
                    items: radio.into_iter().map(GenreItem::Track).collect(),
                })
                .collect();
            // Around the most recent favorite: artists like theirs and more of their records.
            if let Some(seed) = seeds.first()
                && let (Some(album), Some(artist)) =
                    (seed.album_id.as_deref(), seed.artist_refs[0].id.as_deref())
                && let Ok(catalogue) = api.album_catalogue(album, Some(artist)).await
            {
                let name = lead_artist(seed);
                recommended.insert(
                    0,
                    GenreSection {
                        title: format!("Because you like {name}"),
                        items: catalogue
                            .similar
                            .into_iter()
                            .map(GenreItem::Artist)
                            .collect(),
                    },
                );
                recommended.push(GenreSection {
                    title: format!("More from {name}"),
                    items: catalogue
                        .also_like
                        .into_iter()
                        .map(GenreItem::Album)
                        .collect(),
                });
            }
            Ok(home::from_library(
                quick,
                recommended,
                playlists.unwrap_or_default(),
                albums.unwrap_or_default(),
                artists.unwrap_or_default(),
            ))
        })
    }

    pub fn artist(&self, slug: &str, id: String) -> Result<Artist> {
        let api = self.inner.api(slug)?;
        self.run(async move { api.artist(&id).await })
    }

    /// The tracks the user starred on a provider.
    pub fn saved_tracks(&self, slug: &str) -> Result<Vec<Track>> {
        let api = self.inner.api(slug)?;
        self.run(async move { api.saved_tracks().await })
    }

    pub fn set_saved(&self, slug: &str, track_id: String, saved: bool) -> Result<()> {
        let api = self.inner.api(slug)?;
        self.run(async move { api.set_track_saved(&track_id, saved).await })
    }

    /// Stations matching `query`, most played first.
    pub fn radio_search(&self, query: music::radio::Query) -> Result<Vec<Item>> {
        reachable(self.inner.vault.offline())?;
        let radio = self.inner.radio.clone();
        let found = self.run(async move { radio.search(&query).await })?;
        Ok(found.iter().map(station_item).collect())
    }

    /// The most played stations.
    pub fn radio_top(&self, limit: u32) -> Result<Vec<Item>> {
        reachable(self.inner.vault.offline())?;
        let radio = self.inner.radio.clone();
        let found =
            self.run(async move { radio.top(music::radio::Order::Clicks, limit).await })?;
        Ok(found.iter().map(station_item).collect())
    }

    /// The countries, tags or languages stations can be browsed by.
    pub fn radio_facets(&self, kind: RadioFacets) -> Result<Vec<music::radio::Facet>> {
        reachable(self.inner.vault.offline())?;
        let radio = self.inner.radio.clone();
        self.run(async move {
            match kind {
                RadioFacets::Countries => radio.countries().await,
                RadioFacets::Tags => radio.tags().await,
                RadioFacets::Languages => radio.languages().await,
            }
        })
    }

    /// The favourite stations, newest first. They need no network to list.
    pub fn radio_favourites(&self) -> Vec<Item> {
        lock(&self.inner.favourites)
            .list()
            .iter()
            .map(radio::Favourite::item)
            .collect()
    }

    /// Keeps `item` as a favourite station, or stops keeping it. The station is taken from the
    /// queue when it is there, so a song title shown in its place is not what is kept.
    pub fn set_radio_favourite(&self, item: Item, on: bool) {
        let listed = lock(&self.inner.transport)
            .snapshot()
            .items
            .into_iter()
            .find(|queued| queued.source == item.source && queued.id == item.id);
        let favourite = radio::Favourite::of(listed.as_ref().unwrap_or(&item));
        let mut favourites = lock(&self.inner.favourites);
        favourites.set(favourite, on);
        favourites.save(&self.inner.data);
    }

    /// The tracks of an album or a playlist.
    pub fn collection_tracks(&self, slug: &str, kind: MediaKind, id: String) -> Result<Vec<Track>> {
        let api = self.inner.api(slug)?;
        self.run(async move {
            match kind {
                MediaKind::Album => api.album_tracks(&id).await,
                MediaKind::Playlist => api.playlist_tracks(&id).await,
                MediaKind::Artist => Ok(api.artist(&id).await?.top_tracks),
                MediaKind::Track => Ok(vec![api.track(&id).await?]),
            }
        })
    }

    /// The best lyrics for `item`: the ones kept with its download, or the best every lyrics
    /// service in the source `groups` together has, word-timed over line-timed over plain, then
    /// in the order of the `groups`. `None` when no service knows the track or no group is given.
    pub fn lyrics(&self, item: &Item, groups: &[String]) -> Result<Option<Lyrics>> {
        if let Some(kept) = self.inner.shelf.get(&item.source, &item.id) {
            return Ok(Some(kept));
        }
        self.search_lyrics(item, groups)
    }

    /// Finds lyrics for a downloaded `item` and keeps them, so they show offline. Answers
    /// whether any were found.
    pub fn keep_lyrics(&self, item: &Item, groups: &[String]) -> Result<bool> {
        let Some(lyrics) = self.search_lyrics(item, groups)? else {
            return Ok(false);
        };
        self.inner.shelf.keep(&item.source, &item.id, &lyrics);
        Ok(true)
    }

    fn search_lyrics(&self, item: &Item, groups: &[String]) -> Result<Option<Lyrics>> {
        let priority = lyrics_shelf::sources(groups);
        let provider = self
            .inner
            .providers
            .iter()
            .find(|provider| provider.slug() == item.source)
            .map(|provider| provider.slug());
        let query = LyricsQuery {
            title: item.track.name.clone(),
            artist: item.track.artists.clone(),
            album: Some(item.track.album.clone()).filter(|album| !album.is_empty()),
            duration: item.track.duration,
            track: provider.map(|provider| TrackKey {
                provider,
                id: item.id.clone(),
            }),
        };
        // Only the services in the groups given are asked: a group left out is turned off.
        // Offline, only the files beside a track are.
        let offline = self.inner.vault.offline();
        let services: Vec<_> = self
            .inner
            .lyrics
            .iter()
            .filter(|service| priority.iter().any(|name| name == service.name()))
            .filter(|service| !offline || service.name() == music::lyrics::LOCAL)
            .cloned()
            .collect();
        self.run(async move {
            let mut tasks = tokio::task::JoinSet::new();
            for service in services {
                let query = query.clone();
                tasks.spawn(async move {
                    let found = tokio::time::timeout(LYRICS_TIMEOUT, service.search(&query)).await;
                    match found {
                        Ok(Ok(hits)) => hits
                            .into_iter()
                            .filter(|hit| music::lyrics::matched(&query, hit))
                            .collect(),
                        Ok(Err(error)) => {
                            log::debug!("lyrics: {} did not answer: {error:#}", service.name());
                            Vec::new()
                        }
                        Err(_) => Vec::new(),
                    }
                });
            }
            let mut hits = Vec::new();
            while let Some(found) = tasks.join_next().await {
                hits.extend(found.unwrap_or_default());
            }
            Ok(lyrics_shelf::pick(&query, hits, &priority))
        })
    }

    /// A file on disk as a queue item.
    pub fn file_item(&self, path: PathBuf) -> Result<Item> {
        let track = self
            .inner
            .local
            .track_from_path(&path)
            .context("cannot read that file as a track")?;
        let id = track
            .id
            .clone()
            .context("the file read as a track without an id")?;
        Ok(Item {
            source: LOCAL.to_owned(),
            id,
            track,
        })
    }

    /// Makes `items` the queue and plays `start`.
    pub fn play_queue(&self, items: Vec<Item>, start: usize) -> Result<()> {
        let command = lock(&self.inner.transport).start(items, start);
        self.inner.apply(command)
    }

    pub fn next(&self) -> Result<()> {
        let command = lock(&self.inner.transport).next();
        self.inner.apply(command)
    }

    pub fn previous(&self) -> Result<()> {
        let command = lock(&self.inner.transport).previous();
        self.inner.apply(command)
    }

    pub fn jump(&self, index: usize) -> Result<()> {
        let command = lock(&self.inner.transport).jump(index);
        self.inner.apply(command)
    }

    pub fn set_repeat(&self, repeat: Repeat) {
        lock(&self.inner.transport).set_repeat(repeat);
        self.inner.changed();
    }

    /// Plays on, or loads last time's track where it was left when nothing has played yet.
    pub fn play(&self) -> Result<()> {
        let (resumed, snapshot) = {
            let transport = lock(&self.inner.transport);
            (transport.resumed(), transport.snapshot())
        };
        // A paused station plays on from "now": its old buffer is stale, so it loads afresh.
        if resumed.is_none()
            && snapshot.status == Status::Paused
            && let Some(item) = snapshot.item.filter(|item| radio::is_live(&item.source))
        {
            return self.inner.load(&item, Duration::ZERO, false);
        }
        let Some((item, at)) = resumed else {
            self.inner.with_player(|player| player.play());
            return Ok(());
        };
        // An account still signing in fails the load and leaves the track remembered, so the
        // next press tries again.
        self.inner.load(&item, at, false)?;
        lock(&self.inner.transport).loaded();
        self.inner.changed();
        Ok(())
    }

    /// Drops the engine and its audio output, keeping the track where it was for play to load
    /// again. After another app took the audio, iOS stopped the output and never restarts it.
    pub fn reopen_output(&self) {
        lock(&self.inner.transport).unload();
        *lock(&self.inner.engine) = None;
        self.inner.changed();
    }

    /// Whether the phone is on mobile data now. The next track streams at that network's
    /// quality, and downloads waiting for Wi-Fi start once it is back.
    pub fn set_cellular(&self, cellular: bool) {
        if self.inner.cellular.swap(cellular, Ordering::Relaxed) != cellular {
            log::info!(
                "network: {}",
                if cellular {
                    "mobile data"
                } else {
                    "not mobile data"
                }
            );
            self.inner.pump();
        }
    }

    /// Whether the app stays off the network, because the phone has none or the listener turned
    /// offline mode on. Then only kept tracks and files play, nothing downloads, and no provider
    /// or online lyrics service is asked anything. Back online, the waiting downloads start.
    pub fn set_offline(&self, offline: bool) {
        if self.inner.vault.offline() != offline {
            log::info!("network: {}", if offline { "offline" } else { "online" });
            self.inner.vault.set_offline(offline);
            self.inner.pump();
        }
    }

    /// Rest once the current track ends, or not.
    pub fn set_stop_after_current(&self, stop: bool) {
        lock(&self.inner.transport).set_stop_after_current(stop);
        self.inner.changed();
    }

    pub fn pause(&self) {
        self.inner.with_player(|player| player.pause());
    }

    /// How loud the left and right channels and the bass are now, 0 to 1, or silence with nothing
    /// playing. The levels are the track's own, before the listener's volume, so a song's wave
    /// does not change with how loud it was heard.
    pub fn levels(&self) -> [f32; 3] {
        let mut levels = [0.0; 3];
        self.inner.with_player(|player| {
            if let Some(spectrum) = player.spectrum() {
                spectrum.set_absolute(true);
                levels = [
                    levels::channel_level(&spectrum.left()),
                    levels::channel_level(&spectrum.right()),
                    levels::bass(&spectrum.bands()),
                ];
            }
        });
        levels
    }

    pub fn seek(&self, position: Duration) {
        // A live station has nowhere to seek to.
        let live = lock(&self.inner.transport)
            .snapshot()
            .item
            .is_some_and(|item| radio::is_live(&item.source));
        if live {
            return;
        }
        let resumed = lock(&self.inner.transport).seek(position);
        self.inner.changed();
        if !resumed {
            self.inner.with_player(|player| player.seek(position));
        }
    }

    /// Moves a queued track, as dragging its row does.
    pub fn move_queued(&self, from: usize, to: usize) {
        lock(&self.inner.transport).move_item(from, to);
        self.inner.changed();
    }

    /// Mixes what is still to play.
    pub fn shuffle_upcoming(&self) {
        lock(&self.inner.transport).shuffle_upcoming();
        self.inner.changed();
    }

    /// Takes a queued track out, as swiping its row does.
    pub fn remove_queued(&self, index: usize) {
        lock(&self.inner.transport).remove(index);
        self.inner.changed();
    }

    /// Drops what is still to play.
    pub fn clear_upcoming(&self) {
        lock(&self.inner.transport).clear_upcoming();
        self.inner.changed();
    }

    /// Queues `items` right after the current track, or plays them when nothing is playing.
    pub fn play_next(&self, items: Vec<Item>) -> Result<()> {
        let command = lock(&self.inner.transport).play_next(items);
        self.inner.apply(command)
    }

    /// Queues `items` at the end, or plays them when nothing is playing.
    pub fn add_to_queue(&self, items: Vec<Item>) -> Result<()> {
        let command = lock(&self.inner.transport).append(items);
        self.inner.apply(command)
    }

    /// Writes the session now, whatever the saver says, as the app goes to the background.
    pub fn save_session(&self) {
        if let Some(session) = session::Session::of(&lock(&self.inner.transport).snapshot()) {
            session.save(&self.inner.data);
        }
    }

    pub fn playback_settings(&self) -> PlaybackSettings {
        lock(&self.inner.settings).clone()
    }

    /// Saves `next` and applies it: the equalizer and the cache at once, the rest by restarting
    /// the engine where it was, since an engine reads them only when it starts.
    pub fn set_playback_settings(&self, next: PlaybackSettings) {
        let previous = std::mem::replace(&mut *lock(&self.inner.settings), next.clone());
        next.save(&self.inner.data);
        {
            let mut equalizer = lock(&self.inner.equalizer);
            equalizer.set_enabled(next.equalizer);
            equalizer.set_curve(next.curve(), Edit::Glide);
        }
        let vault = self.inner.vault.clone();
        let (keep, limit) = (next.keep_tracks, next.cache_bytes());
        self.inner.runtime.spawn_blocking(move || {
            vault.set_caching(keep);
            vault.set_limit(limit);
            if !keep {
                vault.forget();
            }
        });
        lock(&self.inner.transport).set_continue_similar(next.continue_similar);
        let cellular = self.inner.cellular.load(Ordering::Relaxed);
        if previous.restarts(&next)
            || previous.stream_quality(cellular) != next.stream_quality(cellular)
        {
            self.inner.restart_engine();
        }
        if previous.downloads_wifi_only != next.downloads_wifi_only {
            self.inner.pump();
        }
        // Players started for downloads fetch at the quality they started with.
        if previous.download_quality() != next.download_quality()
            && !lock(&self.inner.downloads).running()
        {
            lock(&self.inner.downloaders).clear();
        }
        if next.free_space && !previous.free_space {
            let inner = self.inner.clone();
            self.inner.runtime.spawn_blocking(move || inner.free_up());
        }
    }

    /// The stream levels a signed-in service serves, best first. Empty when there is no choice.
    pub fn qualities(&self, slug: &str) -> Vec<Offer> {
        lock(&self.inner.sessions)
            .get(slug)
            .map(|connected| connected.capabilities.qualities.to_vec())
            .unwrap_or_default()
    }

    /// What kept tracks and downloads take on disk, in bytes. It walks the folders.
    pub fn storage_usage(&self) -> Result<(u64, u64)> {
        let vault = self.inner.vault.clone();
        self.run(async move { Ok(tokio::task::spawn_blocking(move || vault.usage()).await?) })
    }

    pub fn clear_cache(&self) {
        self.inner.vault.forget();
    }

    pub fn clear_downloads(&self) {
        let mut downloads = lock(&self.inner.downloads);
        downloads.clear();
        downloads.save(&self.inner.data);
        drop(downloads);
        self.inner.vault.forget_downloads();
        self.inner.shelf.clear();
    }

    /// Asks for every track in `tracks` from `source`, and starts what the queue allows. They
    /// download once the provider is signed in, whether it plays or not.
    pub fn download(&self, source: &str, tracks: Vec<Track>) -> Result<()> {
        if radio::is_live(source) {
            anyhow::bail!("a station cannot be downloaded");
        }
        // An account that only browses, such as a free Spotify one, cannot download.
        if !self.inner.streams(source) {
            anyhow::bail!("this account cannot download: a free Spotify account only browses");
        }
        if lock(&self.inner.sessions)
            .get(source)
            .is_some_and(|connected| !connected.capabilities.downloads)
        {
            anyhow::bail!("{source} cannot download on this device");
        }
        {
            let mut downloads = lock(&self.inner.downloads);
            for track in tracks {
                downloads.add(source, track);
            }
            downloads.save(&self.inner.data);
        }
        self.inner.pump();
        Ok(())
    }

    /// Asks only for the tracks in `tracks` not listed yet, as keeping likes or a collection
    /// downloaded does.
    pub fn download_missing(&self, source: &str, tracks: Vec<Track>) -> Result<()> {
        let missing = lock(&self.inner.downloads).missing(source, tracks);
        if missing.is_empty() {
            return Ok(());
        }
        self.download(source, missing)
    }

    /// Keeps an album or playlist downloaded with the `tracks` it has now, and asks for those
    /// not listed yet. With a `name`, notes it and the `cover` for the downloads list.
    pub fn keep_collection(
        &self,
        source: &str,
        album: bool,
        id: &str,
        tracks: Vec<Track>,
        name: Option<&str>,
        cover: Option<&str>,
    ) -> Result<()> {
        self.download_missing(source, tracks.clone())?;
        let mut downloads = lock(&self.inner.downloads);
        downloads.keep(
            source,
            album,
            id,
            tracks.into_iter().filter_map(|track| track.id).collect(),
        );
        if let Some(name) = name {
            downloads.title(source, album, id, name, cover);
        }
        downloads.save(&self.inner.data);
        Ok(())
    }

    /// Stops keeping an album or playlist downloaded and removes its downloads, but for those
    /// another kept collection holds and, while likes download, the `liked` ones: removing
    /// them would only fetch them again.
    pub fn remove_kept_collection(&self, source: &str, album: bool, id: &str, liked: Vec<String>) {
        let spared = match lock(&self.inner.settings).download_likes {
            true => liked,
            false => Vec::new(),
        };
        let removed = {
            let mut downloads = lock(&self.inner.downloads);
            let removed = downloads.drop_collection(source, album, id, &spared);
            downloads.save(&self.inner.data);
            removed
        };
        for id in removed {
            self.inner.discard(source, &id);
            self.inner.shelf.drop(source, &id);
        }
    }

    /// The finished downloads by kept collection, largest first, then the others, with what
    /// each takes on disk, and what they take together. It reads every file's size, so call it
    /// off the main thread. A provider that cannot be reached counts its tracks as nothing.
    pub fn download_groups(&self) -> (Vec<downloads::Group>, u64) {
        let done: Vec<(String, String)> = lock(&self.inner.downloads)
            .entries()
            .iter()
            .filter(|entry| entry.done)
            .map(|entry| (entry.source.clone(), entry.id.clone()))
            .collect();
        let mut sizes = HashMap::new();
        for (source, id) in done {
            let size = self
                .inner
                .with_downloader(&source, |player| Ok(player.download_size(&id)))
                .ok()
                .flatten()
                .unwrap_or(0);
            sizes.insert((source, id), size);
        }
        if !lock(&self.inner.downloads).running() {
            lock(&self.inner.downloaders).clear();
        }
        lock(&self.inner.downloads).groups(|entry| {
            sizes
                .get(&(entry.source.clone(), entry.id.clone()))
                .copied()
                .unwrap_or(0)
        })
    }

    pub fn unkeep_collection(&self, source: &str, album: bool, id: &str) {
        let mut downloads = lock(&self.inner.downloads);
        downloads.unkeep(source, album, id);
        downloads.save(&self.inner.data);
    }

    pub fn kept_collections(&self) -> Vec<downloads::Collection> {
        lock(&self.inner.downloads).collections().to_vec()
    }

    /// The scrobbling accounts and whether local files are sent.
    pub fn scrobbling(&self) -> scrobbling::Scrobbling {
        lock(&self.inner.scrobbling).clone()
    }

    /// Where the listener approves linking `service` with `secret`, for the app to show itself.
    pub fn scrobble_approval(
        &self,
        service: &str,
        secret: &music::scrobble::Secret,
    ) -> Option<String> {
        scrobble_service(service)?.approval(secret)
    }

    /// Links `service`, waiting for the approval shown from `scrobble_approval` when it needs
    /// one, and keeps the account.
    pub fn scrobble_connect(&self, service: &str, secret: music::scrobble::Secret) -> Result<()> {
        let found = scrobble_service(service).context("no such scrobbling service")?;
        let task = self
            .inner
            .runtime
            .spawn(async move { found.connect_quietly(secret).await });
        *lock(&self.inner.linking) = Some(task.abort_handle());
        let account = self
            .inner
            .runtime
            .block_on(task)
            .map_err(|_| anyhow::anyhow!("the link was cancelled"))??;
        let mut scrobbling = lock(&self.inner.scrobbling);
        scrobbling.accounts.insert(service.to_owned(), account);
        scrobbling.save(&self.inner.data);
        Ok(())
    }

    /// Gives up on the link waiting for approval.
    pub fn scrobble_cancel(&self) {
        if let Some(task) = lock(&self.inner.linking).take() {
            task.abort();
        }
    }

    pub fn scrobble_disconnect(&self, service: &str) {
        let mut scrobbling = lock(&self.inner.scrobbling);
        scrobbling.accounts.remove(service);
        scrobbling.save(&self.inner.data);
    }

    pub fn scrobble_enable(&self, service: &str, enabled: bool) {
        let mut scrobbling = lock(&self.inner.scrobbling);
        if let Some(account) = scrobbling.accounts.get_mut(service) {
            account.enabled = enabled;
        }
        scrobbling.save(&self.inner.data);
    }

    pub fn scrobble_local_files(&self, on: bool) {
        let mut scrobbling = lock(&self.inner.scrobbling);
        scrobbling.local_files = on;
        scrobbling.save(&self.inner.data);
    }

    /// Tells every receiving account what started playing.
    pub fn scrobble_now_playing(&self, item: &Item) {
        self.send_listen(item, std::time::SystemTime::now(), false);
    }

    /// Sends a listen of `item` that started at `at` and has earned its scrobble.
    pub fn scrobble(&self, item: &Item, at: std::time::SystemTime) {
        self.send_listen(item, at, true);
    }

    fn send_listen(&self, item: &Item, at: std::time::SystemTime, finished: bool) {
        if finished {
            self.tell_provider(item, at);
        }
        let receivers = lock(&self.inner.scrobbling).receivers(&item.source);
        let Some(play) = scrobbling::play(&item.track, at) else {
            return;
        };
        for (id, account) in receivers {
            let Some(service) = scrobble_service(&id) else {
                continue;
            };
            let play = play.clone();
            // ponytail: a listen that fails to send is dropped; a retry queue if it matters.
            self.inner.runtime.spawn(async move {
                let sent = match finished {
                    true => {
                        service
                            .scrobble(&account, std::slice::from_ref(&play))
                            .await
                    }
                    false => service.now_playing(&account, &play).await,
                };
                if let Err(error) = sent {
                    log::warn!("scrobble: {id} did not take the listen: {error:#}");
                }
            });
        }
    }

    /// Records a finished listen on the track's own server, so its play counts and recently
    /// played fill up. Offline or signed out, nothing goes and the listen is dropped there.
    fn tell_provider(&self, item: &Item, at: std::time::SystemTime) {
        let Ok(api) = self.inner.api(&item.source) else {
            return;
        };
        let (source, id) = (item.source.clone(), item.id.clone());
        self.inner.runtime.spawn(async move {
            if let Err(error) = api.played(&id, at).await {
                log::warn!("scrobble: {source} did not take the listen: {error:#}");
            }
        });
    }

    /// Takes a track off the downloads and out of the vault.
    pub fn remove_download(&self, source: &str, id: &str) {
        let removed = {
            let mut downloads = lock(&self.inner.downloads);
            let removed = downloads.remove(source, id);
            downloads.save(&self.inner.data);
            removed
        };
        if removed {
            self.inner.discard(source, id);
            self.inner.shelf.drop(source, id);
        }
    }

    /// Every listed download, oldest first.
    pub fn downloads(&self) -> Vec<Download> {
        let fractions = lock(&self.inner.fractions);
        lock(&self.inner.downloads)
            .entries()
            .iter()
            .map(|entry| Download {
                source: entry.source.clone(),
                track: entry.track.clone(),
                state: entry.state(),
                progress: fractions
                    .get(&(entry.source.clone(), entry.id.clone()))
                    .and_then(Fraction::get),
            })
            .collect()
    }

    pub fn state(&self) -> PlayerState {
        self.inner.state()
    }

    /// Runs `future` on the core's runtime and waits for it. Callers are the host's worker
    /// threads, never a runtime thread.
    fn run<T: Send + 'static>(
        &self,
        future: impl Future<Output = Result<T>> + Send + 'static,
    ) -> Result<T> {
        self.runtime
            .block_on(self.runtime.spawn(future))
            .context("a core task panicked")?
    }
}

impl Inner {
    fn provider(&self, slug: &str) -> Result<Arc<dyn MusicProvider>> {
        self.providers
            .iter()
            .find(|provider| provider.slug() == slug)
            .cloned()
            .with_context(|| format!("there is no provider called {slug}"))
    }

    fn api(&self, slug: &str) -> Result<Arc<dyn MusicApi>> {
        reachable(self.vault.offline())?;
        lock(&self.sessions)
            .get(slug)
            .map(|connected| connected.api.clone())
            .context("that provider is not signed in")
    }

    /// Whether `slug`'s account plays its own tracks; see [`Core::streams`].
    fn streams(&self, slug: &str) -> bool {
        lock(&self.sessions)
            .get(slug)
            .is_none_or(|connected| plays(slug, connected))
    }

    /// The same song as `item` from another connected service that plays, searched in turn.
    fn stand_in(&self, item: &Item) -> Result<Item> {
        // ponytail: services in name order; the app's provider order if listeners care which.
        let mut apis: Vec<_> = lock(&self.sessions)
            .iter()
            .filter(|(slug, connected)| **slug != item.source && plays(slug, connected))
            .map(|(slug, connected)| (slug.clone(), connected.api.clone()))
            .collect();
        apis.sort_by(|left, right| left.0.cmp(&right.0));
        let wanted = item.track.clone();
        let query = format!("{} {}", wanted.name, wanted.artists);
        let search = async move {
            for (slug, api) in apis {
                match api.search(&query).await {
                    Ok(found) => {
                        if let Some(track) = stand_in::same_song(&wanted, &found) {
                            return Some((slug, track.clone()));
                        }
                    }
                    Err(error) => {
                        log::warn!("playback: {slug} cannot search for a stand-in: {error:#}")
                    }
                }
            }
            None
        };
        // Called from the engine's event task and from the host's threads alike.
        let found = tokio::task::block_in_place(|| self.runtime.block_on(search));
        let (source, track) = found.context("no other connected service has this song")?;
        log::info!("playback: {} plays from {source}", item.source);
        Ok(Item {
            source,
            id: track.id.clone().context("the stand-in has no id")?,
            track,
        })
    }

    /// Keeps a signed-in provider, and starts the downloads it left unfinished.
    fn connect(
        self: &Arc<Self>,
        slug: &str,
        api: Arc<dyn MusicApi>,
        playback: Arc<dyn PlaybackFactory>,
        capabilities: Capabilities,
    ) {
        // On iOS Apple Music plays through the system's queue player, since its Widevine engine
        // has no module there. That player picks the stream itself and keeps nothing.
        #[cfg(target_os = "ios")]
        let (playback, capabilities) = match slug {
            "apple" => (
                Arc::new(native::Factory) as Arc<dyn PlaybackFactory>,
                Capabilities {
                    keeps: false,
                    downloads: false,
                    qualities: &[],
                    ..capabilities
                },
            ),
            _ => (playback, capabilities),
        };
        lock(&self.sessions).insert(
            slug.to_owned(),
            Connected {
                api,
                playback,
                capabilities,
            },
        );
        self.pump();
    }

    /// The engine factory for a source: the local one for files, a signed-in provider's
    /// otherwise.
    fn factory(&self, source: &str) -> Result<Arc<dyn PlaybackFactory>> {
        if radio::is_live(source) {
            return Ok(self.stations.clone());
        }
        if source == LOCAL {
            return self
                .local
                .playback_factory()
                .context("the local provider has no engine");
        }
        if let Some(connected) = lock(&self.sessions).get(source) {
            return Ok(connected.playback.clone());
        }
        // Not reached yet, not at all without a network, or signed out: an engine built without
        // the network plays what is downloaded. Some providers need the stored account for it.
        let mut offline = lock(&self.offline);
        if let Some(factory) = offline.get(source) {
            return Ok(factory.clone());
        }
        let factory = self
            .provider(source)?
            .offline_playback()
            .with_context(|| format!("{source} is not signed in"))?;
        log::info!("playback: {source} plays from its stored account until it is reached");
        offline.insert(source.to_owned(), factory.clone());
        Ok(factory)
    }

    /// Carries out what the transport decided, then tells the host.
    fn apply(self: &Arc<Self>, command: Option<Command>) -> Result<()> {
        let outcome = match command {
            Some(Command::Load { item, seamless }) => {
                // The track that loads now has the bandwidth; the cache warms again once it is in.
                if let Some(round) = lock(&self.prefetching).take() {
                    round.abort();
                }
                self.load(&item, Duration::ZERO, seamless)
            }
            Some(Command::Preload { .. }) if !self.preloads() => Ok(()),
            Some(Command::Preload { item }) => {
                self.prefetch(&item);
                self.with_engine_of(&item.source, |player| player.preload(&item.id, true))
            }
            Some(Command::Restart) => {
                self.with_player(|player| player.seek(Duration::ZERO));
                Ok(())
            }
            Some(Command::Continue { seed }) => {
                self.continue_after(seed);
                Ok(())
            }
            None => Ok(()),
        };
        self.changed();
        outcome
    }

    /// Fetches the upcoming tracks the settings allow into the cache, one at a time and nearest
    /// first, beside the gapless preload of `preloaded`. It runs once the current track is all
    /// in, so it never takes bandwidth from it, and a newer round or a load stops it.
    fn prefetch(self: &Arc<Self>, preloaded: &Item) {
        let inner = self.clone();
        let mut tried = vec![preloaded.clone()];
        let round = self.runtime.spawn(async move {
            // Each step looks again, so a track no longer upcoming is never started.
            while let Some((item, fetching)) = inner.next_prefetch(&tried) {
                log::debug!("prefetch: {} {}", item.source, item.id);
                if let Err(error) = fetching.await {
                    log::debug!("prefetch: {} {} failed: {error:#}", item.source, item.id);
                    break;
                }
                tried.push(item);
            }
        });
        if let Some(previous) = lock(&self.prefetching).replace(round.abort_handle()) {
            previous.abort();
        }
    }

    /// The next upcoming track to fetch into the cache, not one of `tried`, and its fetch on the
    /// engine playing, which streams at the quality the track will play at. Downloads the
    /// listener asked for go first, so nothing is prefetched while any are left.
    // ponytail: only the playing engine's source is prefetched; a mixed queue's other tracks wait.
    fn next_prefetch(&self, tried: &[Item]) -> Option<(Item, Fetching)> {
        if lock(&self.downloads).running() {
            return None;
        }
        let depth = lock(&self.settings)
            .prefetch_depth(self.cellular.load(Ordering::Relaxed), self.vault.offline());
        let upcoming = lock(&self.transport).prefetch(depth, |item| tried.contains(item));
        let engine = lock(&self.engine);
        let engine = engine.as_ref()?;
        let item = upcoming
            .into_iter()
            .find(|item| item.source == engine.source && !engine.player.kept(&item.id))?;
        let fetching = engine.player.prefetch(&item.id);
        Some((item, fetching))
    }

    /// Finds tracks like `seed` from its provider's radio and plays on into them. Without the
    /// provider, offline or signed out, the queue comes to rest at its end.
    fn continue_after(self: &Arc<Self>, seed: Item) {
        let inner = self.clone();
        let api = self.api(&seed.source);
        self.runtime.spawn(async move {
            let found = match api {
                Ok(api) => api.track_radio(&seed.id, None).await,
                Err(error) => Err(error),
            };
            let items = match found {
                Ok((tracks, _)) => tracks
                    .into_iter()
                    .filter(|track| track.playable && track.id.as_deref() != Some(seed.id.as_str()))
                    .filter_map(|track| {
                        Some(Item {
                            source: seed.source.clone(),
                            id: track.id.clone()?,
                            track,
                        })
                    })
                    .collect(),
                Err(error) => {
                    log::warn!("playback: cannot continue with similar tracks: {error:#}");
                    Vec::new()
                }
            };
            log::info!(
                "playback: the queue continues with {} similar tracks",
                items.len()
            );
            let command = lock(&inner.transport).extend(items);
            if let Err(error) = inner.apply(command) {
                log::warn!("playback: cannot play the similar tracks: {error:#}");
            }
        });
    }

    /// Loads `item`, starting its source's engine first when another one is running. Dropping the
    /// old engine is what stops it, and a segue across engines cannot be seamless.
    fn load(self: &Arc<Self>, item: &Item, at: Duration, seamless: bool) -> Result<()> {
        let stood_in;
        let item = match self.streams(&item.source) {
            true => item,
            false => {
                stood_in = self.stand_in(item)?;
                lock(&self.transport).stand_in(item, stood_in.clone());
                &stood_in
            }
        };
        {
            let mut downloads = lock(&self.downloads);
            if downloads.played(&item.source, &item.id, downloads::now()) {
                downloads.save(&self.data);
            }
        }
        let reused = lock(&self.engine)
            .as_ref()
            .is_some_and(|engine| engine.source == item.source);
        match self.load_on_engine(item, at, seamless) {
            // An engine whose output went with an AirPlay route has stopped for good; a new one
            // gets an output on the route there is now.
            Err(error) if reused => {
                log::warn!(
                    "playback: the running engine cannot load, starting a new one: {error:#}"
                );
                *lock(&self.engine) = None;
                self.load_on_engine(item, at, false)
            }
            outcome => outcome,
        }
    }

    fn load_on_engine(self: &Arc<Self>, item: &Item, at: Duration, seamless: bool) -> Result<()> {
        let _entered = self.runtime.enter();
        let mut engine = lock(&self.engine);
        let quality = self.stream_quality();
        let switching = engine
            .as_ref()
            .is_none_or(|engine| engine.source != item.source || engine.quality != quality);
        if switching {
            *engine = None;
            let config = self.playback_config();
            let (player, mut events) = self.factory(&item.source)?.start(config);
            let inner = Arc::downgrade(self);
            self.runtime.spawn(async move {
                while let Some(event) = events.next().await {
                    let Some(inner) = inner.upgrade() else {
                        break;
                    };
                    if let PlaybackEvent::Signal { id, track } = &event
                        && let Some(encoding) = track.encoding
                    {
                        let mut encodings = lock(&inner.encodings);
                        // Only the current track and the one queued behind it are ever asked for.
                        if encodings.len() > 16 {
                            encodings.clear();
                        }
                        encodings.insert(id.clone(), encoding);
                    }
                    // The track failed because its account turned out to play previews only:
                    // the same track stands in from another service, or counts as unplayable
                    // when none has it.
                    if let PlaybackEvent::Unavailable { id: Some(id) } = &event
                        && let Some(item) = lock(&inner.transport).snapshot().item
                        && item.id == *id
                        && !inner.streams(&item.source)
                    {
                        if item.source == "tidal" && !TIDAL_PREVIEWS.swap(true, Ordering::Relaxed) {
                            std::fs::write(inner.data.join(TIDAL_PREVIEWS_FILE), b"").ok();
                        }
                        // Loading the stand-in searches and starts another engine, which blocks;
                        // run here, inside this engine's event task, it never finished.
                        let retrying = inner.clone();
                        let failed = event.clone();
                        inner.runtime.spawn_blocking(move || {
                            let retried = retrying.apply(Some(Command::Load {
                                item,
                                seamless: false,
                            }));
                            if let Err(error) = retried {
                                // No service has it: the failure counts as the track's own.
                                log::warn!("playback: no stand-in: {error:#}");
                                let command = lock(&retrying.transport).on_event(&failed);
                                if let Err(error) = retrying.apply(command) {
                                    log::warn!("playback: cannot follow the engine: {error:#}");
                                }
                            }
                        });
                        continue;
                    }
                    let command = lock(&inner.transport).on_event(&event);
                    if let Err(error) = inner.apply(command) {
                        log::warn!("playback: cannot follow the engine: {error:#}");
                    }
                }
            });
            *engine = Some(Engine {
                source: item.source.clone(),
                quality,
                player,
            });
        }
        let engine = engine.as_ref().context("no engine is running")?;
        engine.player.load(&item.id, at, seamless && !switching)
    }

    fn with_engine_of(
        &self,
        source: &str,
        action: impl FnOnce(&dyn Player) -> Result<()>,
    ) -> Result<()> {
        let _entered = self.runtime.enter();
        match lock(&self.engine).as_ref() {
            Some(engine) if engine.source == source => action(engine.player.as_ref()),
            _ => Ok(()),
        }
    }

    fn with_player(&self, action: impl FnOnce(&dyn Player)) {
        let _entered = self.runtime.enter();
        if let Some(engine) = lock(&self.engine).as_ref() {
            action(engine.player.as_ref());
        }
    }

    fn state(&self) -> PlayerState {
        let transport = lock(&self.transport).snapshot();
        let encoding = transport
            .item
            .as_ref()
            .and_then(|item| lock(&self.encodings).get(&item.id).copied());
        let now_playing = transport
            .item
            .as_ref()
            .filter(|item| radio::is_live(&item.source))
            .and_then(|item| self.stations.now_playing(&item.id));
        PlayerState {
            transport,
            encoding,
            now_playing,
        }
    }

    fn stream_quality(&self) -> Quality {
        lock(&self.settings).stream_quality(self.cellular.load(Ordering::Relaxed))
    }

    fn preloads(&self) -> bool {
        lock(&self.settings).preloads(self.cellular.load(Ordering::Relaxed))
    }

    fn playback_config(&self) -> PlaybackConfig {
        let settings = lock(&self.settings);
        PlaybackConfig {
            normalisation: settings.normalisation,
            gapless: settings.gapless,
            position_interval: POSITION_INTERVAL,
            gain: 1.0,
            equalizer: lock(&self.equalizer).reader(),
            transcode: Transcode::default(),
            quality: settings.stream_quality(self.cellular.load(Ordering::Relaxed)),
            meter: Meter::default(),
            analyzer: Analyzer::default(),
            vault: Some(self.vault.clone()),
        }
    }

    /// Starts the engine again with the current settings and the current track where it was,
    /// paused if it was paused.
    fn restart_engine(self: &Arc<Self>) {
        let (snapshot, resumed) = {
            let transport = lock(&self.transport);
            (transport.snapshot(), transport.resumed().is_some())
        };
        *lock(&self.engine) = None;
        // A track only remembered from last time is in no engine; play loads it with the new
        // settings anyway.
        let Some(item) = snapshot.item.filter(|_| !resumed) else {
            return;
        };
        if let Err(error) = self.load(&item, snapshot.position, false) {
            log::warn!("playback: cannot restart the engine: {error:#}");
            return;
        }
        if snapshot.status == Status::Paused {
            self.with_player(|player| player.pause());
        }
    }

    /// Starts queued downloads while the queue has room. Each one that ends starts the next.
    fn pump(self: &Arc<Self>) {
        loop {
            let wifi_only = lock(&self.settings).downloads_wifi_only;
            if downloads_wait(
                self.vault.offline(),
                wifi_only,
                self.cellular.load(Ordering::Relaxed),
            ) {
                break;
            }
            let signed_in: Vec<String> = lock(&self.sessions).keys().cloned().collect();
            let next = lock(&self.downloads)
                .next_ready(|source| signed_in.iter().any(|slug| slug == source));
            let Some((source, id)) = next else {
                break;
            };
            let fraction = Fraction::default();
            lock(&self.fractions).insert((source.clone(), id.clone()), fraction.clone());
            let started =
                self.with_downloader(&source, |player| Ok(player.download(&id, fraction)));
            let inner = self.clone();
            self.runtime.spawn(async move {
                let outcome = match started {
                    Ok(download) => download.await,
                    Err(error) => Err(error),
                };
                if let Err(error) = &outcome {
                    log::warn!("downloads: {source} {id} failed: {error:#}");
                }
                lock(&inner.fractions).remove(&(source.clone(), id.clone()));
                let listed = {
                    let mut downloads = lock(&inner.downloads);
                    let listed = downloads.finished(&source, &id, outcome.is_ok());
                    downloads.save(&inner.data);
                    listed
                };
                // removed while it ran: what it kept goes too
                if !listed && outcome.is_ok() {
                    inner.discard(&source, &id);
                }
                inner.pump();
            });
        }
        if !lock(&self.downloads).running() {
            lock(&self.downloaders).clear();
        }
    }

    /// Runs `action` on a player of `source` that can reach the vault: the one playing when it
    /// plays that source at the download quality, or one started for downloads otherwise.
    fn with_downloader<T>(
        &self,
        source: &str,
        action: impl FnOnce(&dyn Player) -> Result<T>,
    ) -> Result<T> {
        let _entered = self.runtime.enter();
        let quality = lock(&self.settings).download_quality();
        if let Some(engine) = lock(&self.engine).as_ref()
            && engine.source == source
            && engine.quality == quality
        {
            return action(engine.player.as_ref());
        }
        let mut downloaders = lock(&self.downloaders);
        if !downloaders.contains_key(source) {
            let config = PlaybackConfig {
                quality,
                ..self.playback_config()
            };
            let (player, _events) = self.factory(source)?.start(config);
            downloaders.insert(source.to_owned(), player);
        }
        action(downloaders[source].as_ref())
    }

    /// With freeing space on, takes off the downloads that have not played for 90 days.
    fn free_up(self: &Arc<Self>) {
        if !lock(&self.settings).free_space {
            return;
        }
        let stale = {
            let mut downloads = lock(&self.downloads);
            let stale = downloads.stale(downloads::now(), settings::STALE_AFTER);
            for (source, id) in &stale {
                downloads.remove(source, id);
            }
            if !stale.is_empty() {
                downloads.save(&self.data);
            }
            stale
        };
        for (source, id) in stale {
            log::info!("downloads: {source} {id} unplayed for 90 days, freeing its space");
            self.discard(&source, &id);
        }
    }

    fn discard(self: &Arc<Self>, source: &str, id: &str) {
        let discarded = self.with_downloader(source, |player| {
            player.discard(id);
            Ok(())
        });
        if let Err(error) = discarded {
            log::warn!("downloads: cannot discard {source} {id}: {error:#}");
        }
        if !lock(&self.downloads).running() {
            lock(&self.downloaders).clear();
        }
    }

    fn changed(&self) {
        let state = self.state();
        if lock(&self.saver).due(&state.transport, std::time::Instant::now())
            && let Some(session) = session::Session::of(&state.transport)
        {
            let folder = self.data.clone();
            self.runtime.spawn_blocking(move || session.save(&folder));
        }
        (self.on_change)(state);
    }
}

/// The transport with last time's queue in it, paused where it was left, or an empty one.
fn resumed_transport(folder: &std::path::Path, settings: &PlaybackSettings) -> Transport {
    let mut transport = Transport::default();
    transport.set_continue_similar(settings.continue_similar);
    if let Some(session) = session::Session::load(folder).filter(|_| settings.resume_last) {
        let position = session.position();
        let repeat = if settings.remember_repeat {
            session.repeat
        } else {
            Repeat::Off
        };
        transport.resume(session.items, session.index, position, repeat);
    }
    transport
}

/// The key kept tracks are sealed under, made once and kept in the data folder, which iOS
/// encrypts while the phone is locked.
// ponytail: a file rather than the Keychain; move it there if the data folder ever syncs.
/// Whether queued downloads wait: offline, or on mobile data when they are for Wi-Fi only.
fn downloads_wait(offline: bool, wifi_only: bool, cellular: bool) -> bool {
    offline || wifi_only && cellular
}

/// What stations can be browsed by.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RadioFacets {
    Countries,
    Tags,
    Languages,
}

fn station_item(station: &music::radio::Station) -> Item {
    Item {
        source: radio::RADIO.to_owned(),
        id: station.id.clone(),
        track: station.track(),
    }
}

/// Refuses what needs the network while the app is offline.
fn reachable(offline: bool) -> Result<()> {
    if offline {
        anyhow::bail!("offline: the app is not using the network");
    }
    Ok(())
}

fn vault_key(folder: &std::path::Path) -> Result<Vec<u8>> {
    let path = folder.join("vault.key");
    if let Ok(key) = std::fs::read(&path) {
        return Ok(key);
    }
    let key = Vault::new_master()?;
    std::fs::write(&path, key).context("cannot save the vault key")?;
    Ok(key.to_vec())
}

/// The first credited artist's name, for a shelf title.
fn lead_artist(track: &Track) -> &str {
    track
        .artist_refs
        .first()
        .map_or(track.artists.as_str(), |artist| artist.name.as_str())
}

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

fn scrobble_service(id: &str) -> Option<Arc<dyn music::scrobble::Service>> {
    music::scrobble::services()
        .into_iter()
        .find(|service| service.id() == id)
}

/// Writes the Mozilla root certificates to a PEM file in `cache` and points `SSL_CERT_FILE` at
/// it. librespot reads the platform's root certificates, and iOS keeps none where
/// `rustls-native-certs` looks, so Spotify could not reach any server without it.
fn trust_roots(cache: &std::path::Path) {
    use base64::Engine as _;
    let mut pem = String::new();
    for root in webpki_root_certs::TLS_SERVER_ROOT_CERTS {
        let text = base64::engine::general_purpose::STANDARD.encode(root.as_ref());
        pem.push_str("-----BEGIN CERTIFICATE-----\n");
        for line in text.as_bytes().chunks(64) {
            pem.push_str(std::str::from_utf8(line).unwrap_or_default());
            pem.push('\n');
        }
        pem.push_str("-----END CERTIFICATE-----\n");
    }
    let file = cache.join("roots.pem");
    if let Err(error) = std::fs::create_dir_all(cache).and_then(|()| std::fs::write(&file, pem)) {
        log::warn!("tls: cannot write the root certificates: {error}");
        return;
    }
    // SAFETY: set once at start, before the runtime or any provider reads the environment.
    unsafe { std::env::set_var("SSL_CERT_FILE", &file) };
}

/// Writes every panic to the log as well. A phone shows no stderr, so a thread that panicked,
/// such as a playback engine, otherwise just stops answering with no trace of why.
fn log_panics() {
    let previous = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |info| {
        let thread = std::thread::current();
        log::error!("panic on {}: {info}", thread.name().unwrap_or("a thread"));
        previous(info);
    }));
}

/// Points `dirs` at the app's own folders. On Android it reads the Linux variables, which an
/// app process never has, so every cache and credentials folder came back missing.
#[cfg(target_os = "android")]
fn app_dirs(paths: &Paths) {
    // SAFETY: set once at start, before the runtime or any provider reads the environment.
    unsafe {
        std::env::set_var("HOME", &paths.data);
        std::env::set_var("XDG_DATA_HOME", &paths.data);
        std::env::set_var("XDG_CONFIG_HOME", &paths.data);
        std::env::set_var("XDG_CACHE_HOME", &paths.cache);
    }
}

/// Whether `connected`, the account of `slug`, plays its own tracks. A TIDAL account without a
/// subscription only learns it plays previews once a track is asked for.
fn plays(slug: &str, connected: &Connected) -> bool {
    let previews = music::tidal::preview_only() || TIDAL_PREVIEWS.load(Ordering::Relaxed);
    connected.capabilities.streams && !(slug == "tidal" && previews)
}

/// Whether the TIDAL account was found to play previews only, kept across launches: upstream
/// learns it again only once a track fails, which would cost a failed track every launch.
static TIDAL_PREVIEWS: AtomicBool = AtomicBool::new(false);
/// The file that remembers [`TIDAL_PREVIEWS`] in the data folder.
const TIDAL_PREVIEWS_FILE: &str = "tidal-previews";

/// The page a sign-in's browser lands on once it hands Cauce its code: the app's dark page and
/// accent, a check mark, `title` and `line`.
pub fn return_page(title: &str, line: &str) -> String {
    let escape = |text: &str| {
        text.replace('&', "&amp;")
            .replace('<', "&lt;")
            .replace('>', "&gt;")
            .replace('"', "&quot;")
    };
    format!(
        r##"<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Cauce</title><style>
html,body{{margin:0;height:100%;background:#0e090f;color:#f4eef4;font-family:-apple-system,system-ui,sans-serif}}
main{{min-height:100%;display:flex;flex-direction:column;align-items:center;justify-content:center;gap:14px;padding:32px;box-sizing:border-box;text-align:center}}
.mark{{width:72px;height:72px;border-radius:50%;background:#d36fd0;display:flex;align-items:center;justify-content:center}}
h1{{margin:6px 0 0;font-size:26px;font-weight:700;letter-spacing:-.01em}}
p{{margin:0;max-width:300px;font-size:16px;line-height:1.45;color:#a79da8}}
</style></head><body><main><div class="mark"><svg width="34" height="34" viewBox="0 0 24 24" fill="none" stroke="#1b0d1b" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"><path d="M5 12.5l4.5 4.5L19 7.5"/></svg></div><h1>{}</h1><p>{}</p></main></body></html>"##,
        escape(title),
        escape(line)
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_playlist_entry_is_found_by_its_copy_of_the_track() {
        let ids = ["a", "b", "a", "c", "a"];
        assert_eq!(music::entry_index(ids, "a", 0), Some(0));
        assert_eq!(music::entry_index(ids, "a", 1), Some(2));
        assert_eq!(music::entry_index(ids, "a", 2), Some(4));
        assert_eq!(music::entry_index(ids, "c", 0), Some(3));
        assert_eq!(music::entry_index(ids, "a", 3), None);
        assert_eq!(music::entry_index(ids, "z", 0), None);
    }

    #[test]
    fn nothing_downloads_while_offline_whatever_the_network() {
        for wifi_only in [false, true] {
            for cellular in [false, true] {
                assert!(downloads_wait(true, wifi_only, cellular));
            }
        }
    }

    #[test]
    fn online_downloads_wait_only_for_wifi_when_asked() {
        assert!(!downloads_wait(false, false, false));
        assert!(!downloads_wait(false, false, true));
        assert!(!downloads_wait(false, true, false));
        assert!(downloads_wait(false, true, true));
    }

    #[test]
    fn offline_nothing_is_asked_of_a_provider() {
        let refused = reachable(true).unwrap_err().to_string();
        assert!(refused.contains("offline"), "{refused}");
        assert!(reachable(false).is_ok());
    }
}
