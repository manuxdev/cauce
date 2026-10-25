import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../../../../src/rust/api/player.dart' as core;
import '../../../core/across_providers.dart';
import '../../../core/app_prefs.dart';
import '../../../core/artwork.dart';
import '../../../core/cards.dart';
import '../../../core/icons.dart';
import '../../../core/l10n.dart';
import '../../../core/motion.dart';
import '../../../core/selected_service.dart';
import '../../../core/service_picker.dart';
import '../../../core/skeleton.dart';
import '../../../core/theme.dart';
import '../../../core/tint.dart';
import '../../../core/tint_scope.dart';
import '../../../core/track_tile.dart';
import '../../../core/widgets.dart';
import '../../accounts/view_models/accounts_view_model.dart';
import '../../artist/views/artist_screen.dart';
import '../../downloads/downloads_view_model.dart';
import '../../home/views/collection_screen.dart';
import '../../player/view_models/player_view_model.dart';
import '../recent_searches.dart';
import 'genre_screen.dart';
import '../../../core/status_band.dart';
import '../../../core/error_text.dart';

/// How long typing has to pause before the query goes out, so a word costs one request rather
/// than one per letter.
const _debounce = Duration(milliseconds: 350);
const _motion = Duration(milliseconds: 260);

/// The hues of the styles a service shows without a picture, as the design tints them.
const _hues = <double>[350, 140, 265, 60, 20, 230, 190, 320, 165, 45];

