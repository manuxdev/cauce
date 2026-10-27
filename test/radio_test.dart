import 'package:cauce/src/rust/api/player.dart' as core;
import 'package:cauce/ui/features/radio/radio_section.dart';
import 'package:cauce/ui/features/track/track_options.dart';
import 'package:flutter_test/flutter_test.dart';

core.TrackItem track(String source) => core.TrackItem(
  source: source,
  id: 'id',
  title: 'Title',
  artists: 'Spain · pop',
  album: '',
  durationMs: BigInt.zero,
  playable: true,
  artistLinks: const [],
);

void main() {
  test('the most played stations need no search', () {
    expect(radioQuery(typed: '  ', browse: RadioBrowse.top), isNull);
    // A country, genre or language with nothing picked yet shows the most played too.
    expect(radioQuery(typed: '', browse: RadioBrowse.genre), isNull);
  });

  test('a typed name searches by name alone', () {
    final query = radioQuery(typed: ' jazz ', browse: RadioBrowse.country, facet: 'US')!;
    expect(query.name, 'jazz');
    expect(query.countryCode, isNull);
  });

  test('a picked facet searches by its own filter', () {
    expect(radioQuery(typed: '', browse: RadioBrowse.country, facet: 'ES')!.countryCode, 'ES');
    expect(radioQuery(typed: '', browse: RadioBrowse.genre, facet: 'rock')!.tag, 'rock');
    final language = radioQuery(typed: '', browse: RadioBrowse.language, facet: 'spanish')!;
    expect(language.language, 'spanish');
    expect(language.countryCode, isNull);
  });

  test('a station is live and cannot be downloaded or added to a playlist', () {
    expect(isStation(track('radio')), isTrue);
    expect(isStation(track('subsonic')), isFalse);
    expect(isStation(null), isFalse);
    expect(keepsLikeATrack(track('radio')), isFalse);
    expect(keepsLikeATrack(track('local')), isFalse);
    expect(keepsLikeATrack(track('subsonic')), isTrue);
  });
}
