import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../src/rust/api/player.dart' as core;
import '../../core/app_prefs.dart';
import '../accounts/view_models/accounts_view_model.dart';
import 'download_batch.dart';

/// The downloaded tracks and the ones on their way. The core runs the queue; this asks it again
/// every second while anything is unfinished.
class DownloadsViewModel extends ChangeNotifier {
  List<core.DownloadItem> _items = const [];
  Map<String, core.DownloadItem> _byKey = const {};
  Timer? _poll;
  final List<DownloadBatch> _batches = [];

  /// The albums and playlists kept downloaded, by [_collection] key.
  Set<String> _kept = const {};

  /// Removed, but kept on disk until the toast offering to undo it goes.
  final Set<String> _hidden = {};

  /// The ones already done at the last look, to notice each that finishes. Null before the first.
  Set<String>? _wasDone;

  /// Told when every download of a batch is in.
  void Function(DownloadBatch batch)? onBatchDone;

  List<core.DownloadItem> get items => [
    for (final item in _items)
      if (!_hidden.contains(_key(item.track.source, item.track.id))) item,
  ];

  /// The downloaded ones, in the order they were asked for.
  List<core.TrackItem> get done => [
    for (final item in items)
      if (item.state == core.DownloadState.done) item.track,
  ];

  core.DownloadItem? of(core.TrackItem track) {
    final key = _key(track.source, track.id);
    return _hidden.contains(key) ? null : _byKey[key];
  }

  bool keeps(String slug, core.CardKind kind, String id) => _kept.contains(_collection(slug, kind, id));

  Future<void> refresh() async {
    final (items, kept) = await (core.downloads(), core.keptCollections()).wait;
    _items = items;
    _kept = {for (final collection in kept) _collection(collection.slug, collection.kind, collection.id)};
    _byKey = {for (final item in items) _key(item.track.source, item.track.id): item};
    notifyListeners();
    final states = {
      for (final item in items)
        _key(item.track.source, item.track.id): switch (item.state) {
          core.DownloadState.done => BatchState.done,
          core.DownloadState.failed => BatchState.failed,
          _ => BatchState.waiting,
        },
    };
    final nowDone = {
      for (final item in items)
        if (item.state == core.DownloadState.done) _key(item.track.source, item.track.id),
    };
    if (_wasDone case final wasDone? when appPrefs.saveLyrics) {
      for (final item in items) {
        final key = _key(item.track.source, item.track.id);
        // Lyrics found are kept beside the download; none found is fine. An episode has none.
        if (nowDone.contains(key) && !wasDone.contains(key) && item.track.source != 'podcast') {
          core.keepLyrics(track: item.track, sources: appPrefs.askedLyricsSources).ignore();
        }
      }
    }
    _wasDone = nowDone;
    for (final batch in [..._batches]) {
      if (!batch.update(states)) continue;
      _batches.remove(batch);
      onBatchDone?.call(batch);
    }
    final unfinished = items.any(
      (item) => item.state == core.DownloadState.queued || item.state == core.DownloadState.running,
    );
    if (unfinished) {
      _poll ??= Timer.periodic(const Duration(seconds: 1), (_) => refresh().ignore());
    } else {
      _poll?.cancel();
      _poll = null;
    }
  }

  /// Downloads `tracks`; with a `name`, they are told about together once all are in. Answers
  /// that batch, to follow its progress.
  Future<DownloadBatch?> download(List<core.TrackItem> tracks, {String? name, String? cover}) async {
    final wanted = _wanted(tracks);
    if (wanted.isEmpty) return null;
    final batch = name == null
        ? null
        : DownloadBatch(name: name, cover: cover, keys: {for (final track in wanted) _key(track.source, track.id)});
    if (batch != null) _batches.add(batch);
    await core.downloadTracks(tracks: wanted);
    await refresh();
    return batch;
  }

  /// Keeps an album or playlist downloaded with the `tracks` it has now: those not listed yet
  /// download, and so do the ones it gains each time it is kept again. The `name` and `cover`
  /// are what the downloads list shows for it.
  Future<void> keep(
    String slug,
    core.CardKind kind,
    String id,
    List<core.TrackItem> tracks, {
    String? name,
    String? cover,
  }) async {
    await core.keepCollection(slug: slug, kind: kind, id: id, tracks: _wanted(tracks), name: name, cover: cover);
    await refresh();
  }

