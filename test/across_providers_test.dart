import 'package:flutter_test/flutter_test.dart';
import 'package:cauce/src/rust/api/player.dart' as core;
import 'package:cauce/ui/core/across_providers.dart';

core.TrackItem track(String source, String title, String artists, {bool playable = true}) => core.TrackItem(
  source: source,
  id: '$source-$title',
  title: title,
  artists: artists,
  album: '',
  durationMs: BigInt.zero,
  playable: playable,
  artistLinks: const [],
);

void main() {
  test('interleave takes one from each list in turn, in the order given', () {
    expect(
      interleave([
        [1, 2, 3],
        [10],
        [20, 21],
      ]),
      [1, 10, 20, 2, 21, 3],
    );
    expect(interleave(<List<int>>[]), isEmpty);
  });

  test('ordered puts the slugs in the order kept, the unknown ones last as they came', () {
    expect(ordered(['subsonic', 'other', 'local'], ['other', 'missing', 'subsonic']), ['other', 'subsonic', 'local']);
    expect(ordered(['subsonic', 'other'], const []), ['subsonic', 'other']);
  });

  test('sameSong finds the playable one with the same title and first artist, ignoring case and extras', () {
    final wanted = track('subsonic', 'Marea Alta', 'Lucía Ferrer', playable: false);
    final found = [
      track('other', 'Marea Baja', 'Lucía Ferrer'),
      track('other', 'marea alta (Remastered)', 'Lucía Ferrer, Otro', playable: false),
      track('other', 'Marea Alta - Remastered 2020', 'lucía ferrer & Otro'),
    ];
    expect(sameSong(wanted, found)?.title, 'Marea Alta - Remastered 2020');
    expect(sameSong(wanted, [track('other', 'Marea Alta', 'Someone Else')]), isNull);
  });
}
