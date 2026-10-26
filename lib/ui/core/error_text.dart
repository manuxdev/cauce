import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge.dart';

import 'l10n.dart';

/// What went wrong, as one short sentence for a toast or an empty screen, in the reader's
/// language. The raw error never reaches the screen.
String explainError(Object error) => translate(errorKey(error));

/// The string key that explains `error`, read from its message and the chain of causes the
/// core reports. Earlier rules win, so the specific ones come first.
String errorKey(Object error) {
  if (error is SocketException || error is HttpException) return 'error.network';
  final text = switch (error) {
    AnyhowException(:final message) => message,
    _ => '$error',
  }.toLowerCase();
  bool has(List<String> marks) => marks.any(text.contains);
  for (final (key, marks) in _rules) {
    if (has(marks)) return key;
  }
  return 'error.unknown';
}

const _rules = [
  ('error.storage', ['no space left', 'os error 28', 'disk full']),
  ('error.busy', ['429', 'too many requests', 'rate limit', '503', 'service unavailable']),
  ('error.region', ['your country', 'region', 'geo-blocked', 'geoblocked']),
  (
    'error.session',
    [
      'not signed in',
      'sign in',
      'signed out',
      '401',
      'unauthorized',
      'expired',
      'refused the session',
      'invalid credentials',
    ],
  ),
  ('error.notFound', ['404', 'not found', 'no longer available', 'does not exist', 'unavailable']),
  (
    'error.network',
    ['error sending request', 'dns error', 'timed out', 'timeout', 'connection', 'network', 'unreachable', 'offline'],
  ),
];