/// Searches the service picked, or the downloads, as the user types. Before a query, styles to
/// browse by; while the field is focused, what search found lately.
class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key, required this.accounts, required this.player, required this.onAccounts});

  final AccountsViewModel accounts;
  final PlayerViewModel player;

  /// Opens the accounts tab, for when nothing is connected yet.
  final VoidCallback onAccounts;

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final _query = TextEditingController();
  final _focus = FocusNode();

  /// Keeps the field, and its focus, as it moves between the browse page and the search page.
  final _fieldKey = GlobalKey();

  /// How far the field rose when it took focus, and the title's height above it, so it can come back down.
  double _rise = 0;
  double _titleExtent = 0;
  double _browseOffset = 0;

  /// Searching the downloads instead of a service.
  bool _inLibrary = false;

  /// Searching every connected provider at once, when the setting offers it.
  bool _all = false;
  bool get _everywhere => _all && !_inLibrary && appPrefs.searchAll && widget.accounts.connected.length > 1;
  bool _searching = false;
  String? _error;
  List<core.TrackItem> _tracks = [];
  List<core.MediaCard> _albums = [];
  Timer? _pending;

  /// Each service's styles, asked for once.
  final Map<String, Future<List<core.GenreCard>>> _genreLists = {};

  /// Counts searches sent, so an answer to a query the user has typed past is dropped.
  int _sent = 0;

  String? get _slug => selectedService.among([for (final service in widget.accounts.connected) service.slug]);
  String get _text => _query.text.trim();

  /// Focused or holding a query: the field rises and the scope buttons show.
  bool get _active => _focus.hasFocus || _text.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (_focus.hasFocus && _text.isEmpty) _measure();
      setState(() {});
    });
  }

  void _measure() {
    final field = _fieldKey.currentContext?.findRenderObject() as RenderBox?;
    final page = context.findRenderObject() as RenderBox?;
    if (field == null || page == null || !field.attached) return;
    final top = field.localToGlobal(Offset.zero, ancestor: page).dy - MediaQuery.paddingOf(context).top;
    _rise = (top - 8).clamp(0.0, double.infinity);
    _titleExtent = _rise + _browseOffset;
    _browseOffset = 0;
  }

  @override
  void dispose() {
    _pending?.cancel();
    _query.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _typed(String _) {
    _pending?.cancel();
    if (_text.isEmpty) {
      _sent++;
      setState(() {
        _tracks = [];
        _albums = [];
        _searching = false;
        _error = null;
      });
      return;
    }
    setState(() => _searching = !_inLibrary);
    if (!_inLibrary) _pending = Timer(_debounce, _search);
  }

  /// Searches `query` straight away, as a tap on a style or a recent query does.
  void _searchFor(String query) {
    _query.text = query;
    _query.selection = TextSelection.collapsed(offset: query.length);
    recentSearches.addQuery(query);
    _typed(query);
    _search();
  }

  Future<void> _search() async {
    _pending?.cancel();
    final slug = _slug;
    final query = _text;
    if (_inLibrary || slug == null || query.isEmpty) return;
    final sent = ++_sent;
    setState(() {
      _searching = true;
      _error = null;
    });
    try {
      if (_everywhere) {
        // One provider failing leaves the others' results.
        final slugs = ordered([for (final service in widget.accounts.connected) service.slug], appPrefs.providerOrder);
        final found = await Future.wait([
          for (final slug in slugs) core.search(slug: slug, query: query).catchError((Object _) => <core.TrackItem>[]),
        ]);
        if (mounted && sent == _sent) {
          setState(() {
            _tracks = interleave(found);
            _albums = [];
            _searching = false;
          });
        }
        return;
      }
      // Albums are a bonus: a service that cannot search them still finds tracks.
      final albumsFound = core.searchAlbums(slug: slug, query: query).catchError((Object _) => <core.MediaCard>[]);
      final tracks = await core.search(slug: slug, query: query);
      final albums = await albumsFound;
      if (mounted && sent == _sent) {
        setState(() {
          _tracks = tracks;
          _albums = albums;
        });
      }
    } catch (error) {
      if (mounted && sent == _sent) setState(() => _error = explainError(error));
    }
    if (mounted && sent == _sent) setState(() => _searching = false);
  }

  void _cancel() {
    _query.clear();
    _typed('');
    _focus.unfocus();
  }

  void _scope({required bool library, String? slug, bool all = false}) {
    if (slug != null) selectedService.select(slug);
    setState(() {
      _inLibrary = library;
      _all = all;
    });
    _typed(_query.text);
    if (!library) _search();
  }

  void _openArtist(String slug, core.ArtistLink artist) {
    recentSearches.addArtist(slug, artist);
    Navigator.of(context).push(
      CoverRoute<void>(
        builder: (_) => ArtistScreen(slug: slug, artist: artist, player: widget.player),
      ),
    );
  }

  void _openAlbum(String slug, core.MediaCard album, [Object? heroTag]) {
    recentSearches.addAlbum(slug, album);
    Navigator.of(context).push(
      CoverRoute<void>(
        builder: (_) => CollectionScreen(slug: slug, card: album, player: widget.player, heroTag: heroTag),
      ),
    );
  }

  void _play(List<core.TrackItem> tracks, int index) {
    recentSearches.addTrack(tracks[index]);
    if (_text.isNotEmpty) recentSearches.addQuery(_text);
    widget.player.playQueue(tracks, index);
  }

  @override
  Widget build(BuildContext context) {
    // Search keeps its own neutral grey whatever plays.
    return TintScope(
      tint: Tint.neutral,
      child: ColoredBox(
        color: CauceColors.background,
        child: Scaffold(
          body: SafeArea(
            bottom: false,
            child: ListenableBuilder(
              listenable: Listenable.merge([
                widget.accounts,
                widget.player,
                selectedService,
                appPrefs,
                recentSearches,
                downloads,
              ]),
              builder: (context, _) {
                final connected = widget.accounts.connected;
                if (connected.isEmpty && !_inLibrary) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      PageTitle(context.t('tab.search')),
                      Expanded(
                        child: NothingConnected(
                          message: context.t('search.nothingConnected'),
                          onAccounts: widget.onAccounts,
                        ),
                      ),
                    ],
                  );
                }
                if (!_active) return _browse(context);
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // The field rises from under the title to the top.
                    TweenAnimationBuilder<double>(
                      tween: Tween(begin: 8 + _rise, end: 8),
                      duration: _motion,
                      curve: CauceCurves.exit,
                      builder: (context, height, _) => SizedBox(height: height),
                    ),
                    _field(context),
                    Arrive(child: _scopes(connected)),
                    Expanded(
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 200),
                        child: KeyedSubtree(key: ValueKey((_text.isEmpty, _inLibrary)), child: _body(context)),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _field(BuildContext context) {
    return KeyedSubtree(
      key: _fieldKey,
      child: Padding(
        padding: EdgeInsets.fromLTRB(CauceMetrics.gutter, 0, _active ? 8 : CauceMetrics.gutter, 0),
        child: Row(
          children: [
            Expanded(
              child: SizedBox(
                height: 42,
                child: TextField(
                  controller: _query,
                  focusNode: _focus,
                  textInputAction: TextInputAction.search,
                  onChanged: _typed,
                  onSubmitted: (query) {
                    recentSearches.addQuery(query);
                    _search();
                  },
                  style: const TextStyle(fontSize: 17),
                  decoration: InputDecoration(
                    prefixIcon: Padding(
                      padding: EdgeInsets.only(left: 12, right: 8),
                      child: CauceIcon(CauceGlyph.search, size: 19, color: CauceColors.mutedForeground, weight: 2.1),
                    ),
                    prefixIconConstraints: const BoxConstraints(minWidth: 0, minHeight: 0),
                    suffixIcon: _text.isEmpty
                        ? null
                        : GestureDetector(
                            onTap: () {
                              _query.clear();
                              _typed('');
                            },
                            child: Center(
                              widthFactor: 1,
                              child: Container(
                                width: 18,
                                height: 18,
                                margin: const EdgeInsets.only(right: 12),
                                decoration: const BoxDecoration(color: Color(0x59FFFFFF), shape: BoxShape.circle),
                                child: CauceIcon(CauceGlyph.close, size: 10, color: CauceColors.background, weight: 3),
                              ),
                            ),
                          ),
                    hintText: _inLibrary
                        ? context.t('search.libraryHint')
                        : _everywhere
                        ? context.t('search.inAll')
                        : _active && _slug != null
                        ? context.t('search.in', {'service': _serviceName(_slug!)})
                        : context.t('search.hint'),
                  ),
                ),
              ),
            ),
            AnimatedSize(
              duration: _motion,
              curve: CauceCurves.exit,
              child: _active
                  ? TextButton(onPressed: _cancel, child: Text(context.t('search.cancel')))
                  : const SizedBox.shrink(),
            ),
          ],
        ),
      ),
    );
  }

  String _serviceName(String slug) =>
      streamingServices.firstWhere((service) => service.slug == slug, orElse: () => StreamingService(slug, slug)).name;

  /// The services and the downloads, side by side. While the listener types, the scope being
  /// searched leads, so it is in view whatever the order.
  Widget _scopes(List<StreamingService> connected) {
    bool picked(String slug) => !_inLibrary && !_everywhere && slug == _slug;
    final pills = <(bool, Widget)>[
      if (appPrefs.searchAll && connected.length > 1)
        (
          _everywhere,
          Pill(
            key: const ValueKey('all'),
            label: context.t('search.all'),
            selected: _everywhere,
            onTap: () => _scope(library: false, all: true),
          ),
        ),
      for (final service in connected)
        (
          picked(service.slug),
          Pill(
            key: ValueKey(service.slug),
            label: service.name,
            dot: brandOf(service.slug).color,
            selected: picked(service.slug),
            onTap: () => _scope(library: false, slug: service.slug),
          ),
        ),
      (
        _inLibrary,
        Pill(
          key: const ValueKey('downloads'),
          label: context.t('downloads.title'),
          glyph: CauceGlyph.download,
          selected: _inLibrary,
          onTap: () => _scope(library: true),
        ),
      ),
    ];
    final shown = _active ? [...pills.where((pill) => pill.$1), ...pills.where((pill) => !pill.$1)] : pills;
    return SizedBox(
      height: 58,
      child: ListView(
        // A new order starts from the left, where the active scope now is.
        key: ValueKey(_active),
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(CauceMetrics.gutter, 12, CauceMetrics.gutter, 12),
        children: [
          for (final (index, (_, pill)) in shown.indexed)
            Padding(
              padding: EdgeInsets.only(right: index == shown.length - 1 ? 0 : 8),
              child: pill,
            ),
        ],
      ),
    );
  }

  Widget _body(BuildContext context) {
    if (_text.isNotEmpty) return _inLibrary ? _libraryResults(context) : _results(context);
    return _recent(context);
  }

  Future<List<core.GenreCard>> _genres(String slug) => _genreLists.putIfAbsent(slug, () => core.genres(slug: slug));

  Widget _browse(BuildContext context) {
    final slug = _slug;
    return FutureBuilder(
      future: slug == null ? null : _genres(slug),
      builder: (context, snapshot) {
        final genres = snapshot.data ?? const <core.GenreCard>[];
        // Back from searching, the title comes down from above as the field drops under it.
        return TweenAnimationBuilder<double>(
          tween: Tween(begin: -_titleExtent, end: 0),
          duration: _motion,
          curve: CauceCurves.exit,
          builder: (context, shift, child) => Transform.translate(offset: Offset(0, shift), child: child),
          child: NotificationListener<ScrollUpdateNotification>(
            onNotification: (notification) {
              if (notification.depth == 0) _browseOffset = notification.metrics.pixels;
              return false;
            },
            child: CustomScrollView(
              slivers: [
                SliverToBoxAdapter(child: PageTitle(context.t('tab.search'))),
                SliverToBoxAdapter(
                  child: StatusBands(accounts: widget.accounts, onAccounts: widget.onAccounts),
                ),
                // The field scrolls up with the title, then stays at the top on a frosted bar.
                SliverPersistentHeader(pinned: true, delegate: _FieldBar(_field(context))),
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(CauceMetrics.gutter, 22, CauceMetrics.gutter, 12),
                  sliver: SliverToBoxAdapter(child: Text(context.t('search.browse'), style: CauceText.section)),
                ),
                if (snapshot.hasError)
                  SliverPadding(
                    padding: const EdgeInsets.symmetric(horizontal: CauceMetrics.gutter),
                    sliver: SliverToBoxAdapter(
                      child: Text(
                        explainError(snapshot.error!),
                        style: TextStyle(color: Theme.of(context).colorScheme.error),
                      ),
                    ),
                  ),
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(CauceMetrics.gutter, 0, CauceMetrics.gutter, bottomChromeInset),
                  sliver: SliverGrid.count(
                    crossAxisCount: 2,
                    mainAxisSpacing: 10,
                    crossAxisSpacing: 10,
                    childAspectRatio: 2.02,
                    children: [
                      if (snapshot.connectionState == ConnectionState.waiting)
                        for (var bone = 0; bone < 8; bone++)
                          const Skeleton(
                            child: Bone(height: double.infinity, radius: CauceMetrics.artworkRadius),
                          ),
                      for (final (index, genre) in genres.indexed)
                        _GenreCard(
                          genre: genre,
                          hue: _hues[index % _hues.length],
                          onTap: () => Navigator.of(context).push(
                            CoverRoute<void>(
                              builder: (_) => GenreScreen(
                                slug: slug!,
                                genre: genre,
                                hue: _hues[index % _hues.length],
                                player: widget.player,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _recent(BuildContext context) {
    final items = recentSearches.items;
    if (items.isEmpty) return const SizedBox.shrink();
    return ListView(
      padding: const EdgeInsets.only(bottom: bottomChromeInset),
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      children: [
        SectionHeader(context.t('search.recent'), action: context.t('search.clear'), onAction: recentSearches.clear),
        for (final (index, item) in items.indexed)
          Arrive(
            delay: Duration(milliseconds: 30 * index.clamp(0, 8)),
            child: _recentTile(context, item),
          ),
      ],
    );
  }

  Widget _recentTile(BuildContext context, Recent item) {
    final (Widget leading, String? subtitle, VoidCallback onTap) = switch (item.kind) {
      RecentKind.query => (
        Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(color: CauceColors.secondary, borderRadius: BorderRadius.circular(8)),
          alignment: Alignment.center,
          child: CauceIcon(CauceGlyph.search, size: 18, color: CauceColors.mutedForeground, weight: 2.1),
        ),
        null,
        () => _searchFor(item.title),
      ),
      RecentKind.track => (
        Artwork(url: item.cover, size: 48, radius: 8),
        context.t('search.song', {'artist': item.subtitle}),
        () => _play([item.track!], 0),
      ),
      RecentKind.artist => (
        item.cover == null ? InitialAvatar(name: item.title) : Artwork(url: item.cover, size: 48, radius: 24),
        context.t('search.artist'),
        () => _openArtist(item.source, core.ArtistLink(id: item.id, name: item.title)),
      ),
      RecentKind.album => (
        Artwork(url: item.cover, size: 48, radius: 8),
        context.t('search.album', {'artist': item.subtitle}),
        () => _openAlbum(
          item.source,
          core.MediaCard(
            kind: core.CardKind.album,
            id: item.id,
            title: item.title,
            subtitle: item.subtitle,
            cover: item.cover,
          ),
        ),
      ),
    };
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(CauceMetrics.gutter, 7, 8, 7),
        child: Row(
          children: [
            leading,
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(item.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 16)),
                  if (subtitle != null)
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 13.5, color: CauceColors.mutedForeground),
                    ),
                ],
              ),
            ),
            IconButton(
              tooltip: context.t('search.remove'),
              onPressed: () => recentSearches.remove(item),
              icon: CauceIcon(CauceGlyph.close, size: 16, color: CauceColors.mutedForeground),
            ),
          ],
        ),
      ),
    );
  }

  Widget _results(BuildContext context) {
    final slug = _slug!;
    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.all(CauceMetrics.gutter),
        child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
      );
    }
    if (_searching && _tracks.isEmpty) {
      return const SingleChildScrollView(physics: NeverScrollableScrollPhysics(), child: TrackListSkeleton(count: 10));
    }
    if (_tracks.isEmpty && _albums.isEmpty) return _nothing(context);
    final artists = <String, (String, core.ArtistLink)>{
      for (final track in _tracks)
        for (final artist in track.artistLinks) artist.id: (track.source, artist),
    }.values.take(12).toList();
    final current = widget.player.track;
    return AnimatedOpacity(
      // Stale results stay put, dimmed, until the new ones land.
      opacity: _searching ? 0.5 : 1,
      duration: const Duration(milliseconds: 150),
      child: ListView(
        padding: const EdgeInsets.only(bottom: bottomChromeInset),
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        children: [
          // Each landing of results comes in group by group, 30 ms apart.
          if (artists.isNotEmpty)
            Arrive(
              key: ObjectKey((_tracks, 'artists')),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SectionHeader(context.t('search.artists')),
                  SizedBox(
                    height: 56,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: CauceMetrics.gutter),
                      itemCount: artists.length,
                      separatorBuilder: (_, _) => const SizedBox(width: 18),
                      itemBuilder: (context, index) {
                        final (source, artist) = artists[index];
                        return Pressable(
                          onTap: () => _openArtist(source, artist),
                          child: Row(
                            children: [
                              InitialAvatar(name: artist.name, size: 56),
                              const SizedBox(width: 12),
                              Text(artist.name, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500)),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          if (_albums.isNotEmpty)
            Arrive(
              key: ObjectKey((_albums, 'albums')),
              delay: const Duration(milliseconds: 30),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SectionHeader(context.t('search.albums')),
                  Shelf(
                    height: 160,
                    children: [
                      for (final album in _albums)
                        ReleaseCard(
                          cover: album.cover,
                          title: album.title,
                          subtitle: '',
                          size: 112,
                          heroTag: coverTag('search', album.id),
                          onTap: () => _openAlbum(slug, album, coverTag('search', album.id)),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          if (_tracks.isNotEmpty)
            Arrive(
              key: ObjectKey((_tracks, 'songs')),
              delay: const Duration(milliseconds: 60),
              child: Column(
                children: [
                  SectionHeader(context.t('search.songs')),
                  for (final (index, track) in _tracks.indexed)
                    TrackTile(
                      mixed: _everywhere,
                      track: track,
                      playing: current?.id == track.id && current?.source == track.source,
                      onTap: () => _play(_tracks, index),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _libraryResults(BuildContext context) {
    final needle = _text.toLowerCase();
    final found = [
      for (final track in downloads.done)
        if ('${track.title} ${track.artists} ${track.album}'.toLowerCase().contains(needle)) track,
    ];
    if (found.isEmpty) return _nothing(context);
    final current = widget.player.track;
    return ListView(
      padding: const EdgeInsets.only(bottom: bottomChromeInset),
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      children: [
        for (final (index, track) in found.indexed)
          TrackTile(
            mixed: _everywhere,
            track: track,
            playing: current?.id == track.id && current?.source == track.source,
            onTap: () => _play(found, index),
          ),
      ],
    );
  }

  Widget _nothing(BuildContext context) {
    final slug = _slug;
    return Padding(
      padding: const EdgeInsets.only(top: 60),
      child: Align(
        alignment: Alignment.topCenter,
        child: EmptyState(
          glyph: CauceGlyph.search,
          title: context.t(_inLibrary ? 'search.nothingDownloaded' : 'search.nothingTitle'),
          message: context.t(_inLibrary ? 'search.nothingDownloaded.detail' : 'search.nothing', {'query': _text}),
          actions: [
            if (_inLibrary && slug != null)
              SoftButton(
                label: context.t('search.in', {'service': _serviceName(slug)}),
                onPressed: () => _scope(library: false, slug: slug),
              ),
          ],
        ),
      ),
    );
  }
}

/// A style to browse by: its picture, or its hue with a tilted note, its name at the bottom.
class _GenreCard extends StatelessWidget {
  const _GenreCard({required this.genre, required this.hue, required this.onTap});

  final core.GenreCard genre;
  final double hue;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final picture = artworkProvider(genre.cover);
    return Pressable(
      onTap: onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(CauceMetrics.artworkRadius),
        child: ColoredBox(
          color: oklch(0.5, 0.12, hue),
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (picture != null) ...[
                Image(image: picture, fit: BoxFit.cover, errorBuilder: (_, _, _) => const SizedBox.shrink()),
                const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.bottomCenter,
                      end: Alignment.topCenter,
                      colors: [Color(0xB3000000), Colors.transparent],
                    ),
                  ),
                ),
              ],
              Padding(
                padding: const EdgeInsets.all(12),
                child: Align(
                  alignment: Alignment.bottomLeft,
                  child: Text(
                    genre.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                      height: 1.15,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The search field pinned under the status bar; its frosted bar shows once the page scrolls beneath it.
class _FieldBar extends SliverPersistentHeaderDelegate {
  const _FieldBar(this.field);

  final Widget field;

  static const _extent = 8 + 42 + 6.0;

  @override
  double get minExtent => _extent;

  @override
  double get maxExtent => _extent;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) {
    return Stack(
      fit: StackFit.expand,
      children: [
        AnimatedOpacity(
          opacity: shrinkOffset > 0 ? 1 : 0,
          duration: const Duration(milliseconds: 160),
          child: ClipRect(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: CauceColors.background.withValues(alpha: 0.88),
                  border: Border(bottom: BorderSide(color: CauceColors.foreground.withValues(alpha: 0.08), width: 0.5)),
                ),
              ),
            ),
          ),
        ),
        Padding(padding: const EdgeInsets.only(top: 8, bottom: 6), child: field),
      ],
    );
  }

  @override
  bool shouldRebuild(_FieldBar oldDelegate) => true;
}
