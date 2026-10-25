import 'package:flutter_test/flutter_test.dart';
import 'package:cauce/ui/core/toast.dart';

void main() {
  testWidgets('a toast stays 3 s with text only, 4 s with an action and 6 s with undo', (tester) async {
    final center = ToastCenter();
    for (final (toast, seconds) in [
      (const Toast(title: 'Link copied'), 3),
      (Toast(title: 'Added', action: 'View', onAction: () {}), 4),
      (Toast(title: 'Deleted', onUndo: () {}), 6),
    ]) {
      center.show(toast);
      await tester.pump(Duration(milliseconds: seconds * 1000 - 100));
      expect(center.value, same(toast));
      await tester.pump(const Duration(milliseconds: 200));
      expect(center.value, isNull);
    }
  });

  testWidgets('undo cancels what the toast holds back; letting it go carries it out', (tester) async {
    final center = ToastCenter();
    var undone = 0, done = 0;
    center.show(Toast(title: 'Deleted', onUndo: () => undone++, onGone: () => done++));
    center.undo();
    await tester.pump(const Duration(seconds: 7));
    expect((undone, done), (1, 0));

    center.show(Toast(title: 'Deleted', onUndo: () => undone++, onGone: () => done++));
    await tester.pump(const Duration(seconds: 7));
    expect((undone, done), (1, 1));
  });

  testWidgets('a new toast replaces the one showing, which is then gone', (tester) async {
    final center = ToastCenter();
    var done = 0;
    center.show(Toast(title: 'Deleted', onUndo: () {}, onGone: () => done++));
    const next = Toast(title: 'Link copied');
    center.show(next);
    expect(center.value, same(next));
    expect(done, 1);
    center.dismiss();
  });

  testWidgets('the time stops while the toast is held', (tester) async {
    final center = ToastCenter();
    const toast = Toast(title: 'Link copied');
    center.show(toast);
    center.hold(true);
    await tester.pump(const Duration(seconds: 10));
    expect(center.value, same(toast));
    center.hold(false);
    await tester.pump(const Duration(seconds: 3));
    expect(center.value, isNull);
  });
}