  /// Stops keeping an album or playlist downloaded and removes its downloads, but for those
  /// another kept collection holds and, while likes download, the `liked` ones.
  Future<void> removeCollection(
    String slug,
    core.CardKind kind,
    String id, {
    required List<core.TrackItem> liked,
  }) async {
    await core.removeKeptCollection(slug: slug, kind: kind, id: id, liked: [for (final track in liked) track.id]);
    await refresh();
  }

  /// Downloads what the kept albums and playlists of the `signedIn` services are missing, and
  /// with `likes` their liked songs too. Only what is not listed yet is asked for, so the queue
  /// and Wi-Fi-only hold as for any download. One that cannot be reached now waits for the next.
  Future<void> catchUp(List<String> signedIn, {required bool likes}) async {
    if (likes) {
      for (final slug in signedIn) {
        try {
          await core.downloadMissing(tracks: _wanted(await core.savedTracks(slug: slug)));
        } on Object {
          // Offline or refused: the next catch-up tries again.
        }
      }
    }
    for (final kept in await core.keptCollections()) {
      if (!signedIn.contains(kept.slug)) continue;
      try {
        final tracks = await core.collectionTracks(slug: kept.slug, kind: kept.kind, id: kept.id);
        await core.keepCollection(slug: kept.slug, kind: kept.kind, id: kept.id, tracks: _wanted(tracks));
      } on Object {
        // Gone or unreachable: it stays kept, and the next catch-up tries again.
      }
    }
    await refresh();
  }

  /// Downloads at once the `added` tracks a kept playlist just gained here, then keeps it with
  /// its tracks now. The queue and Wi-Fi-only hold as for any download.
  Future<void> addedTo(String slug, String playlistId, List<core.TrackItem> added) async {
    final wanted = downloadsOnAdd(kept: keeps(slug, core.CardKind.playlist, playlistId), added: added);
    if (wanted.isEmpty) return;
    await core.downloadMissing(tracks: wanted);
    try {
      final tracks = await core.collectionTracks(slug: slug, kind: core.CardKind.playlist, id: playlistId);
      await core.keepCollection(slug: slug, kind: core.CardKind.playlist, id: playlistId, tracks: _wanted(tracks));
    } on Object {
      // Unreachable now: the next catch-up keeps it with them.
    }
    await refresh();
  }

  Future<void> remove(core.TrackItem track) async {
    await core.removeDownload(source: track.source, id: track.id);
    await refresh();
  }

  /// Hides `track` at once and answers what takes it back; the file goes when [forget] is called.
  void hide(core.TrackItem track) {
    _hidden.add(_key(track.source, track.id));
    notifyListeners();
  }

  void unhide(core.TrackItem track) {
    _hidden.remove(_key(track.source, track.id));
    notifyListeners();
  }

  /// Deletes a hidden download for good.
  Future<void> forget(core.TrackItem track) async {
    await remove(track);
    _hidden.remove(_key(track.source, track.id));
  }

  static String _key(String source, String id) => '$source\u0000$id';

  static String _collection(String slug, core.CardKind kind, String id) => '$slug\u0000${kind.name}\u0000$id';

  /// The ones a provider can download: not local files nor an open catalog's, and playable.
  static List<core.TrackItem> _wanted(List<core.TrackItem> tracks) => [
    for (final track in tracks)
      if (canDownload(track.source) && track.playable) track,
  ];
}

/// Whether a track of `source` can be downloaded: not a file already on the phone, and not an
/// open catalog's, which only streams.
bool canDownload(String source) => source != 'local' && !openCatalogs.contains(source);

final downloads = DownloadsViewModel();

/// What adding `added` to a playlist downloads at once: the ones a provider can download, when
/// the playlist is `kept` downloaded.
List<core.TrackItem> downloadsOnAdd({required bool kept, required List<core.TrackItem> added}) =>
    kept ? DownloadsViewModel._wanted(added) : const [];

/// Whether coming back to the app catches up the kept downloads, `last` caught up at, so changes
/// made elsewhere come in without a fetch on every return.
bool catchUpDue(DateTime? last, DateTime now) => last == null || now.difference(last) >= const Duration(minutes: 15);
