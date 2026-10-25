import 'package:flutter/animation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:cauce/ui/core/motion.dart';

void main() {
  test('a spring curve starts at rest and lands on its end', () {
    for (final curve in [CauceCurves.soft, CauceCurves.vivid]) {
      expect(curve.transform(0), 0);
      expect(curve.transform(1), 1);
    }
  });

  test('the soft spring never overshoots and the vivid one does', () {
    double peak(Curve curve) =>
        [for (var step = 0; step <= 100; step++) curve.transform(step / 100)].reduce((a, b) => a > b ? a : b);
    expect(peak(CauceCurves.soft), lessThanOrEqualTo(1.001));
    expect(peak(CauceCurves.vivid), greaterThan(1.05));
  });

  test('a spring settles in the time the design gives it', () {
    expect(CauceCurves.soft.duration.inMilliseconds, closeTo(529, 5));
    expect(CauceCurves.vivid.duration.inMilliseconds, closeTo(690, 5));
  });
}
