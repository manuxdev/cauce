import '../../../../src/rust/api/player.dart' as core;

/// What became of waiting on a Quick Connect code.
enum QuickConnectEnd { authorized, expired, cancelled }

/// How long between asking the server whether the code is authorized.
const quickConnectInterval = Duration(seconds: 3);

/// Asks [check] where the code stands every [quickConnectInterval] until it is authorized or the server forgets it,
/// or [cancelled] turns true, as when the screen closes. A failed check ends the wait with its error.
Future<QuickConnectEnd> waitForQuickConnect({
  required Future<core.QuickConnectCheck> Function() check,
  required bool Function() cancelled,
  Future<void> Function(Duration)? wait,
}) async {
  final pause = wait ?? Future<void>.delayed;
  while (true) {
    await pause(quickConnectInterval);
    if (cancelled()) return QuickConnectEnd.cancelled;
    final state = await check();
    if (cancelled()) return QuickConnectEnd.cancelled;
    switch (state) {
      case core.QuickConnectCheck.waiting:
        continue;
      case core.QuickConnectCheck.authorized:
        return QuickConnectEnd.authorized;
      case core.QuickConnectCheck.expired:
        return QuickConnectEnd.expired;
    }
  }
}
