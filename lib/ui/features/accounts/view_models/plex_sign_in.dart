import '../../../../src/rust/api/player.dart' as core;
import 'quick_connect.dart';

/// Asks [check] where the plex.tv sign-in stands until the listener approves it on Plex's page or plex.tv forgets
/// it, or [cancelled] turns true, as when the page closes. It waits as a Quick Connect code does.
Future<QuickConnectEnd> waitForPlexPin({
  required Future<core.PlexPinCheck> Function() check,
  required bool Function() cancelled,
  Future<void> Function(Duration)? wait,
}) => waitForQuickConnect(
  check: () async => switch (await check()) {
    core.PlexPinCheck.waiting => core.QuickConnectCheck.waiting,
    core.PlexPinCheck.approved => core.QuickConnectCheck.authorized,
    core.PlexPinCheck.expired => core.QuickConnectCheck.expired,
  },
  cancelled: cancelled,
  wait: wait,
);

/// The server to sign in to without asking: the only one the account has. With several, or none, there is nothing
/// to pick for the listener.
core.PlexServer? serverToPick(List<core.PlexServer> servers) => servers.length == 1 ? servers.single : null;
