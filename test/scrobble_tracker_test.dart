import 'package:cauce/ui/features/scrobbling/scrobble_tracker.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final start = DateTime(2026, 10, 24, 12);
  DateTime at(int seconds) => start.add(Duration(seconds: seconds));

  late List<String> nowPlaying;
  late List<(String, DateTime)> scrobbled;
  late ScrobbleTracker<String> tracker;

  setUp(() {
    nowPlaying = [];
    scrobbled = [];
    tracker = ScrobbleTracker<String>(
      nowPlaying: nowPlaying.add,
      scrobble: (track, started) => scrobbled.add((track, started)),
    );
  });

  void play(String? track, int seconds, {bool playing = true, int length = 200}) => tracker.observe(
    track,
    id: track ?? '',
    length: Duration(seconds: length),
    playing: playing,
    now: at(seconds),
  );

  test('a play is announced once and scrobbled once it reaches half its length', () {
    play('a', 0);
    play('a', 60);
    expect(nowPlaying, ['a']);
    expect(scrobbled, isEmpty);
    play('a', 100);
    play('a', 150);
    expect(scrobbled, [('a', at(0))]);
  });

  test('paused time does not count', () {
    play('a', 0);
    play('a', 50, playing: false);
    play('a', 500, playing: false);
    play('a', 500);
    play('a', 549);
    expect(scrobbled, isEmpty);
    play('a', 551);
    expect(scrobbled, hasLength(1));
  });

  test('four minutes earn a long track and short tracks never scrobble', () {
    play('long', 0, length: 3600);
    play('long', 240, length: 3600);
    expect(scrobbled.map((play) => play.$1), ['long']);
    play('short', 240, length: 20);
    play('short', 260, length: 20);
    expect(scrobbled, hasLength(1));
  });

  test('changing track flushes the old one and starts the next', () {
    play('a', 0);
    play('b', 120);
    expect(scrobbled.map((play) => play.$1), ['a']);
    expect(nowPlaying, ['a', 'b']);
    play(null, 130);
    play('b', 140);
    expect(nowPlaying, ['a', 'b', 'b']);
  });
}
