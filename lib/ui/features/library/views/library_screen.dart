import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../../../../src/rust/api/player.dart' as core;
import '../../../core/artwork.dart';
import '../../../core/dropdown.dart';
import '../../../core/icons.dart';
import '../../../core/l10n.dart';
import '../../../core/motion.dart';
import '../../../core/selected_service.dart';
import '../../../core/service_picker.dart';
import '../../../core/skeleton.dart';
import '../../../core/theme.dart';
import '../../../core/track_tile.dart';
import '../../../core/widgets.dart';
import '../../accounts/sign_in.dart';
import '../../accounts/view_models/accounts_view_model.dart';
import '../../downloads/downloads_view_model.dart';
import '../../home/views/collection_screen.dart';
import '../../player/view_models/player_view_model.dart';
import '../device_library.dart';
import '../../podcasts/podcasts_section.dart';
import '../../radio/radio_section.dart';
import '../view_models/favorites_view_model.dart';
import '../../../core/toast.dart';
import '../../../core/status_band.dart';

const _audioExtensions = {'.mp3', '.m4a', '.flac', '.ogg', '.opus', '.wav', '.aiff'};
const _files = 'files';
const _downloads = 'downloads';
const _playlists = 'playlists';
const _radio = radioSource;
const _podcasts = podcastSource;

/// How far the list scrolls before the chips are gone and play sits by the title.
const _collapseDistance = 56.0;

/// Picks `slug` in the library and returns the library's own section to show, or null to show
/// the shared provider. Only a provider is written to the selection Home and the other screens
/// share: Playlists, Downloads and Files are the library's own and never replace it.
@visibleForTesting
String? pickLibrarySection(String slug, List<String> providers) {
  if (!providers.contains(slug)) return slug;
  selectedService.select(slug);
  return null;
}

/// The starred tracks of each connected service, the downloads, and the files on the phone.
class LibraryScreen extends StatefulWidget {
  const LibraryScreen({
    super.key,
    required this.accounts,
    required this.favorites,
    required this.player,
    required this.onHome,
    required this.onAccounts,
  });

  final AccountsViewModel accounts;
  final FavoritesViewModel favorites;
  final PlayerViewModel player;

  /// Opens the home tab, from an empty list.
  final VoidCallback onHome;

  /// Opens the accounts, to connect another provider.
  final VoidCallback onAccounts;

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  List<File> _localFiles = [];

  /// Folders picked in the Files app, with their audio files.
  List<PickedFolder> _folders = [];

  /// The listener's own playlists of every connected provider, loaded when first shown.
  Future<List<(String, core.PlaylistItem)>>? _ownPlaylists;

  /// How far the chips have collapsed into the title, from 0 to 1, following the scroll.
  final _collapse = ValueNotifier<double>(0);

  /// The phone's Music library, read the first time Files is opened: reading it asks for
  /// access, which should not pop up on launch.
  List<DeviceSong>? _deviceSongs;

  /// The device song being exported before it plays.
  String? _preparing;

  @override
  void initState() {
    super.initState();
    _refreshFiles();
  }

  @override
  void dispose() {
    _collapse.dispose();
    super.dispose();
  }

  Future<void> _refreshFiles() async {
    try {
      final folders = await PickedFolders.list();
      if (mounted) setState(() => _folders = folders);
    } on Object {
      // The folders are read again on the next refresh.
    }
    final documents = await getApplicationDocumentsDirectory();
    final files =
        documents
            .listSync()
            .whereType<File>()
            .where((file) => _audioExtensions.any(file.path.toLowerCase().endsWith))
            .toList()
          ..sort((a, b) => a.path.toLowerCase().compareTo(b.path.toLowerCase()));
    if (mounted) setState(() => _localFiles = files);
  }

