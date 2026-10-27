import 'dart:ui';

import 'package:flutter/material.dart';

import '../../../src/rust/api/player.dart' as core;
import '../../core/icons.dart';
import '../../core/l10n.dart';
import '../../core/service_picker.dart';
import '../../core/skeleton.dart';
import '../../core/status_band.dart';
import '../../core/theme.dart';
import '../../core/track_tile.dart';
import '../../core/widgets.dart';
import '../library/view_models/favorites_view_model.dart';
import '../player/view_models/player_view_model.dart';
import '../player/views/player_parts.dart';

/// The source a station plays through.
const radioSource = 'radio';

/// Whether `track` is a live station: no length, no seeking, nothing to download, scrobble or
/// add to a playlist.
bool isStation(core.TrackItem? track) => track?.source == radioSource;

/// How the station list is browsed.
enum RadioBrowse { top, country, genre, language }

/// The search a browse makes: by name when one is typed, otherwise by the facet picked, or the
/// most played stations when there is neither.
@visibleForTesting
core.RadioQuery? radioQuery({required String typed, required RadioBrowse browse, String? facet}) {
  final name = typed.trim();
  if (name.isEmpty && (browse == RadioBrowse.top || facet == null)) return null;
  return core.RadioQuery(
    name: name.isEmpty ? null : name,
    countryCode: name.isEmpty && browse == RadioBrowse.country ? facet : null,
    tag: name.isEmpty && browse == RadioBrowse.genre ? facet : null,
    language: name.isEmpty && browse == RadioBrowse.language ? facet : null,
    offset: 0,
    limit: 60,
  );
}

/// The library's radio: favourite stations first, then the most played, or those of a country,
/// genre or language, or those whose name matches the search.
class RadioSection extends StatefulWidget {
  const RadioSection({super.key, required this.player, required this.favorites});

  final PlayerViewModel player;
  final FavoritesViewModel favorites;

  @override
  State<RadioSection> createState() => _RadioSectionState();
}

class _RadioSectionState extends State<RadioSection> {
  final _query = TextEditingController();
  var _browse = RadioBrowse.top;

  /// The country code, tag or language picked, per way of browsing. A country starts at the
  /// phone's own.
  final Map<RadioBrowse, String?> _picked = {RadioBrowse.country: PlatformDispatcher.instance.locale.countryCode};
  final Map<RadioBrowse, Future<List<core.RadioFacet>>> _facets = {};
  late Future<List<core.TrackItem>> _stations = _load();

  @override
  void initState() {
    super.initState();
    if (widget.favorites.tracks(radioSource).isEmpty) widget.favorites.load(radioSource);
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<List<core.TrackItem>> _load() {
    final query = radioQuery(typed: _query.text, browse: _browse, facet: _picked[_browse]);
    return query == null ? core.radioTop(limit: 60) : core.radioSearch(query: query);
  }

  void _reload() => setState(() => _stations = _load());

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
        return RefreshIndicator(
          color: CauceColors.foreground,
          onRefresh: () async {
            _facets.clear();
            _reload();
            await Future.wait([_stations, widget.favorites.load(radioSource)]);
          },
          child: ListView(
            padding: const EdgeInsets.only(bottom: bottomChromeInset),
            children: [
              _field(context),
              const SizedBox(height: 10),
              SizedBox(
                height: 34,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: CauceMetrics.gutter),
                  children: [
                    for (final (browse, label) in [
                      (RadioBrowse.top, 'radio.top'),
                      (RadioBrowse.country, 'radio.country'),
                      (RadioBrowse.genre, 'radio.genre'),
                      (RadioBrowse.language, 'radio.language'),
                    ])
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: Pill(
                          label: context.t(label),
                          selected: _browse == browse && !searching,
                          onTap: () {
                            _query.clear();
                            _browse = browse;
                            _reload();
                          },
                        ),
                      ),
                  ],
                ),
              ),
              if (_browse != RadioBrowse.top && !searching) _facetRow(),
              if (favourites.isNotEmpty && !searching) ...[
                SectionHeader(context.t('radio.favourites'), count: favourites.length),
                for (var index = 0; index < favourites.length; index++) _row(favourites, index),
              ],
              SectionHeader(context.t(searching || _browse != RadioBrowse.top ? 'radio.stations' : 'radio.top')),
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

  Widget _field(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: CauceMetrics.gutter),
      child: SizedBox(
        height: 42,
        child: TextField(
          controller: _query,
          textInputAction: TextInputAction.search,
          onSubmitted: (_) => _reload(),
          onChanged: (text) {
            if (text.isEmpty) _reload();
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
    );
  }

  /// The countries, genres or languages to pick from, most stations first.
  Widget _facetRow() {
    final browse = _browse;
    return FutureBuilder(
      future: _facetsOf(browse),
      builder: (context, snapshot) {
        final facets = snapshot.data ?? const <core.RadioFacet>[];
        // A country is searched by its code; a genre or language by its name, as listed.
        String value(core.RadioFacet facet) => browse == RadioBrowse.country ? (facet.code ?? facet.name) : facet.name;
        return Padding(
          padding: const EdgeInsets.only(top: 10),
          child: SizedBox(
            height: 34,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: CauceMetrics.gutter),
              children: [
                for (final facet in facets)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Pill(
                      label: facet.name,
                      selected: _picked[browse] == value(facet),
                      onTap: () {
                        _picked[browse] = value(facet);
                        _reload();
                      },
                    ),
                  ),
              ],
            ),
          ),
        );
      },
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
