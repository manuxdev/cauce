import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../../src/rust/api/player.dart' as core;
import '../sleep_timer.dart';
import '../../../core/error_text.dart';
import '../../../core/l10n.dart';

/// The player as every screen sees it: the latest state the Rust core sent, and the commands
/// that change it.
class PlayerViewModel extends ChangeNotifier {
  PlayerViewModel(Stream<core.PlayerSnapshot> states) {
    _subscription = states.listen((state) {
      // The core stopped after several tracks in a row would not play: say so once.
      if (state.stalled && !(_state?.stalled ?? false)) _error = translate('error.unplayable');
      _state = state;
      notifyListeners();
    });
  }

  late final StreamSubscription<core.PlayerSnapshot> _subscription;
  core.PlayerSnapshot? _state;
  String? _error;

  core.PlayerSnapshot? get state => _state;
  core.TrackItem? get track => _state?.track;
  bool get playing => _state?.status == core.PlaybackStatus.playing;
  bool get loading => _state?.status == core.PlaybackStatus.loading;
  Duration get position => Duration(milliseconds: _state?.positionMs.toInt() ?? 0);
  Duration get duration => Duration(milliseconds: _state?.durationMs.toInt() ?? 0);
  core.RepeatMode get repeat => _state?.repeat ?? core.RepeatMode.off;

  /// How the stream is encoded, such as "AAC · 256 kbps", once the engine has said.
  String? get quality => _state?.quality;
  List<core.TrackItem> get queue => _state?.queue ?? const [];

  /// Playback rests once the current track ends, as the sleep timer's last option does.
  bool get stopsAfterCurrent => _state?.stopsAfterCurrent ?? false;

  Future<void> stopAfterCurrent(bool stop) => _run(() => core.setStopAfterCurrent(stop: stop));

  /// Pauses after a chosen time.
  late final sleep = SleepTimer(pause: () => playing ? _run(core.pause) : Future.value());
  int? get index => _state?.index;

  /// On mobile data, as the platform last said, which picks the stream quality in use.
  bool cellular = false;

  /// The last command that failed, for a snackbar. Cleared by [takeError].
  String? get error => _error;

  String? takeError() {
    final error = _error;
    _error = null;
    return error;
  }

  /// Takes the audio from other apps before anything plays, answering whether another app had
  /// it, which leaves the output to open again. Set by the platform side; nothing to do in tests.
  static Future<bool> Function() claimAudio = () async => false;

  /// The same song from another provider, for one its own cannot play. Set where the accounts
  /// are known; finds nothing in tests.
  static Future<core.TrackItem?> Function(core.TrackItem track) substitute = (_) async => null;

  Future<void> playQueue(List<core.TrackItem> tracks, int start) async {
    final wanted = tracks[start];
    final found = wanted.playable ? null : await substitute(wanted);
    if (found != null) tracks = [...tracks]..[start] = found;
    return _play(() => core.playQueue(tracks: tracks, start: start));
  }

  Future<void> playFiles(List<String> paths, int start) => _play(() => core.playFiles(paths: paths, start: start));

  Future<void> togglePlay() => playing ? _run(core.pause) : _play(core.play);
  Future<void> next() => _play(core.next);
  Future<void> previous() => _play(core.previous);
  Future<void> jump(int index) => _play(() => core.jump(index: index));
  Future<void> moveQueued(int from, int to) => _run(() => core.moveQueued(from: from, to: to));
  Future<void> shuffleUpcoming() => _run(core.shuffleUpcoming);
  Future<void> removeQueued(int index) => _run(() => core.removeQueued(index: index));
  Future<void> clearUpcoming() => _run(core.clearUpcoming);
  Future<void> seek(Duration to) => _run(() => core.seek(millis: BigInt.from(to.inMilliseconds)));

  /// Off → all → one → off.
  Future<void> cycleRepeat() => _run(
    () => core.setRepeat(
      repeat: switch (repeat) {
        core.RepeatMode.off => core.RepeatMode.all,
        core.RepeatMode.all => core.RepeatMode.one,
        core.RepeatMode.one => core.RepeatMode.off,
      },
    ),
  );

  /// Opens a new output on the route just picked and plays on from where the track was.
  Future<void> reroute() => _run(() async {
    await core.reopenOutput();
    await core.play();
  });

  Future<void> _play(Future<void> Function() command) => _run(() async {
    if (await claimAudio()) await core.reopenOutput();
    await command();
  });

  Future<void> _run(Future<void> Function() command) async {
    try {
      await command();
    } catch (error) {
      _error = explainError(error);
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _subscription.cancel();
    super.dispose();
  }
}
