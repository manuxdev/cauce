import 'package:flutter_test/flutter_test.dart';
import 'package:cauce/src/rust/api/player.dart' as core;
import 'package:cauce/ui/features/downloads/downloads_view_model.dart';

core.TrackItem track(String id, {String source = 'subsonic', bool playable = true}) => core.TrackItem(
  source: source,
  id: id,
  title: id,
  artists: '',
  album: '',
  durationMs: BigInt.zero,
  playable: playable,
  artistLinks: const [],
);

void main() {
  test('tracks added to a kept playlist download at once, those it cannot download left out', () {
    final added = [track('a'), track('b', playable: false), track('c', source: 'local')];
    expect(downloadsOnAdd(kept: true, added: added).map((track) => track.id), ['a']);
  });

  test('tracks added to a playlist not kept download nothing', () {
    expect(downloadsOnAdd(kept: false, added: [track('a')]), isEmpty);
  });

  test('coming back to the app catches up at most every 15 minutes', () {
    final last = DateTime(2026, 1, 1, 12);
    expect(catchUpDue(null, last), isTrue);
    expect(catchUpDue(last, last.add(const Duration(minutes: 14, seconds: 59))), isFalse);
    expect(catchUpDue(last, last.add(const Duration(minutes: 15))), isTrue);
  });
}
