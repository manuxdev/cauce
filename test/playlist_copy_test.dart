import 'package:flutter_test/flutter_test.dart';
import 'package:cauce/src/rust/api/player.dart' as core;
import 'package:cauce/ui/features/home/views/playlist_editing.dart';

core.TrackItem track(String id) => core.TrackItem(
  source: 'subsonic',
  id: id,
  title: id,
  artists: '',
  album: '',
  durationMs: BigInt.zero,
  playable: true,
  artistLinks: const [],
);

void main() {
  test('a row is removed as its copy of the track, so a duplicate takes the right one', () {
    final tracks = [track('a'), track('b'), track('a'), track('c'), track('a')];
    expect([for (var i = 0; i < tracks.length; i++) copyOf(tracks, i)], [0, 0, 1, 0, 2]);
  });
}
