import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../core/status_band.dart';

import '../../../src/rust/api/player.dart' as core;

import 'view_models/player_view_model.dart';

/// How far the reported position may drift from where steady playback puts it before the lock
/// screen is told again. iOS extrapolates from the rate, so only jumps need sending.
const _drift = Duration(seconds: 2);

/// What plays the sound, by the name the phone gives it, such as "AirPods Pro"; for the screen
/// only, never logged.
final audioOutput = ValueNotifier<String?>(null);

/// The phone's volume, 0 to 1, once the platform has said.
final outputVolume = ValueNotifier<double?>(null);

/// Mirrors the player onto the lock screen and Control Center, and carries their buttons and the
/// audio session's interruptions back to the player.
class NowPlayingCenter {
  NowPlayingCenter(this._player) {
    _channel.setMethodCallHandler(_command);
    PlayerViewModel.claimAudio = () async => await _channel.invokeMethod<bool>('claim') ?? false;
    _player.addListener(_sync);
    _channel.invokeMethod('output');
    // iOS says by itself; Android only once the network changes.
    if (defaultTargetPlatform == TargetPlatform.android) _channel.invokeMethod('online');
  }

  /// Sets the phone's own volume, 0 to 1.
  static Future<void> setVolume(double volume) => _channel.invokeMethod('volume', volume);

  /// Opens Android's output switcher; iOS embeds its own picker instead.
  static Future<void> pickOutput() => _channel.invokeMethod('pickOutput');

  static const _channel = MethodChannel('cauce/now_playing');

  final PlayerViewModel _player;

  /// Tells the platform side the preferences it acts on by itself.
  static Future<void> options({required bool resumeOnConnect}) =>
      _channel.invokeMethod('options', {'resumeOnConnect': resumeOnConnect});
  String? _track;
  bool? _playing;
  Duration _sentPosition = Duration.zero;
  DateTime _sentAt = DateTime.now();

  void _sync() {
    final track = _player.track;
    if (track == null) {
      if (_track != null) _channel.invokeMethod('clear');
      _track = null;
      return;
    }
    final key = '${track.source}:${track.id}';
    final playing = _player.playing;
    final expected = _sentPosition + (_playing == true ? DateTime.now().difference(_sentAt) : Duration.zero);
    final drifted = (_player.position - expected).abs() > _drift;
    if (key == _track && playing == _playing && !drifted) return;
    _track = key;
    _playing = playing;
    _sentPosition = _player.position;
    _sentAt = DateTime.now();
    _channel.invokeMethod('update', {
      'title': track.title,
      'artist': track.artists,
      'album': track.album,
      'artwork': track.cover,
      'duration': _player.duration.inMilliseconds / 1000,
      'position': _player.position.inMilliseconds / 1000,
      'playing': playing,
    });
  }

  Future<void> _command(MethodCall call) async {
    if (call.method == 'log') return core.note(message: '${call.arguments}');
    if (call.method != 'command') return;
    final arguments = call.arguments as Map;
    switch (arguments['name']) {
      case 'play':
        if (!_player.playing) await _player.togglePlay();
      case 'pause':
        if (_player.playing) await _player.togglePlay();
      case 'toggle':
        await _player.togglePlay();
      case 'next':
        await _player.next();
      case 'reroute':
        await _player.reroute();
      case 'previous':
        await _player.previous();
      case 'online':
        online.value = arguments['value'] == true;
      case 'network':
        _player.cellular = arguments['value'] == true;
        await core.setCellular(cellular: _player.cellular);
      case 'output':
        audioOutput.value = arguments['value'] as String?;
      case 'volume':
        outputVolume.value = (arguments['value'] as num?)?.toDouble();
      case 'seek':
        final seconds = (arguments['value'] as num?)?.toDouble() ?? 0;
        await _player.seek(Duration(milliseconds: (seconds * 1000).round()));
    }
  }
}
