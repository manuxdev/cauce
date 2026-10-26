import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/app_prefs.dart';
import '../../../src/rust/api/player.dart' as core;

enum RecentKind { query, track, artist, album }

/// Something found through search: a query typed, or a track, artist or album opened from the
/// results.
class Recent {
  const Recent({
    required this.kind,
    required this.title,
    this.source = '',
    this.id = '',
    this.subtitle = '',
    this.cover,
    this.track,
  });

  final RecentKind kind;
  final String source;
  final String id;
  final String title;
  final String subtitle;
  final String? cover;

  /// The track itself, for a track, so it plays again as it was.
  final core.TrackItem? track;

  bool same(Recent other) => switch (kind) {
    RecentKind.query => other.kind == kind && other.title.toLowerCase() == title.toLowerCase(),
    _ => other.kind == kind && other.source == source && other.id == id,
  };

  Map<String, Object?> toJson() => {
    'kind': kind.name,
    'source': source,
    'id': id,
    'title': title,
    'subtitle': subtitle,
    'cover': cover,
    if (track case final track?) 'track': _trackToJson(track),
  };

  static Recent fromJson(Object? json) {
    // The first version kept the queries alone.
    if (json is String) return Recent(kind: RecentKind.query, title: json);
    final map = json! as Map<String, Object?>;
    return Recent(
      kind: RecentKind.values.byName(map['kind']! as String),
      source: map['source'] as String? ?? '',
      id: map['id'] as String? ?? '',
      title: map['title'] as String? ?? '',
      subtitle: map['subtitle'] as String? ?? '',
      cover: map['cover'] as String?,
      track: switch (map['track']) {
        final Map<String, Object?> track => _trackFromJson(track),
        _ => null,
      },
    );
  }
}

/// What search found lately, newest first, kept across launches.
class RecentSearches extends ChangeNotifier {
  static const _kept = 20;

  List<Recent> _items = [];
  File? _file;

  List<Recent> get items => _items;

  Future<void> load() async {
    final file = File('${(await getApplicationSupportDirectory()).path}/recent_searches.json');
    _file = file;
    if (!await file.exists()) return;
    try {
      _items = [for (final item in jsonDecode(await file.readAsString()) as List) Recent.fromJson(item)];
      notifyListeners();
    } on Object {
      // A torn write or an older shape leaves nothing worth keeping.
    }
  }

  /// Puts `query` first, once, ignoring case.
  void addQuery(String query) {
    final trimmed = query.trim();
    if (trimmed.isNotEmpty) _add(Recent(kind: RecentKind.query, title: trimmed));
  }

  void addTrack(core.TrackItem track) => _add(
    Recent(
      kind: RecentKind.track,
      source: track.source,
      id: track.id,
      title: track.title,
      subtitle: track.artists,
      cover: track.cover,
      track: track,
    ),
  );

  void addArtist(String source, core.ArtistLink artist) =>
      _add(Recent(kind: RecentKind.artist, source: source, id: artist.id, title: artist.name));

  void addAlbum(String source, core.MediaCard album) => _add(
    Recent(
      kind: RecentKind.album,
      source: source,
      id: album.id,
      title: album.title,
      subtitle: album.subtitle,
      cover: album.cover,
    ),
  );

  void remove(Recent item) {
    _items = [..._items.where((kept) => !kept.same(item))];
    _save();
  }

  void clear() {
    _items = [];
    _save();
  }

  void _add(Recent item) {
    if (!appPrefs.saveSearches) return;
    _items = [item, ..._items.where((kept) => !kept.same(item))].take(_kept).toList();
    _save();
  }

  void _save() {
    notifyListeners();
    _file?.writeAsString(jsonEncode([for (final item in _items) item.toJson()])).ignore();
  }
}

Map<String, Object?> _trackToJson(core.TrackItem track) => {
  'source': track.source,
  'id': track.id,
  'title': track.title,
  'artists': track.artists,
  'album': track.album,
  'cover': track.cover,
  'durationMs': track.durationMs.toInt(),
  'playable': track.playable,
  'albumId': track.albumId,
  'artistLinks': [
    for (final artist in track.artistLinks) {'id': artist.id, 'name': artist.name},
  ],
};

core.TrackItem _trackFromJson(Map<String, Object?> json) => core.TrackItem(
  source: json['source']! as String,
  id: json['id']! as String,
  title: json['title'] as String? ?? '',
  artists: json['artists'] as String? ?? '',
  album: json['album'] as String? ?? '',
  cover: json['cover'] as String?,
  durationMs: BigInt.from(json['durationMs'] as int? ?? 0),
  playable: json['playable'] as bool? ?? true,
  albumId: json['albumId'] as String?,
  artistLinks: [
    for (final artist in json['artistLinks'] as List? ?? const [])
      core.ArtistLink(id: (artist as Map)['id'] as String, name: artist['name'] as String),
  ],
);

final recentSearches = RecentSearches();
