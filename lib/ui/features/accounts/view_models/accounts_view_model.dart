import 'package:flutter/foundation.dart';

import '../../../../src/rust/api/player.dart' as core;
import '../../../core/error_text.dart';

/// A streaming service the app can sign in to.
class StreamingService {
  const StreamingService(this.slug, this.name);

  final String slug;
  final String name;
}

const streamingServices = [
  StreamingService('youtube', 'YouTube Music'),
  StreamingService('deezer', 'Deezer'),
  StreamingService('spotify', 'Spotify'),
  StreamingService('tidal', 'Tidal'),
  StreamingService('subsonic', 'Subsonic'),
];

/// Which services have an account in, by display name.
class AccountsViewModel extends ChangeNotifier {
  final Map<String, String> _accounts = {};
  final Set<String> _restoring = {};
  final Map<String, String> _errors = {};

  bool _settled = false;

  /// The services with an account stored on the phone, known without reaching them.
  late final Set<String> _stored = {
    for (final service in streamingServices)
      if (_isStored(service.slug)) service.slug,
  };

  static bool _isStored(String slug) {
    try {
      return core.stored(slug: slug);
    } catch (_) {
      return false;
    }
  }

  /// Whether any account is stored, so the app can open before reaching it.
  bool get anyStored => _stored.isNotEmpty;

  /// Whether any stored account is still being brought back.
  bool get restoringAny => _restoring.isNotEmpty;

  /// Whether a stored account could not be reached, as happens without a network.
  bool get unreachable => _stored.any((slug) => !signedIn(slug) && _errors.containsKey(slug));

  /// Whether every stored account has been tried, so an empty `connected` means none.
  bool get settled => _settled;

  bool signedIn(String slug) => _accounts.containsKey(slug);

  /// Whether `slug` has an account kept on the phone, reached or not.
  bool stored(String slug) => _stored.contains(slug);

  /// Signed in with an account that only browses, such as a free Spotify one: its songs play
  /// from another connected service.
  bool browsesOnly(String slug) => signedIn(slug) && !core.streams(slug: slug);
  String? account(String slug) => _accounts[slug];
  bool restoring(String slug) => _restoring.contains(slug);

  /// Why the last restore of `slug` failed. Cleared once the service has an account.
  String? error(String slug) => _errors[slug];

  List<StreamingService> get connected => streamingServices.where((service) => signedIn(service.slug)).toList();

  /// Brings back every stored account, all at once: a slow service does not hold up the rest.
  Future<void> restoreAll() async {
    await Future.wait([for (final service in streamingServices) _restore(service.slug)]);
    _settled = true;
    notifyListeners();
  }

  Future<void> _restore(String slug) async {
    _restoring.add(slug);
    notifyListeners();
    try {
      final name = await core.restore(slug: slug);
      if (name != null) _accounts[slug] = name;
      _errors.remove(slug);
    } catch (error) {
      _errors[slug] = explainError(error);
    }
    _restoring.remove(slug);
    notifyListeners();
  }

  void signedInAs(String slug, String name) {
    _accounts[slug] = name;
    _stored.add(slug);
    _errors.remove(slug);
    notifyListeners();
  }

  Future<void> signOut(String slug) async {
    await core.signOut(slug: slug);
    _accounts.remove(slug);
    _stored.remove(slug);
    notifyListeners();
  }
}
