import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:cauce/ui/core/error_text.dart';

void main() {
  String key(String message) => errorKey(AnyhowException(message));

  test('connection trouble reads as no connection', () {
    expect(key('error sending request for url (https://music.example.com/): dns error'), 'error.network');
    expect(key('operation timed out'), 'error.network');
    expect(errorKey(const SocketException('Connection failed')), 'error.network');
  });

  test('a lost or refused session asks to sign in again', () {
    expect(key('subsonic is not signed in'), 'error.session');
    expect(key('HTTP status client error (401 Unauthorized)'), 'error.session');
  });

  test('region, missing, busy and storage each say what happened', () {
    expect(key('track is not available in your country'), 'error.region');
    expect(key('HTTP status client error (404 Not Found)'), 'error.notFound');
    expect(key('HTTP status client error (429 Too Many Requests)'), 'error.busy');
    expect(key('No space left on device (os error 28)'), 'error.storage');
  });

  test('anything else is a plain something went wrong, never the raw text', () {
    expect(key('AnyhowException(weird internal thing)'), 'error.unknown');
    expect(errorKey(StateError('x')), 'error.unknown');
  });
}
