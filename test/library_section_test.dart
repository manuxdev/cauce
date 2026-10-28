import 'package:cauce/src/rust/api/player.dart' as core;
import 'package:cauce/ui/core/selected_service.dart';
import 'package:cauce/ui/features/library/views/library_screen.dart';
import 'package:flutter_test/flutter_test.dart';

core.TrackItem track(String source, String id) => core.TrackItem(
  source: source,
  id: id,
  title: id,
  artists: '',
  album: '',
  durationMs: BigInt.zero,
  playable: true,
  artistLinks: const [],
);

void main() {
  const providers = ['subsonic', 'jellyfin'];

  test('opening a library section keeps the provider picked on home', () {
    selectedService.select('jellyfin');

    expect(pickLibrarySection('playlists', providers), 'playlists');
    expect(pickLibrarySection('downloads', providers), 'downloads');
    expect(pickLibrarySection('files', providers), 'files');

    expect(selectedService.among(providers), 'jellyfin');
  });

  test('picking a provider in the library switches it everywhere', () {
    selectedService.select('subsonic');

    expect(pickLibrarySection('jellyfin', providers), isNull);

    expect(selectedService.among(providers), 'jellyfin');
  });

  test('downloads list every provider until one is picked', () {
    final tracks = [track('emby', 'a'), track('plex', 'b'), track('emby', 'c')];

    expect(downloadSources(tracks), ['emby', 'plex']);
    expect(downloadsFrom(tracks, null), tracks);
    expect([for (final track in downloadsFrom(tracks, 'emby')) track.id], ['a', 'c']);
    // A provider whose downloads are all gone shows every provider again.
    expect(downloadsFrom(tracks, 'jellyfin'), tracks);
  });
}
