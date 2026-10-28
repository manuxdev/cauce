import 'package:cauce/src/rust/api/player.dart';
import 'package:cauce/ui/features/accounts/view_models/quick_connect.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  /// Answers `answers` in turn, counting the checks and the waits between them.
  ({
    Future<QuickConnectCheck> Function() check,
    Future<void> Function(Duration) wait,
    List<Duration> waits,
    int Function() checks,
  })
  script(List<QuickConnectCheck> answers) {
    final waits = <Duration>[];
    var checks = 0;
    return (
      check: () async => answers[checks++],
      wait: (interval) async => waits.add(interval),
      waits: waits,
      checks: () => checks,
    );
  }

  test('waits between checks until the code is authorized', () async {
    final s = script([QuickConnectCheck.waiting, QuickConnectCheck.waiting, QuickConnectCheck.authorized]);
    final end = await waitForQuickConnect(check: s.check, cancelled: () => false, wait: s.wait);
    expect(end, QuickConnectEnd.authorized);
    expect(s.checks(), 3);
    expect(s.waits, List.filled(3, const Duration(seconds: 3)));
  });

  test('a code the server forgot has expired and stops the checks', () async {
    final s = script([QuickConnectCheck.waiting, QuickConnectCheck.expired, QuickConnectCheck.authorized]);
    final end = await waitForQuickConnect(check: s.check, cancelled: () => false, wait: s.wait);
    expect(end, QuickConnectEnd.expired);
    expect(s.checks(), 2);
  });

  test('cancelling stops the checks, even with one under way', () async {
    final s = script([QuickConnectCheck.waiting, QuickConnectCheck.authorized]);
    var cancelled = false;
    final end = await waitForQuickConnect(
      check: () async {
        final answer = await s.check();
        cancelled = true;
        return answer;
      },
      cancelled: () => cancelled,
      wait: s.wait,
    );
    expect(end, QuickConnectEnd.cancelled);
    expect(s.checks(), 1);
  });

  test('cancelled before the first check asks nothing', () async {
    final s = script([QuickConnectCheck.authorized]);
    final end = await waitForQuickConnect(check: s.check, cancelled: () => true, wait: s.wait);
    expect(end, QuickConnectEnd.cancelled);
    expect(s.checks(), 0);
  });

  test('a failed check ends the wait with its error', () async {
    final s = script([]);
    await expectLater(
      waitForQuickConnect(check: () async => throw StateError('offline'), cancelled: () => false, wait: s.wait),
      throwsStateError,
    );
  });
}
