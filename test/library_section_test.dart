import 'package:cauce/ui/core/selected_service.dart';
import 'package:cauce/ui/features/library/views/library_screen.dart';
import 'package:flutter_test/flutter_test.dart';

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
}
