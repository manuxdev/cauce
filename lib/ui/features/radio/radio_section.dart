import 'dart:async';

import 'package:flutter/material.dart';

import '../../../src/rust/api/player.dart' as core;
import '../../core/icons.dart';
import '../../core/l10n.dart';
import '../../core/motion.dart';
import '../../core/service_picker.dart';
import '../../core/skeleton.dart';
import '../../core/status_band.dart';
import '../../core/theme.dart';
import '../../core/track_tile.dart';
import '../../core/widgets.dart';
import '../library/view_models/favorites_view_model.dart';
import '../player/view_models/player_view_model.dart';
import '../player/views/player_parts.dart';
import '../track/track_options.dart';

/// The source a station plays through.
const radioSource = 'radio';

/// Whether `track` is a live station: no length, no seeking, nothing to download, scrobble or
/// add to a playlist.
bool isStation(core.TrackItem? track) => track?.source == radioSource;

/// How the station list is browsed.
enum RadioBrowse { top, country, genre, language }

/// The search a browse makes: by the name typed, within the facet picked, or the most played
/// stations when there is neither.
@visibleForTesting
core.RadioQuery? radioQuery({required String typed, required RadioBrowse browse, String? facet}) {
  final name = typed.trim();
  final filter = browse == RadioBrowse.top ? null : facet;
  if (name.isEmpty && filter == null) return null;
  return core.RadioQuery(
    name: name.isEmpty ? null : name,
    countryCode: browse == RadioBrowse.country ? filter : null,
    tag: browse == RadioBrowse.genre ? filter : null,
    language: browse == RadioBrowse.language ? filter : null,
    offset: 0,
    limit: 60,
  );
}

/// The flag of a two-letter country code, or nothing for anything else.
String flagOf(String? code) {
  final letters = code?.toUpperCase() ?? '';
  if (!RegExp(r'^[A-Z]{2}$').hasMatch(letters)) return '';
  return String.fromCharCodes(letters.codeUnits.map((unit) => 0x1F1E6 + unit - 0x41));
}

/// What the filter sheet picked: a way of browsing, and the facet's value and name.
typedef RadioFilter = ({RadioBrowse browse, String? value, String? name});

const _debounce = Duration(milliseconds: 350);

/// The library's radio: favourite stations first, then the most played, or those of a country,
/// genre or language, narrowed by the name searched.
class RadioSection extends StatefulWidget {
  const RadioSection({super.key, required this.player, required this.favorites});

  final PlayerViewModel player;
  final FavoritesViewModel favorites;

  @override
  State<RadioSection> createState() => _RadioSectionState();
}

class _RadioSectionState extends State<RadioSection> {
  final _query = TextEditingController();
  Timer? _pending;
  RadioFilter _filter = (browse: RadioBrowse.top, value: null, name: null);
  final Map<RadioBrowse, Future<List<core.RadioFacet>>> _facets = {};
  late Future<List<core.TrackItem>> _stations = _load();

  @override
  void initState() {
    super.initState();
    if (widget.favorites.tracks(radioSource).isEmpty) widget.favorites.load(radioSource);
  }

  @override
  void dispose() {
    _pending?.cancel();
    _query.dispose();
    super.dispose();
  }

  Future<List<core.TrackItem>> _load() {
    final query = radioQuery(typed: _query.text, browse: _filter.browse, facet: _filter.value);
    return query == null ? core.radioTop(limit: 60) : core.radioSearch(query: query);
  }

  void _reload() => setState(() => _stations = _load());

  /// Searches once the typing stops, as the music search does.
  void _typed(String text) {
    _pending?.cancel();
    _pending = Timer(text.trim().isEmpty ? Duration.zero : _debounce, () {
      if (mounted) _reload();
    });
  }

  void _pick(RadioFilter filter) {
    _filter = filter;
    _reload();
  }

  Future<List<core.RadioFacet>> _facetsOf(RadioBrowse browse) => _facets.putIfAbsent(
    browse,
    () => core.radioBrowse(
      kind: switch (browse) {
        RadioBrowse.country => core.RadioBrowse.countries,
        RadioBrowse.genre => core.RadioBrowse.tags,
        _ => core.RadioBrowse.languages,
      },
    ),
  );

