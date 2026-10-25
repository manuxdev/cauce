import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'ui/core/across_providers.dart';
import 'ui/core/app_prefs.dart';
import 'src/rust/api/player.dart' as core;
import 'src/rust/frb_generated.dart';
import 'ui/core/motion.dart';
import 'ui/core/notifications.dart';
import 'ui/core/app_scope.dart';
import 'ui/core/cached_image.dart';
import 'ui/core/icons.dart';
import 'ui/core/floating_tab_bar.dart';
import 'ui/core/l10n.dart';
import 'ui/core/selected_service.dart';
import 'ui/core/status_band.dart';
import 'ui/core/tab_navigators.dart';
import 'ui/core/theme.dart';
import 'ui/core/tint_scope.dart';
import 'ui/core/toast.dart';
import 'ui/features/accounts/view_models/accounts_view_model.dart';
import 'ui/features/downloads/downloads_view_model.dart';
import 'ui/features/home/views/home_screen.dart';
import 'ui/features/library/view_models/favorites_view_model.dart';
import 'ui/features/library/views/library_screen.dart';
import 'ui/features/onboarding/app_gate.dart';
import 'ui/features/lyrics/view_models/lyrics_view_model.dart';
import 'ui/features/player/audio_levels.dart';
import 'ui/features/player/now_playing_center.dart';
import 'ui/features/player/view_models/player_view_model.dart';
import 'ui/features/player/views/mini_player.dart';
import 'ui/features/scrobbling/scrobble_tracker.dart';
import 'ui/features/search/recent_searches.dart';
import 'ui/features/search/views/search_screen.dart';
import 'ui/features/settings/view_models/playback_settings_view_model.dart';
import 'ui/features/settings/views/settings_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final PlayerViewModel player;
  try {
    await RustLib.init();
    final data = await getApplicationSupportDirectory();
    final cache = await getApplicationCacheDirectory();
    await core.init(dataDir: data.path, cacheDir: cache.path);
    player = PlayerViewModel(core.playerStates());
  } catch (error) {
    // Without the core there is no app, but a blank screen would hide why.
    runApp(
      MaterialApp(
        home: Scaffold(body: SafeArea(child: Text('Cannot load the Rust core:\n$error'))),
      ),
    );
    return;
  }
  NowPlayingCenter(player);
  waveforms.attach(player);
  final scrobbles = ScrobbleTracker<core.TrackItem>(
    nowPlaying: (track) => core.scrobbleNowPlaying(track: track).ignore(),
    scrobble: (track, started) =>
        core.scrobble(track: track, startedSecs: BigInt.from(started.millisecondsSinceEpoch ~/ 1000)).ignore(),
  );
  player.addListener(() {
    final track = player.track;
    scrobbles.observe(
      track,
      id: track == null ? '' : '${track.source}:${track.id}',
      length: Duration(milliseconds: track?.durationMs.toInt() ?? 0),
      playing: player.playing,
      now: DateTime.now(),
    );
  });
  final favorites = FavoritesViewModel();
  final accounts = AccountsViewModel();
  // Hearts need each service's favorites as soon as it has an account.
  accounts.addListener(() {
    for (final service in accounts.connected) {
      if (favorites.tracks(service.slug).isEmpty && !favorites.loading(service.slug)) favorites.load(service.slug);
    }
  });
  // A band going away is confirmed with a toast.
  final failing = <String>{};
  accounts.addListener(() {
    for (final service in streamingServices) {
      if (accounts.error(service.slug) != null) {
        failing.add(service.slug);
      } else if (accounts.signedIn(service.slug) && failing.remove(service.slug)) {
        showToast(Toast(title: translate('band.connected', {'name': service.name}), glyph: CauceGlyph.check));
      }
    }
  });
  online.addListener(() {
    if (!online.value) return;
    showToast(Toast(title: translate('band.backOnline'), glyph: CauceGlyph.check, tone: ToastTone.info));
    // Accounts that could not be reached offline are tried again.
    if (accounts.unreachable) accounts.restoreAll();
  });
  accounts.restoreAll();
  PlayerViewModel.substitute = (track) async {
    if (!appPrefs.substitute) return null;
    final others = ordered([
      for (final service in accounts.connected)
        if (service.slug != track.source) service.slug,
    ], appPrefs.providerOrder);
    for (final slug in others) {
      try {
        final found = sameSong(track, await core.search(slug: slug, query: '${track.title} ${track.artists}'));
        if (found != null) return found;
      } on Object {
        // That provider cannot search now; the next one may.
      }
    }
    return null;
  };
  final playbackSettings = PlaybackSettingsViewModel();
  downloads.onBatchDone = (batch) {
    final failed = batch.done == 0;
    final title = translate(failed ? 'downloads.notReady' : 'downloads.finished', {'name': batch.name});
    final detail = batch.failed == 0
        ? translate('downloads.offline', {'count': batch.done})
        : translate('downloads.someFailed', {'done': batch.done, 'failed': batch.failed});
    if (WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) notify(title, detail).ignore();
    showToast(
      Toast(
        title: title,
        detail: detail,
        cover: batch.cover,
        badge: true,
        tone: failed ? ToastTone.error : ToastTone.ok,
      ),
    );
  };
  favorites.onLiked = (track) {
    if (playbackSettings.settings?.downloadLikes ?? false) downloads.download([track]);
  };
  await Future.wait([
    selectedService.load(),
    CachedNetworkImage.prepare(),
    recentSearches.load(),
    language.load(),
    appPrefs.load(),
    playbackSettings.load(),
    downloads.refresh(),
  ]);
  Appearance(player);
  // The page a sign-in's browser lands on speaks the app's language.
  void wordReturnPage() =>
      core.setReturnPage(title: translate('signIn.returned'), line: translate('signIn.returned.detail')).ignore();
  wordReturnPage();
  language.addListener(wordReturnPage);
  runApp(
    AppScope(
      player: player,
      accounts: accounts,
      favorites: favorites,
      lyrics: LyricsViewModel(player),
      playbackSettings: playbackSettings,
      child: LanguageScope(child: const CauceApp()),
    ),
  );
}

