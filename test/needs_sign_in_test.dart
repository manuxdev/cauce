import 'package:cauce/ui/features/accounts/view_models/accounts_view_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('an Apple Music track waits on its sign-in to play, the rest play from what is kept', () {
    expect(needsSignIn('apple', const {}, toPlay: true), isTrue);
    expect(needsSignIn('apple', const {'apple'}, toPlay: true), isFalse);
    expect(needsSignIn('deezer', const {}, toPlay: true), isFalse);
    expect(needsSignIn('local', const {}, toPlay: true), isFalse);
  });

  test('liking waits on a sign-in to any service, never for a file on the phone', () {
    expect(needsSignIn('deezer', const {}), isTrue);
    expect(needsSignIn('spotify', const {'deezer'}), isTrue);
    expect(needsSignIn('deezer', const {'deezer'}), isFalse);
    expect(needsSignIn('local', const {}), isFalse);
  });

  test('a station or an episode needs no account to be kept', () {
    expect(needsSignIn('radio', const {}), isFalse);
    expect(needsSignIn('podcast', const {}), isFalse);
  });

  test('an Apple Music download waits on a connection, after its sign-in; the rest play offline', () {
    expect(playBlock('apple', const {}, online: false), PlayBlock.signIn);
    expect(playBlock('apple', const {}, online: true), PlayBlock.signIn);
    expect(playBlock('apple', const {'apple'}, online: false), PlayBlock.offline);
    expect(playBlock('apple', const {'apple'}, online: true), PlayBlock.none);
    expect(playBlock('deezer', const {}, online: false), PlayBlock.none);
    expect(playBlock('local', const {}, online: false), PlayBlock.none);
  });
}
