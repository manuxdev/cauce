import 'package:flutter/foundation.dart';

enum BatchState { waiting, done, failed }

/// Downloads asked for together under one name, such as an album, to say once when they are
/// all in.
class DownloadBatch {
  DownloadBatch({required this.name, this.cover, required this.keys});

  final String name;
  final String? cover;
  final Set<String> keys;

  /// How much of it is in, from 0 to 1.
  final progress = ValueNotifier<double>(0);
  int done = 0;
  int failed = 0;

  /// Takes the state of every listed download by key, answering whether the batch is over. One
  /// no longer listed was removed: it holds nothing up, and is neither done nor failed.
  bool update(Map<String, BatchState> states) {
    var waiting = 0;
    done = 0;
    failed = 0;
    for (final key in keys) {
      switch (states[key]) {
        case null:
          break;
        case BatchState.waiting:
          waiting++;
        case BatchState.done:
          done++;
        case BatchState.failed:
          failed++;
      }
    }
    progress.value = (done + failed) / keys.length;
    return waiting == 0;
  }
}
