import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../src/rust/api/player.dart' as core;
import '../../core/app_prefs.dart';
import 'download_batch.dart';

/// The downloaded tracks and the ones on their way. The core runs the queue; this asks it again
/// every second while anything is unfinished.
class DownloadsViewModel extends ChangeNotifier {
  List<core.DownloadItem> _items = const [];
  Map<String, core.DownloadItem> _byKey = const {};
  Timer? _poll;
  final List<DownloadBatch> _batches = [];

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

  Future<void> refresh() async {
    final items = await core.downloads();
    _items = items;
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
        // Lyrics found are kept beside the download; none found is fine.
        if (nowDone.contains(key) && !wasDone.contains(key)) {
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
    final wanted = [
      for (final track in tracks)
        if (track.source != 'local' && track.playable) track,
    ];
    if (wanted.isEmpty) return null;
    final batch = name == null
        ? null
        : DownloadBatch(name: name, cover: cover, keys: {for (final track in wanted) _key(track.source, track.id)});
    if (batch != null) _batches.add(batch);
    await core.downloadTracks(tracks: wanted);
    await refresh();
    return batch;
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
}

final downloads = DownloadsViewModel();