/// Picks the palette from the listener's appearance choices, the phone's theme and the cover
/// playing, and draws the whole app again when how it looks changes.
class Appearance with WidgetsBindingObserver {
  Appearance(this.player) {
    WidgetsBinding.instance.addObserver(this);
    appPrefs.addListener(_update);
    player.addListener(_follow);
    _follow();
    _update();
  }

  final PlayerViewModel player;
  String? _cover;
  double? _hue;
  Object? _shown;

  void _follow() {
    final track = player.track;
    final cover = track?.coverLarge ?? track?.cover;
    if (cover == _cover) return;
    _cover = cover;
    coverHueOf(cover).then((hue) {
      if (cover != _cover) return;
      _hue = hue;
      _update();
    });
  }

  @override
  void didChangePlatformBrightness() => _update();

  void _update() {
    final light = switch (appPrefs.theme) {
      ThemeChoice.light => true,
      ThemeChoice.dark => false,
      ThemeChoice.system => PlatformDispatcher.instance.platformBrightness == Brightness.light,
    };
    final accent = appPrefs.accent;
    final dark = Palette.of(light: false, accent: accent, coverHue: _hue);
    CauceColors.use(light ? Palette.of(light: true, accent: accent, coverHue: _hue) : dark, dark);
    final shown = (CauceColors.now, dark, appPrefs.coverColor, appPrefs.density, appPrefs.providerTag);
    if (shown == _shown) return;
    _shown = shown;
    // Colours are read straight from the palette, so every widget builds again with the new one.
    void rebuild(Element element) {
      element.markNeedsBuild();
      element.visitChildren(rebuild);
    }

    WidgetsBinding.instance.rootElement?.visitChildren(rebuild);
  }
}

class CauceApp extends StatelessWidget {
  const CauceApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Cauce',
      debugShowCheckedModeBanner: false,
      theme: cauceTheme(),
      // The playing cover's tint, handed to every page and painted behind the tab pages.
      builder: (context, child) => AnnotatedRegion(
        value: CauceColors.light ? SystemUiOverlayStyle.dark : SystemUiOverlayStyle.light,
        child: ListenableBuilder(
          listenable: AppScope.of(context).player,
          builder: (context, _) {
            final track = AppScope.of(context).player.track;
            return CoverTint(
              url: track?.coverLarge ?? track?.cover,
              child: Builder(
                builder: (context) => ColoredBox(
                  color: TintScope.of(context).page,
                  child: ToastHost(child: child!),
                ),
              ),
            );
          },
        ),
      ),
      home: AppGate(accounts: AppScope.of(context).accounts, app: const Shell()),
    );
  }
}

List<TabItem> _tabs(BuildContext context) => [
  TabItem(CauceGlyph.home, context.t('tab.home')),
  TabItem(CauceGlyph.search, context.t('tab.search')),
  TabItem(CauceGlyph.library, context.t('tab.library')),
  TabItem(CauceGlyph.settings, context.t('tab.settings')),
];

/// Where connecting a service lives.
const _settingsTab = 3;

