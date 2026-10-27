import 'package:flutter_test/flutter_test.dart';
import 'package:cauce/src/rust/api/player.dart' as core;
import 'package:cauce/ui/features/player/upcoming_covers.dart';

core.TrackItem track(String id, {String? cover}) => core.TrackItem(
  source: 'subsonic',
  id: id,
  title: id,
  artists: '',
  album: '',
  cover: cover ?? 'https://covers/$id',
  durationMs: BigInt.zero,
  playable: true,
  artistLinks: const [],
);

List<String> covers(
  List<core.TrackItem> queue,
  int? index, {
  bool online = true,
  bool cellular = false,
  bool dataSaver = false,
  core.RepeatMode repeat = core.RepeatMode.off,
}) => upcomingCovers(queue, index, repeat: repeat, online: online, cellular: cellular, dataSaver: dataSaver);

void main() {
  final queue = [
    for (final id in ['a', 'b', 'c', 'd']) track(id),
  ];

  test('the covers of the next two on Wi-Fi and the next one on mobile data', () {
    expect(covers(queue, 0), ['https://covers/b', 'https://covers/c']);
    expect(covers(queue, 0, cellular: true), ['https://covers/b']);
  });

  test('none offline, saving data on mobile data, or with nothing playing', () {
    expect(covers(queue, 0, online: false), isEmpty);
    expect(covers(queue, 0, cellular: true, dataSaver: true), isEmpty);
    expect(covers(queue, null), isEmpty);
  });

  test('saving data only holds on mobile data', () {
    expect(covers(queue, 0, dataSaver: true), ['https://covers/b', 'https://covers/c']);
  });

  test('the end of the queue stops them, unless it repeats from the start', () {
    expect(covers(queue, 3), isEmpty);
    expect(covers(queue, 2), ['https://covers/d']);
    expect(covers(queue, 3, repeat: core.RepeatMode.all), ['https://covers/a', 'https://covers/b']);
    expect(covers([track('a')], 0, repeat: core.RepeatMode.all), isEmpty);
  });

  test('a local file or a track without a cover needs nothing fetched', () {
    final mixed = [
      track('a'),
      track('b', cover: '/files/b.jpg'),
      core.TrackItem(
        source: 'subsonic',
        id: 'c',
        title: 'c',
        artists: '',
        album: '',
        durationMs: BigInt.zero,
        playable: true,
        artistLinks: const [],
      ),
    ];
    expect(covers(mixed, 0), isEmpty);
  });
}
