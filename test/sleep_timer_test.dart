import 'package:flutter_test/flutter_test.dart';
import 'package:cauce/ui/features/player/sleep_timer.dart';

void main() {
  testWidgets('pauses once the time is up', (tester) async {
    var paused = 0;
    final timer = SleepTimer(pause: () async => paused++);
    timer.start(const Duration(minutes: 15));
    expect(timer.active, isTrue);
    await tester.pump(const Duration(minutes: 14));
    expect(paused, 0);
    await tester.pump(const Duration(minutes: 1));
    expect(paused, 1);
    expect(timer.active, isFalse);
  });

  testWidgets('cancelling keeps playing', (tester) async {
    var paused = 0;
    final timer = SleepTimer(pause: () async => paused++);
    timer.start(const Duration(minutes: 5));
    timer.cancel();
    await tester.pump(const Duration(minutes: 10));
    expect(paused, 0);
    expect(timer.active, isFalse);
  });

  testWidgets('a new time replaces the old one', (tester) async {
    var paused = 0;
    final timer = SleepTimer(pause: () async => paused++);
    timer.start(const Duration(minutes: 5));
    timer.start(const Duration(minutes: 30));
    await tester.pump(const Duration(minutes: 10));
    expect(paused, 0);
    expect(timer.left, const Duration(minutes: 20));
    timer.cancel();
  });
}
