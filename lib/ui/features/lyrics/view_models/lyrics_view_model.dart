import 'package:flutter/foundation.dart';

import '../../../../src/rust/api/player.dart' as core;
import '../../../core/app_prefs.dart';
import '../../player/view_models/player_view_model.dart';

/// The lyrics of whatever is playing, looked up once per track.
class LyricsViewModel extends ChangeNotifier {
  LyricsViewModel(this._player) {
    _player.addListener(_follow);
  }

  final PlayerViewModel _player;
  final Map<String, core.LyricsView?> _found = {};
  String? _track;
  bool _loading = false;

  bool get loading => _loading;

  /// The current track's lyrics; `null` while loading or when no service has any.
  core.LyricsView? get lyrics => _track == null ? null : _found[_track];

  void _follow() {
    final track = _player.track;
    final key = track == null ? null : '${track.source}:${track.id}';
    if (key == _track) return;
    _track = key;
    notifyListeners();
    if (track != null && key != null && !_found.containsKey(key)) _load(track, key);
  }

  Future<void> _load(core.TrackItem track, String key) async {
    _loading = true;
    notifyListeners();
    try {
      _found[key] = await core.lyrics(track: track, sources: appPrefs.lyricsSources);
    } catch (_) {
      _found[key] = null;
    }
    if (_track == key) _loading = false;
    notifyListeners();
  }

  @override
  void dispose() {
    _player.removeListener(_follow);
    super.dispose();
  }
}
