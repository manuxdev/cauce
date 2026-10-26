import 'package:cauce/ui/features/accounts/view_models/accounts_view_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('liking waits on a sign-in to the service, never for a file on the phone', () {
    expect(needsSignIn('subsonic', const {}), isTrue);
    expect(needsSignIn('subsonic', const {'subsonic'}), isFalse);
    expect(needsSignIn('local', const {}), isFalse);
  });

  test('a track from a service the app no longer has asks for no sign-in', () {
    expect(needsSignIn('retired', const {}), isFalse);
  });
}
