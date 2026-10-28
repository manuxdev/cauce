import 'package:cauce/src/rust/api/player.dart' as core;
import 'package:cauce/ui/features/podcasts/podcasts_section.dart';
import 'package:cauce/ui/features/track/track_options.dart';
import 'package:flutter_test/flutter_test.dart';

core.TrackItem track(String source) => core.TrackItem(
  source: source,
  id: 'id',
  title: 'Episode',
  artists: 'The Show',
  album: '',
  durationMs: BigInt.from(3600000),
  playable: true,
  artistLinks: const [],
);

const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

void main() {
  test('a typed feed address gets https when it has no scheme', () {
    expect(feedAddress('  feeds.example.com/rss '), 'https://feeds.example.com/rss');
    expect(feedAddress('http://example.com/feed.xml'), 'http://example.com/feed.xml');
    expect(feedAddress('HTTPS://Example.com/Feed'), 'HTTPS://Example.com/Feed');
  });

  test('what is not a web address is no feed', () {
    expect(feedAddress(''), isNull);
    expect(feedAddress('not a url'), isNull);
    expect(feedAddress('ftp://example.com/feed'), isNull);
    expect(feedAddress('localhost'), isNull);
    expect(feedAddress('https://'), isNull);
  });

  test('an episode in progress shows how far it got and what is left', () {
    final hour = BigInt.from(3600000);
    expect(episodeProgress(durationMs: hour, positionMs: BigInt.from(900000), played: false), 0.25);
    expect(episodeLeft(durationMs: hour, positionMs: BigInt.from(900000), played: false), const Duration(minutes: 45));
    // Not started, played, or of no known length: no progress to show.
    expect(episodeProgress(durationMs: hour, positionMs: BigInt.zero, played: false), isNull);
    expect(episodeProgress(durationMs: hour, positionMs: BigInt.from(900000), played: true), isNull);
    expect(episodeProgress(durationMs: BigInt.zero, positionMs: BigInt.from(900000), played: false), isNull);
    expect(episodeLeft(durationMs: hour, positionMs: BigInt.zero, played: false), isNull);
  });

  test('a release date leaves out the year when it is this one', () {
    final now = DateTime(2025, 10, 27);
    expect(episodeDate(DateTime(2025, 10, 21).millisecondsSinceEpoch ~/ 1000, now, months), '21 Oct');
    expect(episodeDate(DateTime(2024, 3, 2).millisecondsSinceEpoch ~/ 1000, now, months), '2 Mar 2024');
    expect(episodeDate(null, now, months), '');
  });

  test('an episode is kept apart from tracks: downloaded, never hearted or put in a playlist', () {
    expect(isEpisode(track('podcast')), isTrue);
    expect(isEpisode(track('subsonic')), isFalse);
    expect(isEpisode(null), isFalse);
    expect(keepsLikeATrack(track('podcast')), isFalse);
  });
}
