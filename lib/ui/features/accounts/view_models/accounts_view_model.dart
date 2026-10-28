import 'package:flutter/foundation.dart';

import '../../../../src/rust/api/player.dart' as core;
import '../../../core/error_text.dart';
import '../../../core/status_band.dart';

/// A streaming service the app can sign in to.
class StreamingService {
  const StreamingService(this.slug, this.name);

  final String slug;
  final String name;
}

/// Apple Music only on iOS and Android, where the system has a player or a CDM for its songs.
final streamingServices = [
  const StreamingService('youtube', 'YouTube Music'),
  const StreamingService('deezer', 'Deezer'),
  const StreamingService('spotify', 'Spotify'),
  if (defaultTargetPlatform == TargetPlatform.iOS || defaultTargetPlatform == TargetPlatform.android)
    const StreamingService('apple', 'Apple Music'),
  const StreamingService('tidal', 'Tidal'),
  const StreamingService('subsonic', 'Subsonic'),
  const StreamingService('jellyfin', 'Jellyfin'),
  const StreamingService('emby', 'Emby'),
  const StreamingService('plex', 'Plex'),
  const StreamingService('audius', 'Audius'),
];

/// Open catalogs, connected with no account: nothing of theirs downloads, as their terms allow
/// only streaming, and none of their playlists is the listener's to edit.
const openCatalogs = {'audius'};

/// Whether `source`'s track waits on signing in to its service, with `signedIn` the services
/// that have an account in. Liking always does. Playing only does for Apple Music, which keeps
/// its downloads encrypted and licenses every play afresh; the rest play their downloads from
/// the account kept on the phone. A file on the phone never waits.
bool needsSignIn(String source, Set<String> signedIn, {bool toPlay = false}) =>
    !_accountless.contains(source) && !signedIn.contains(source) && (!toPlay || source == 'apple');

/// Sources with no account behind them: files on the phone, radio stations, podcast episodes.
const _accountless = {'local', 'radio', 'podcast'};

/// What keeps a track from playing now, short of trying it.
enum PlayBlock { none, signIn, offline }

/// What keeps `source`'s track from playing, with `signedIn` as in [needsSignIn] and `online`
/// whether a license can be reached. The sign-in comes first; once in, Apple Music still needs
/// the connection for each play's license.
PlayBlock playBlock(String source, Set<String> signedIn, {required bool online}) => switch (source) {
  _ when needsSignIn(source, signedIn, toPlay: true) => PlayBlock.signIn,
  'apple' when !online => PlayBlock.offline,
  _ => PlayBlock.none,
};

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

  /// See [needsSignIn]. One still being brought back counts as in.
  bool needsSignInFor(String source, {bool toPlay = false}) =>
      needsSignIn(source, {..._accounts.keys, ..._restoring}, toPlay: toPlay);

  /// See [playBlock], offline as the platform last said or once `reachable` failed. iOS plays
  /// Apple Music through the system, which keeps its own downloads playable offline.
  PlayBlock playBlockFor(String source, {bool reachable = true}) => playBlock(source, {
    ..._accounts.keys,
    ..._restoring,
  }, online: defaultTargetPlatform == TargetPlatform.iOS || (reachable && online.value));
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
