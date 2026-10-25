import 'package:flutter/foundation.dart';

import '../../../../src/rust/api/player.dart' as core;
import '../../../core/error_text.dart';

/// Each service's starred tracks, and the hearts drawn from them.
class FavoritesViewModel extends ChangeNotifier {
  final Map<String, List<core.TrackItem>> _tracks = {};
  final Set<String> _loading = {};
  final Map<String, String> _errors = {};

  List<core.TrackItem> tracks(String slug) => _tracks[slug] ?? const [];
  bool loading(String slug) => _loading.contains(slug);
  String? error(String slug) => _errors[slug];

  bool saved(core.TrackItem track) => tracks(track.source).any((saved) => saved.id == track.id);

  Future<void> load(String slug) async {
    if (_loading.contains(slug)) return;
    _loading.add(slug);
    notifyListeners();
    try {
      _tracks[slug] = await core.savedTracks(slug: slug);
      _errors.remove(slug);
    } catch (error) {
      _errors[slug] = explainError(error);
    }
    _loading.remove(slug);
    notifyListeners();
  }

  /// Stars or unstars `track`, showing the change at once and taking it back if the service
  /// refuses.
  /// Runs for every track the user likes, as auto-downloading likes does.
  void Function(core.TrackItem track)? onLiked;

  Future<void> toggle(core.TrackItem track) async {
    final wasSaved = saved(track);
    final list = [...tracks(track.source)];
    wasSaved ? list.removeWhere((saved) => saved.id == track.id) : list.insert(0, track);
    final before = _tracks[track.source];
    _tracks[track.source] = list;
    notifyListeners();
    try {
      await core.setSaved(slug: track.source, trackId: track.id, saved: !wasSaved);
      if (!wasSaved) onLiked?.call(track);
    } catch (error) {
      _tracks[track.source] = before ?? const [];
      _errors[track.source] = explainError(error);
      notifyListeners();
    }
  }
}
