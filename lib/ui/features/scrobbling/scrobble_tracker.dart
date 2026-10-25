/// Decides when a play has earned its scrobble, from the player's state as it changes: the
/// service is told once when a track starts, and the listen is sent once the time actually spent
/// playing it reaches half the track or four minutes. Tracks under 30 seconds are never sent.
///
/// Time is counted on the wall clock while playing, so seeking ahead does not count as listening.
class ScrobbleTracker<T> {
  ScrobbleTracker({required this.nowPlaying, required this.scrobble});

  final void Function(T track) nowPlaying;
  final void Function(T track, DateTime started) scrobble;

  static const _shortest = Duration(seconds: 30);
  static const _enough = Duration(minutes: 4);

  T? _track;
  String? _id;
  Duration _length = Duration.zero;
  DateTime? _started;
  DateTime? _since;
  Duration _listened = Duration.zero;
  bool _sent = false;

  /// Takes the player's current track, or none, and whether it is playing at [now].
  void observe(T? track, {required String id, required Duration length, required bool playing, required DateTime now}) {
    _count(now);
    if (track == null) {
      _track = _id = null;
      return;
    }
    if (id != _id) {
      _track = track;
      _id = id;
      _length = length;
      _started = now;
      _listened = Duration.zero;
      _sent = false;
      nowPlaying(track);
    }
    _since = playing ? now : null;
    _check();
  }

  void _count(DateTime now) {
    if (_since case final since?) _listened += now.difference(since);
    _since = null;
    _check();
  }

  void _check() {
    final track = _track;
    if (track == null || _sent || _length < _shortest) return;
    final half = _length ~/ 2;
    if (_listened >= (half < _enough ? half : _enough)) {
      _sent = true;
      scrobble(track, _started!);
    }
  }
}