  Future<List<(String, core.PlaylistItem)>> _loadPlaylists(List<StreamingService> connected) async {
    final lists = await Future.wait([
      for (final service in connected)
        core
            .ownPlaylists(slug: service.slug)
            .then((playlists) => [for (final playlist in playlists) (service.slug, playlist)])
            // One provider failing leaves the others' playlists.
            .catchError((Object _) => <(String, core.PlaylistItem)>[]),
    ]);
    return [for (final list in lists) ...list]
      ..sort((a, b) => a.$2.name.toLowerCase().compareTo(b.$2.name.toLowerCase()));
  }

  /// What the play button by the title plays for `source`, or nothing when it has no songs.
  VoidCallback? _playAll(String source) {
    switch (source) {
      case _playlists || _radio || _podcasts:
        return null;
      case _downloads:
        final tracks = downloads.done;
        return tracks.isEmpty ? null : () => widget.player.playQueue(tracks, 0);
      case _files:
        if (_deviceSongs?.isNotEmpty ?? false) return () => _playDevice(0);
        final paths = [for (final file in _localFiles) file.path, for (final folder in _folders) ...folder.files];
        return paths.isEmpty ? null : () => widget.player.playFiles(paths, 0);
      default:
        final tracks = widget.favorites.tracks(source);
        return tracks.isEmpty ? null : () => widget.player.playQueue(tracks, 0);
    }
  }

  void _choose(String source) {
    _collapse.value = 0;
    final section = pickLibrarySection(source, [for (final service in widget.accounts.connected) service.slug]);
    setState(() => _section = section);
    if (section == null && widget.favorites.tracks(source).isEmpty) widget.favorites.load(source);
  }

