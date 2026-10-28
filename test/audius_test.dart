import 'package:cauce/ui/core/widgets.dart';
import 'package:cauce/ui/features/accounts/view_models/accounts_view_model.dart';
import 'package:cauce/ui/features/downloads/downloads_view_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Audius tracks only stream, so they never download', () {
    expect(canDownload('audius'), isFalse);
    expect(canDownload('local'), isFalse);
    expect(canDownload('subsonic'), isTrue);
  });

  test('Audius is connected like a service, with its own brand', () {
    expect(streamingServices.map((service) => service.slug), contains('audius'));
    expect(needsSignIn('audius', {}), isTrue);
    expect(needsSignIn('audius', {'audius'}), isFalse);
    expect(brandOf('audius').letters, 'AU');
  });

  test('liking an Audius track never asks to sign in once Audius is connected', () {
    final accounts = AccountsViewModel()..signedInAs('audius', 'Audius');
    expect(accounts.needsSignInFor('audius'), isFalse);
    // Its tracks stream with no account, so playing never waits on one.
    expect(needsSignIn('audius', {}, toPlay: true), isFalse);
  });
}
