import 'package:cauce/src/rust/api/player.dart';
import 'package:cauce/ui/features/accounts/view_models/plex_sign_in.dart';
import 'package:cauce/ui/features/accounts/view_models/quick_connect.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<QuickConnectEnd> wait(List<PlexPinCheck> answers, {bool Function()? cancelled}) {
    var checks = 0;
    return waitForPlexPin(
      check: () async => answers[checks++],
      cancelled: cancelled ?? () => false,
      wait: (_) async {},
    );
  }

  test('waits until the listener approves the sign-in', () async {
    expect(await wait([PlexPinCheck.waiting, PlexPinCheck.approved]), QuickConnectEnd.authorized);
  });

  test('a sign-in plex.tv forgot has expired', () async {
    expect(await wait([PlexPinCheck.waiting, PlexPinCheck.expired]), QuickConnectEnd.expired);
  });

  test('closing the page stops the checks', () async {
    expect(await wait([], cancelled: () => true), QuickConnectEnd.cancelled);
  });

  test('a single server is picked without asking, several are listed', () {
    const den = PlexServer(id: 'd', name: 'Den', owned: true);
    const friend = PlexServer(id: 'f', name: 'Friend', owned: false);
    expect(serverToPick([den]), den);
    expect(serverToPick([den, friend]), isNull);
    expect(serverToPick([]), isNull);
  });
}