  /// Playlists, Downloads or Files when one is open, null while the provider's likes show.
  String? _section;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([
        widget.accounts,
        widget.favorites,
        widget.player,
        selectedService,
        downloads,
        online,
      ]),
      builder: (context, _) {
        final connected = widget.accounts.connected;
        final provider = selectedService.among([for (final service in connected) service.slug]);
        final section = _section == _playlists && connected.isEmpty ? null : _section;
        final source = section ?? provider ?? _downloads;
        final play = _playAll(source);
        final still = MediaQuery.disableAnimationsOf(context);
        return Scaffold(
          body: SafeArea(
            bottom: false,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                PageTitle(
                  context.t('tab.library'),
                  // Play rises into the title row as the chips scroll away.
                  trailing: play == null
                      ? null
                      : ValueListenableBuilder(
                          valueListenable: _collapse,
                          builder: (context, collapse, child) => IgnorePointer(
                            ignoring: collapse < 0.5,
                            child: Opacity(
                              opacity: collapse,
                              child: Transform.translate(
                                offset: Offset(0, still ? 0 : (1 - collapse) * 14),
                                child: child,
                              ),
                            ),
                          ),
                          child: GestureDetector(
                            onTap: play,
                            child: Container(
                              width: 40,
                              height: 40,
                              decoration: BoxDecoration(color: CauceColors.accent, shape: BoxShape.circle),
                              alignment: Alignment.center,
                              child: CauceIcon(CauceGlyph.play, size: 17, color: CauceColors.onAccent),
                            ),
                          ),
                        ),
                ),
                StatusBands(
                  accounts: widget.accounts,
                  onAccounts: widget.onAccounts,
                  onDownloads: () => _choose(_downloads),
                ),
                ValueListenableBuilder(
                  valueListenable: _collapse,
                  builder: (context, collapse, child) => IgnorePointer(
                    ignoring: collapse > 0.5,
                    child: ClipRect(
                      child: Align(
                        alignment: Alignment.topCenter,
                        heightFactor: still ? 1 : 1 - collapse,
                        child: Opacity(opacity: 1 - collapse, child: child),
                      ),
                    ),
                  ),
                  child: Column(
                    children: [
                      SizedBox(
                        height: 34,
                        child: ListView(
                          scrollDirection: Axis.horizontal,
                          padding: const EdgeInsets.symmetric(horizontal: CauceMetrics.gutter),
                          children: [
                            if (provider != null)
                              Builder(
                                builder: (context) => Pill(
                                  label: connected.firstWhere((service) => service.slug == provider).name,
                                  dot: brandOf(provider).color,
                                  chevron: true,
                                  selected: source == provider,
                                  onTap: () => source == provider
                                      ? _pickProvider(context, connected, provider)
                                      : _choose(provider),
                                ),
                              ),
                            for (final (slug, label) in [
                              if (connected.isNotEmpty) (_playlists, context.t('library.playlists')),
                              (_downloads, context.t('downloads.title')),
                              (_files, context.t('library.files')),
                              (_radio, context.t('library.radio')),
                              (_podcasts, context.t('library.podcasts')),
                            ])
                              Padding(
                                padding: const EdgeInsets.only(left: 8),
                                child: Pill(label: label, selected: source == slug, onTap: () => _choose(slug)),
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 10),
                    ],
                  ),
                ),
                Expanded(
                  // A fling sideways moves to the chip beside the one picked, in the row's order.
                  child: GestureDetector(
                    onHorizontalDragEnd: (details) {
                      final velocity = details.primaryVelocity ?? 0;
                      if (velocity.abs() < 300) return;
                      final order = [
                        ?provider,
                        if (connected.isNotEmpty) _playlists,
                        _downloads,
                        _files,
                        _radio,
                        _podcasts,
                      ];
                      final next = order.indexOf(source) + (velocity < 0 ? 1 : -1);
                      if (next >= 0 && next < order.length) _choose(order[next]);
                    },
                    child: NotificationListener<ScrollNotification>(
                      onNotification: (notification) {
                        if (notification.depth == 0 && notification.metrics.axis == Axis.vertical) {
                          _collapse.value = (notification.metrics.pixels / _collapseDistance).clamp(0.0, 1.0);
                        }
                        return false;
                      },
                      child: switch (source) {
                        _files => _filesList(),
                        _radio => RadioSection(player: widget.player, favorites: widget.favorites),
                        _podcasts => PodcastsSection(player: widget.player),
                        _downloads => _downloadsList(),
                        _playlists => _playlistsList(connected),
                        _ => _favoritesList(source),
                      },
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  static const _connectOther = 'connect-other';

  /// A menu under the provider pill to switch to another connected one, sign in again to one
  /// whose session lapsed, or connect another.
  Future<void> _pickProvider(BuildContext context, List<StreamingService> connected, String current) async {
    final lapsed = [
      for (final service in streamingServices)
        if (widget.accounts.error(service.slug) != null && !connected.contains(service)) service,
    ];
    final picked = await showDropdown<String>(
      context,
      items: [
        for (final service in connected)
          DropdownItem(
            value: service.slug,
            leading: BrandBadge(slug: service.slug, size: 30),
            title: service.name,
            subtitle: widget.favorites.tracks(service.slug).isEmpty
                ? null
                : context.t('library.likedCount', {'count': widget.favorites.tracks(service.slug).length}),
            selected: service.slug == current,
          ),
        for (final service in lapsed)
          DropdownItem(
            value: service.slug,
            leading: BrandBadge(slug: service.slug, size: 30),
            title: service.name,
            subtitle: context.t('providers.expired'),
            subtitleColor: const Color(0xFFF0B04A),
          ),
      ],
      footer: [
        DropdownItem(
          value: _connectOther,
          leading: const DropdownPlus(),
          title: context.t('library.connectOther'),
          color: CauceColors.accent,
        ),
      ],
    );
    if (!context.mounted || picked == null) return;
    if (picked == _connectOther) return widget.onAccounts();
    if (lapsed.where((service) => service.slug == picked).firstOrNull case final service?) {
      return signIn(context, service, widget.accounts);
    }
    _choose(picked);
  }

  Widget _favoritesList(String slug) {
    final favorites = widget.favorites;
    final tracks = favorites.tracks(slug);
    final current = widget.player.track;
    final name = streamingServices.firstWhere((service) => service.slug == slug).name;
    return RefreshIndicator(
      color: CauceColors.foreground,
      onRefresh: () => favorites.load(slug),
      child: ListView(
        padding: const EdgeInsets.only(bottom: bottomChromeInset),
        children: [
          if (favorites.loading(slug) && tracks.isEmpty) const TrackListSkeleton(),
          if (favorites.error(slug) case final error?)
            Padding(
              padding: const EdgeInsets.only(top: 100),
              child: EmptyState(
                glyph: CauceGlyph.alert,
                badge: true,
                danger: true,
                title: context.t('common.error'),
                message: error,
                actions: [FilledButton(onPressed: () => favorites.load(slug), child: Text(context.t('common.retry')))],
              ),
            ),
          if (!favorites.loading(slug) && tracks.isEmpty && favorites.error(slug) == null)
            Padding(
              padding: const EdgeInsets.only(top: 100),
              child: EmptyState(
                glyph: CauceGlyph.heart,
                title: context.t('library.likedNone', {'service': name}),
                message: context.t('library.likedEmpty'),
                actions: [SoftButton(label: context.t('library.goHome'), onPressed: widget.onHome)],
              ),
            ),
          if (tracks.isNotEmpty)
            _CollectionHeader(
              art: Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(color: CauceColors.accent, borderRadius: BorderRadius.circular(12)),
                alignment: Alignment.center,
                child: CauceIcon(CauceGlyph.heartFilled, size: 28, color: CauceColors.onAccent),
              ),
              title: context.t('track.like'),
              subtitle: context.t('playlist.count', {'count': tracks.length}),
              onPlay: () => widget.player.playQueue(tracks, 0),
            ),
          for (final (index, track) in tracks.indexed)
            TrackTile(
              track: track,
              playing: current?.id == track.id && current?.source == track.source,
              onTap: () => widget.player.playQueue(tracks, index),
            ),
        ],
      ),
    );
  }

  Widget _downloadsList() {
    final tracks = downloads.done;
    final pending = [
      for (final item in downloads.items)
        if (item.state != core.DownloadState.done) item.track,
    ];
    final current = widget.player.track;
    void play(core.TrackItem track) => widget.player.playQueue(tracks, tracks.indexOf(track));

    Widget tile(core.TrackItem track, VoidCallback onTap) => Dismissible(
      key: ValueKey('${track.source}/${track.id}'),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 22),
        color: const Color(0xFFE5383B),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CauceIcon(CauceGlyph.trash, size: 20, weight: 2),
            const SizedBox(height: 4),
            Text(context.t('downloads.delete'), style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
          ],
        ),
      ),
      // Deleting asks nothing: it can be undone until the toast goes.
      onDismissed: (_) {
        downloads.hide(track);
        showToast(
          Toast(
            title: context.t('downloads.deleted'),
            detail: '${track.title} · ${track.artists}',
            cover: track.cover,
            onUndo: () => downloads.unhide(track),
            onGone: () => downloads.forget(track).ignore(),
          ),
        );
      },
      child: TrackTile(
        track: track,
        mixed: true,
        playing: current?.id == track.id && current?.source == track.source,
        onTap: onTap,
      ),
    );
    return RefreshIndicator(
      color: CauceColors.foreground,
      onRefresh: downloads.refresh,
      child: ListView(
        padding: const EdgeInsets.only(bottom: bottomChromeInset),
        children: [
          if (tracks.isEmpty && pending.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 100),
              child: EmptyState(
                glyph: CauceGlyph.download,
                title: context.t('downloads.none'),
                message: context.t('downloads.empty'),
              ),
            ),
          if (tracks.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(CauceMetrics.gutter, 6, CauceMetrics.gutter, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      context.t('playlist.count', {'count': tracks.length}),
                      style: TextStyle(fontSize: 15, color: CauceColors.mutedForeground),
                    ),
                  ),
                  AccentButton(label: context.t('downloads.playAll'), onPressed: () => play(tracks.first)),
                ],
              ),
            ),
          if (pending.isNotEmpty) ...[
            Overline('${context.t('downloads.inProgress')} · ${pending.length}'),
            for (final track in pending) tile(track, () => downloads.download([track])),
          ],
          if (tracks.isNotEmpty) ...[
            Overline(context.t('downloads.done')),
            for (final track in tracks) tile(track, () => play(track)),
          ],
        ],
      ),
    );
  }

  Future<void> _loadDevice() async {
    final songs = await DeviceLibrary.songs();
    if (mounted) setState(() => _deviceSongs = songs);
  }

  Future<void> _playDevice(int index) async {
    final songs = _deviceSongs!;
    setState(() => _preparing = songs[index].id);
    final paths = await DeviceLibrary.ready(songs, index);
    if (!mounted) return;
    setState(() => _preparing = null);
    if (paths.isEmpty) {
      showToast(Toast(title: context.t('library.protected'), tone: ToastTone.error));
      return;
    }
    await widget.player.playFiles(paths, 0);
  }

  Widget _playlistsList(List<StreamingService> connected) {
    final loading = _ownPlaylists ??= _loadPlaylists(connected);
    return RefreshIndicator(
      color: CauceColors.foreground,
      onRefresh: () async {
        final reload = _loadPlaylists(connected);
        setState(() => _ownPlaylists = reload);
        await reload;
      },
      child: FutureBuilder(
        future: loading,
        builder: (context, snapshot) => ListView(
          padding: const EdgeInsets.only(bottom: bottomChromeInset),
          children: [
            if (snapshot.connectionState != ConnectionState.done)
              const TrackListSkeleton(count: 6)
            else if (snapshot.data?.isEmpty ?? true)
              Padding(
                padding: const EdgeInsets.only(top: 100),
                child: EmptyState(glyph: CauceGlyph.library, title: context.t('library.playlistsNone')),
              )
            else
              for (final (slug, playlist) in snapshot.data!)
                Builder(
                  builder: (context) {
                    final service = connected.firstWhere((service) => service.slug == slug).name;
                    return _FileRow(
                      leading: Stack(
                        clipBehavior: Clip.none,
                        children: [
                          Artwork(url: playlist.cover, size: 48, radius: 8),
                          Positioned(right: -4, bottom: -4, child: BrandBadge(slug: slug, size: 18)),
                        ],
                      ),
                      title: playlist.name,
                      subtitle: playlist.trackCount == 0
                          ? service
                          : '$service · ${context.t('playlist.count', {'count': playlist.trackCount})}',
                      onTap: () => Navigator.of(context).push(
                        CoverRoute<void>(
                          builder: (_) => CollectionScreen(
                            slug: slug,
                            card: core.MediaCard(
                              kind: core.CardKind.playlist,
                              id: playlist.id,
                              title: playlist.name,
                              subtitle: service,
                              cover: playlist.cover,
                            ),
                            player: widget.player,
                          ),
                        ),
                      ),
                    );
                  },
                ),
          ],
        ),
      ),
    );
  }

  /// A file's row, playing the files in `paths` from it.
  Widget _fileTile(List<String> paths, int index) {
    final name = paths[index].split('/').last;
    final dot = name.lastIndexOf('.');
    final title = dot > 0 ? name.substring(0, dot) : name;
    return _FileRow(
      leading: InitialAvatar(name: title, round: false),
      title: title,
      subtitle: dot > 0 ? name.substring(dot + 1).toUpperCase() : '',
      onTap: () => widget.player.playFiles(paths, index),
    );
  }

  Future<void> _addFolder() async {
    if (await PickedFolders.add()) await _refreshFiles();
  }

  Widget _filesList() {
    final paths = [for (final file in _localFiles) file.path];
    final device = _deviceSongs;
    if (device == null) WidgetsBinding.instance.addPostFrameCallback((_) => _loadDevice());
    return RefreshIndicator(
      color: CauceColors.foreground,
      onRefresh: () => Future.wait([_refreshFiles(), _loadDevice()]),
      child: ListView(
        padding: const EdgeInsets.only(bottom: bottomChromeInset),
        children: [
          if (device == null)
            const TrackListSkeleton(count: 6)
          else if (device.isNotEmpty) ...[
            SectionHeader(context.t('library.onDevice'), count: device.length),
            for (final (index, song) in device.indexed)
              _FileRow(
                leading: Artwork(url: song.cover, size: 48, radius: 8),
                title: song.title,
                subtitle: [song.artist, song.album].where((part) => part.isNotEmpty).join(' · '),
                trailing: _preparing == song.id
                    ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : Text(
                        formatDuration(song.duration),
                        style: TextStyle(fontSize: 14, color: CauceColors.mutedForeground),
                      ),
                onTap: _preparing == null ? () => _playDevice(index) : null,
              ),
          ],
          if (_localFiles.isNotEmpty) SectionHeader(context.t('library.copied'), count: _localFiles.length),
          for (var index = 0; index < paths.length; index++) _fileTile(paths, index),
          for (final folder in _folders) ...[
            SectionHeader(
              folder.name,
              count: folder.files.length,
              action: context.t('library.removeFolder'),
              onAction: () async {
                await PickedFolders.remove(folder.name);
                await _refreshFiles();
              },
            ),
            for (var index = 0; index < folder.files.length; index++) _fileTile(folder.files, index),
          ],
          if (device != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(CauceMetrics.gutter, 20, CauceMetrics.gutter, 0),
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: CauceColors.foreground.withValues(alpha: 0.16)),
                ),
                child: Row(
                  children: [
                    CauceIcon(CauceGlyph.folder, size: 20, color: CauceColors.accent),
                    const SizedBox(width: 12),
                    Expanded(child: Text(context.t('library.filesHint'), style: CauceText.caption)),
                  ],
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(CauceMetrics.gutter, 12, CauceMetrics.gutter, 0),
            child: SoftButton(label: context.t('library.addFolder'), glyph: CauceGlyph.folder, onPressed: _addFolder),
          ),
        ],
      ),
    );
  }
}

