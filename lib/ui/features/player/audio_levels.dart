import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';

import '../../../src/rust/api/player.dart' as core;
import '../../core/app_prefs.dart';
import 'player_design.dart';
import 'view_models/player_view_model.dart';

/// How loud the music is, read from the engine about 30 times a second, but only while something
/// on screen [hold]s it: the tape's VU meters, or the ripple when it follows the audio.
class AudioLevels extends ChangeNotifier implements ValueListenable<double> {
  double left = 0;
  double right = 0;
  int _holders = 0;
  Timer? _timer;

  /// Both channels together.
  @override
  double get value => math.max(left, right);

  /// Starts reading until the returned function is called.
  VoidCallback hold() {
    if (_holders++ == 0) _timer = Timer.periodic(const Duration(milliseconds: 33), (_) => _read());
    var released = false;
    return () {
      if (released) return;
      released = true;
      if (--_holders == 0) {
        _timer?.cancel();
        _timer = null;
        left = right = 0;
        notifyListeners();
      }
    };
  }

  void _read() {
    final List<double> levels;
    try {
      levels = core.levels();
    } on Object {
      return;
    }
    if (levels.length < 2) return;
    left = levels[0].toDouble();
    right = levels[1].toDouble();
    notifyListeners();
  }
}

final audioLevels = AudioLevels();

/// Reads [audioLevels] while it is on screen and the listener lets the music move it.
class LevelsHold extends StatefulWidget {
  const LevelsHold({super.key, required this.child});

  final Widget child;

  @override
  State<LevelsHold> createState() => _LevelsHoldState();
}

class _LevelsHoldState extends State<LevelsHold> {
  VoidCallback? _release;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _follow();
  }

  @override
  void didUpdateWidget(LevelsHold old) {
    super.didUpdateWidget(old);
    _follow();
  }

  void _follow() {
    final on = appPrefs.reactive && !MediaQuery.disableAnimationsOf(context);
    if (on && _release == null) _release = audioLevels.hold();
    if (!on) {
      _release?.call();
      _release = null;
    }
  }

  @override
  void dispose() {
    _release?.call();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Each song's wave, kept in a small file per song once it has been heard nearly all the way
/// through with the wave bar in use. Until then a song has none, and the bar draws a made-up one.
class Waveforms extends ChangeNotifier {
  /// Slots along a song, and how often it is listened to while it plays.
  static const buckets = 120;
  static const _every = Duration(milliseconds: 200);

  final _known = <String, List<double>>{};
  final _asked = <String>{};
  Directory? _folder;
  PlayerViewModel? _player;
  Timer? _timer;
  String? _recording;
  WaveformBuilder? _builder;

  /// The wave of the song [key] names, `source:id`, or null while it is not known.
  List<double>? of(String key) {
    if (_asked.add(key)) _load(key);
    return _known[key];
  }

  /// Listens to [player] for songs to build waves of.
  void attach(PlayerViewModel player) {
    _player = player;
    player.addListener(_follow);
    appPrefs.addListener(_follow);
  }

  bool get _wanted =>
      seekStyleFor(appPrefs.playerDesign, appPrefs.seekStyle) == SeekStyle.wave ||
      seekStyleFor(appPrefs.playerDesign, appPrefs.seekStyle, lyrics: true) == SeekStyle.wave;

  void _follow() {
    final player = _player!;
    final track = player.track;
    final key = track == null ? null : '${track.source}:${track.id}';
    if (key != _recording) {
      _recording = key;
      _builder = WaveformBuilder(buckets);
    }
    final listen = key != null && player.playing && _wanted && of(key) == null;
    if (listen && _timer == null) _timer = Timer.periodic(_every, (_) => _sample());
    if (!listen) {
      _timer?.cancel();
      _timer = null;
    }
  }

  void _sample() {
    final player = _player!;
    final total = player.duration.inMilliseconds;
    final key = _recording;
    final builder = _builder;
    if (key == null || builder == null || total == 0) return;
    final levels = core.levels();
    if (levels.length < 2) return;
    builder.add(player.position.inMilliseconds / total, math.max(levels[0], levels[1]).toDouble());
    if (builder.filled < 0.9) return;
    final wave = builder.bars;
    _known[key] = wave;
    _save(key, wave);
    notifyListeners();
    _follow();
  }

  Future<Directory> _dir() async =>
      _folder ??= await Directory('${(await getApplicationSupportDirectory()).path}/waveforms').create(recursive: true);

  /// A file name for [key] that any id fits in.
  static String _name(String key) => '${base64Url.encode(utf8.encode(key)).replaceAll('=', '')}.json';

  Future<void> _load(String key) async {
    try {
      final file = File('${(await _dir()).path}/${_name(key)}');
      if (!await file.exists()) return;
      final wave = [...(jsonDecode(await file.readAsString()) as List).whereType<num>().map((bar) => bar.toDouble())];
      if (wave.isEmpty) return;
      _known[key] = wave;
      notifyListeners();
    } on Object {
      // Unreadable: built again the next time it plays.
    }
  }

  Future<void> _save(String key, List<double> wave) async {
    try {
      final file = File('${(await _dir()).path}/${_name(key)}');
      await file.writeAsString(jsonEncode([for (final bar in wave) (bar * 100).round() / 100]));
    } on Object {
      // Not kept this time; it is in memory for now.
    }
  }
}

final waveforms = Waveforms();