  Future<void> _openFilters() async {
    FocusScope.of(context).unfocus();
    final picked = await behindSheet(
      showModalBottomSheet<RadioFilter>(
        context: context,
        useRootNavigator: true,
        isScrollControlled: true,
        sheetAnimationStyle: sheetAnimation,
        barrierColor: Colors.black.withValues(alpha: 0.5),
        builder: (_) => _RadioFilters(current: _filter, facetsOf: _facetsOf),
      ),
    );
    if (picked != null && mounted) _pick(picked);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([online, widget.favorites, widget.player]),
      builder: (context, _) {
        if (!online.value) {
          return Padding(
            padding: const EdgeInsets.only(bottom: bottomChromeInset / 2),
            child: EmptyState(
              glyph: CauceGlyph.offline,
              badge: true,
              title: context.t('home.offline'),
              message: context.t('radio.offline'),
            ),
          );
        }
        final favourites = widget.favorites.tracks(radioSource);
        final searching = _query.text.trim().isNotEmpty;
        final filtered = _filter.browse != RadioBrowse.top;
        return RefreshIndicator(
          color: CauceColors.foreground,
          onRefresh: () async {
            _facets.clear();
            _reload();
            await Future.wait([_stations, widget.favorites.load(radioSource)]);
          },
          child: ListView(
            padding: const EdgeInsets.only(bottom: bottomChromeInset),
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            children: [
              _field(context, filtered),
              if (favourites.isNotEmpty && !searching && !filtered) ...[
                SectionHeader(context.t('radio.favourites'), count: favourites.length),
                for (var index = 0; index < favourites.length; index++) _row(favourites, index),
              ],
              SectionHeader(
                filtered
                    ? '${flagOf(_filter.browse == RadioBrowse.country ? _filter.value : null)} ${_filter.name}'.trim()
                    : context.t(searching ? 'radio.stations' : 'radio.top'),
                action: filtered ? context.t('radio.clear') : null,
                onAction: filtered ? () => _pick((browse: RadioBrowse.top, value: null, name: null)) : null,
              ),
              FutureBuilder(
                future: _stations,
                builder: (context, snapshot) {
                  if (snapshot.connectionState != ConnectionState.done) return const TrackListSkeleton();
                  if (snapshot.hasError) {
                    return EmptyState(
                      glyph: CauceGlyph.alert,
                      badge: true,
                      danger: true,
                      title: context.t('common.error'),
                      actions: [FilledButton(onPressed: _reload, child: Text(context.t('common.retry')))],
                    );
                  }
                  final stations = snapshot.data ?? const <core.TrackItem>[];
                  if (stations.isEmpty) {
                    return Padding(
                      padding: const EdgeInsets.only(top: 40),
                      child: EmptyState(glyph: CauceGlyph.search, title: context.t('radio.none')),
                    );
                  }
                  return Column(
                    children: [for (var index = 0; index < stations.length; index++) _row(stations, index)],
                  );
                },
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _field(BuildContext context, bool filtered) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(CauceMetrics.gutter, 0, CauceMetrics.gutter, 4),
      child: Row(
        children: [
          Expanded(
            child: SizedBox(
              height: 42,
              child: TextField(
                controller: _query,
                textInputAction: TextInputAction.search,
                onChanged: _typed,
                onSubmitted: (_) {
                  _pending?.cancel();
                  _reload();
                },
                style: const TextStyle(fontSize: 17),
                decoration: InputDecoration(
                  hintText: context.t('radio.search'),
                  prefixIcon: Padding(
                    padding: const EdgeInsets.only(left: 12, right: 8),
                    child: CauceIcon(CauceGlyph.search, size: 19, color: CauceColors.mutedForeground, weight: 2.1),
                  ),
                  prefixIconConstraints: const BoxConstraints(minWidth: 0, minHeight: 0),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Material(
            color: filtered ? CauceColors.accent : CauceColors.secondary,
            borderRadius: BorderRadius.circular(12),
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: _openFilters,
              child: SizedBox.square(
                dimension: 42,
                child: Center(
                  child: CauceIcon(
                    CauceGlyph.settings,
                    size: 20,
                    weight: 2.1,
                    color: filtered ? CauceColors.onAccent : CauceColors.foreground,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _row(List<core.TrackItem> stations, int index) {
    final station = stations[index];
    final current = widget.player.track;
    return TrackTile(
      track: station,
      showAlbum: false,
      playing: current?.source == station.source && current?.id == station.id,
      onTap: () => widget.player.playQueue(stations, index),
      trailing: HeartButton(
        saved: widget.favorites.saved(station),
        onTap: () => widget.favorites.toggle(station),
        size: 36,
        fill: Colors.transparent,
      ),
    );
  }
}

/// The sheet that picks a country, genre or language, each searchable, most stations first.
class _RadioFilters extends StatefulWidget {
  const _RadioFilters({required this.current, required this.facetsOf});

  final RadioFilter current;
  final Future<List<core.RadioFacet>> Function(RadioBrowse) facetsOf;

  @override
  State<_RadioFilters> createState() => _RadioFiltersState();
}

class _RadioFiltersState extends State<_RadioFilters> {
  final _search = TextEditingController();
  late var _tab = widget.current.browse == RadioBrowse.top ? RadioBrowse.country : widget.current.browse;

  static const _tabs = [
    (RadioBrowse.country, 'radio.country', 'radio.searchCountries'),
    (RadioBrowse.genre, 'radio.genre', 'radio.searchGenres'),
    (RadioBrowse.language, 'radio.language', 'radio.searchLanguages'),
  ];

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  // A country is searched by its code; a genre or language by its name, as listed.
  String _value(core.RadioFacet facet) => _tab == RadioBrowse.country ? (facet.code ?? facet.name) : facet.name;

  String _label(core.RadioFacet facet) =>
      facet.name.isEmpty ? facet.name : facet.name[0].toUpperCase() + facet.name.substring(1);

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.viewInsetsOf(context).bottom + MediaQuery.paddingOf(context).bottom;
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.8,
      child: Column(
        children: [
          const SheetHandle(),
          Padding(
            padding: const EdgeInsets.fromLTRB(CauceMetrics.gutter, 0, 8, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    context.t('radio.filters'),
                    style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
                  ),
                ),
                if (widget.current.browse != RadioBrowse.top)
                  TextButton(
                    onPressed: () => Navigator.of(context).pop((browse: RadioBrowse.top, value: null, name: null)),
                    child: Text(context.t('radio.clear')),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: CauceMetrics.gutter),
            child: Container(
              height: 38,
              padding: const EdgeInsets.all(3),
              decoration: BoxDecoration(color: CauceColors.secondary, borderRadius: BorderRadius.circular(12)),
              child: Row(
                children: [
                  for (final (tab, label, _) in _tabs)
                    Expanded(
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => setState(() {
                          _tab = tab;
                          _search.clear();
                        }),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          curve: Curves.easeOut,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: _tab == tab ? CauceColors.raised : Colors.transparent,
                            borderRadius: BorderRadius.circular(9),
                          ),
                          child: Text(
                            context.t(label),
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: _tab == tab ? CauceColors.foreground : CauceColors.mutedForeground,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(CauceMetrics.gutter, 12, CauceMetrics.gutter, 6),
            child: SizedBox(
              height: 42,
              child: TextField(
                controller: _search,
                onChanged: (_) => setState(() {}),
                style: const TextStyle(fontSize: 17),
                decoration: InputDecoration(
                  hintText: context.t(_tabs.firstWhere((entry) => entry.$1 == _tab).$3),
                  prefixIcon: Padding(
                    padding: const EdgeInsets.only(left: 12, right: 8),
                    child: CauceIcon(CauceGlyph.search, size: 19, color: CauceColors.mutedForeground, weight: 2.1),
                  ),
                  prefixIconConstraints: const BoxConstraints(minWidth: 0, minHeight: 0),
                ),
              ),
            ),
          ),
          Expanded(
            child: FutureBuilder(
              future: widget.facetsOf(_tab),
              builder: (context, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return const Center(child: CircularProgressIndicator(strokeWidth: 2));
                }
                final typed = _search.text.trim().toLowerCase();
                final facets = [
                  for (final facet in snapshot.data ?? const <core.RadioFacet>[])
                    if (facet.name.toLowerCase().contains(typed)) facet,
                ];
                if (facets.isEmpty) {
                  return Padding(
                    padding: EdgeInsets.only(bottom: bottom),
                    child: EmptyState(glyph: CauceGlyph.search, title: context.t('radio.noMatch')),
                  );
                }
                return ListView.builder(
                  padding: EdgeInsets.only(top: 4, bottom: bottom + 12),
                  keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                  itemCount: facets.length,
                  itemBuilder: (context, index) => _facet(facets[index]),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _facet(core.RadioFacet facet) {
    final picked = widget.current.browse == _tab && widget.current.value == _value(facet);
    final flag = _tab == RadioBrowse.country ? flagOf(facet.code) : '';
    return InkWell(
      onTap: () => Navigator.of(context).pop((browse: _tab, value: _value(facet), name: _label(facet))),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: CauceMetrics.gutter, vertical: 13),
        child: Row(
          children: [
            if (flag.isNotEmpty) ...[Text(flag, style: const TextStyle(fontSize: 22)), const SizedBox(width: 14)],
            Expanded(
              child: Text(
                _label(facet),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 17, fontWeight: picked ? FontWeight.w600 : FontWeight.w400),
              ),
            ),
            Text(
              '${facet.stations}',
              style: TextStyle(
                fontSize: 13,
                color: CauceColors.mutedForeground,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
            SizedBox(
              width: 32,
              child: picked
                  ? Align(
                      alignment: Alignment.centerRight,
                      child: CauceIcon(CauceGlyph.check, size: 18, color: CauceColors.accent, weight: 2.4),
                    )
                  : null,
            ),
          ],
        ),
      ),
    );
  }
}