/// A file's row: the same shape as a track's, without the options.
class _FileRow extends StatelessWidget {
  const _FileRow({required this.leading, required this.title, required this.subtitle, this.trailing, this.onTap});

  final Widget leading;
  final String title;
  final String subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 7, 20, 7),
        child: Row(
          children: [
            leading,
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 16)),
                  const SizedBox(height: 3),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 13.5, color: CauceColors.mutedForeground),
                  ),
                ],
              ),
            ),
            ?trailing,
          ],
        ),
      ),
    );
  }
}

/// A list's own header: its art, name and count, and a round play button.
class _CollectionHeader extends StatelessWidget {
  const _CollectionHeader({required this.art, required this.title, required this.subtitle, required this.onPlay});

  final Widget art;
  final String title;
  final String subtitle;
  final VoidCallback onPlay;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(CauceMetrics.gutter, 8, CauceMetrics.gutter, 12),
      child: Row(
        children: [
          art,
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: CauceText.section),
                const SizedBox(height: 2),
                Text(subtitle, style: TextStyle(fontSize: 15, color: CauceColors.mutedForeground)),
              ],
            ),
          ),
          GestureDetector(
            onTap: onPlay,
            child: Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(color: CauceColors.accent, shape: BoxShape.circle),
              alignment: Alignment.center,
              child: CauceIcon(CauceGlyph.play, size: 20, color: CauceColors.onAccent),
            ),
          ),
        ],
      ),
    );
  }
}