/// The tabs, with the mini player and the floating tab bar riding over every one.
class Shell extends StatefulWidget {
  const Shell({super.key});

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  late int _tab = tabNavigators.selected = appPrefs.initialTab;
  late final PlayerViewModel _player = AppScope.of(context).player;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _player.addListener(_showError);
      _player.addListener(_unfoldOnPlay);
    });
  }

  @override
  void dispose() {
    _player.removeListener(_showError);
    _player.removeListener(_unfoldOnPlay);
    super.dispose();
  }

  /// What was playing last time the player changed, to notice a new track or playing again.
  (String?, bool) _was = (null, false);

  /// Playing something brings the mini player back out of the dock.
  void _unfoldOnPlay() {
    final now = (_player.track?.id, _player.playing || _player.loading);
    if (now.$2 && (now.$1 != _was.$1 || !_was.$2)) dockCompact.value = false;
    _was = now;
  }

  void _showError() {
    final error = _player.takeError();
    if (error == null || !mounted) return;
    showToast(Toast(title: error, tone: ToastTone.error));
  }

  void _openAccounts() => _select(_settingsTab);

  /// A tap on the tab on screen takes it back to its first page.
  void _select(int tab) {
    // A tap on the dock brings the mini player back out.
    dockCompact.value = false;
    if (tab == _tab) {
      tabNavigators.keys[tab].currentState?.popUntil((route) => route.isFirst);
      return;
    }
    tabNavigators.selected = tab;
    tick();
    appPrefs.usedTab(tab);
    setState(() => _tab = tab);
  }

  /// Each tab's navigator flies its own heroes; only the root one gets a controller for free.
  final _heroes = [for (var tab = 0; tab < 4; tab++) HeroController()];

  Widget _tabPage(int tab, Widget page) => Navigator(
    key: tabNavigators.keys[tab],
    observers: [_heroes[tab]],
    onGenerateRoute: (_) => MaterialPageRoute<void>(builder: (_) => page),
  );

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    return BehindSheet(
      child: Scaffold(
        extendBody: true,
        body: IndexedStack(
          index: _tab,
          children: [
            _tabPage(0, HomeScreen(accounts: scope.accounts, player: scope.player, onAccounts: _openAccounts)),
            _tabPage(1, SearchScreen(accounts: scope.accounts, player: scope.player, onAccounts: _openAccounts)),
            _tabPage(
              2,
              LibraryScreen(
                accounts: scope.accounts,
                favorites: scope.favorites,
                player: scope.player,
                onHome: () => _select(0),
                onAccounts: _openAccounts,
              ),
            ),
            _tabPage(_settingsTab, SettingsScreen(accounts: scope.accounts, playback: scope.playbackSettings)),
          ],
        ),
        // The dock fades out in the first part of the full player opening, so it never shows
        // through the panel as it rises.
        bottomNavigationBar: ValueListenableBuilder(
          valueListenable: playerReveal,
          builder: (context, reveal, dock) => IgnorePointer(
            ignoring: reveal > 0,
            child: Opacity(opacity: (1 - reveal / panelFade).clamp(0.0, 1.0), child: dock),
          ),
          child: SafeArea(
            minimum: const EdgeInsets.only(bottom: 4),
            child: _Measured(
              extent: dockExtent,
              child: Dock(
                top: ValueListenableBuilder(
                  valueListenable: dockCompact,
                  builder: (context, compact, player) => AnimatedSize(
                    duration: const Duration(milliseconds: 220),
                    curve: CauceCurves.exit,
                    child: AnimatedOpacity(
                      opacity: compact ? 0 : 1,
                      duration: const Duration(milliseconds: 160),
                      child: compact ? const SizedBox(width: double.infinity) : player,
                    ),
                  ),
                  child: MiniPlayer(player: scope.player),
                ),
                items: _tabs(context),
                selected: _tab,
                onSelected: _select,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Writes how far [child] reaches up from the bottom of the screen into [extent].
class _Measured extends StatefulWidget {
  const _Measured({required this.extent, required this.child});

  final ValueNotifier<double> extent;
  final Widget child;

  @override
  State<_Measured> createState() => _MeasuredState();
}

class _MeasuredState extends State<_Measured> {
  void _measure(Duration _) {
    if (!mounted) return;
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final top = box.localToGlobal(Offset.zero).dy;
    widget.extent.value = MediaQuery.sizeOf(context).height - top;
  }

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback(_measure);
    return NotificationListener<SizeChangedLayoutNotification>(
      onNotification: (_) {
        WidgetsBinding.instance.addPostFrameCallback(_measure);
        return false;
      },
      child: SizeChangedLayoutNotifier(child: widget.child),
    );
  }
}
