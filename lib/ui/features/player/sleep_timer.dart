import 'dart:async';

import 'package:flutter/foundation.dart';

/// Pauses the music once a chosen time has run out. Counts down a second at a time, so what is
/// left can be shown.
class SleepTimer extends ChangeNotifier {
  SleepTimer({required this.pause});

  final Future<void> Function() pause;

  Timer? _tick;
  Duration _left = Duration.zero;

  bool get active => _tick != null;
  Duration get left => _left;

  void start(Duration after) {
    _tick?.cancel();
    _left = after;
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      _left -= const Duration(seconds: 1);
      if (_left <= Duration.zero) {
        cancel();
        pause();
        return;
      }
      notifyListeners();
    });
    notifyListeners();
  }

  void cancel() {
    _tick?.cancel();
    _tick = null;
    _left = Duration.zero;
    notifyListeners();
  }
}
