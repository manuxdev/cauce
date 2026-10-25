import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:cauce/ui/core/icons.dart';

void main() {
  test('absolute and relative lines close into a triangle', () {
    final path = parseSvgPath('M4 5l10 7-10 7z');
    expect(path.getBounds(), const Rect.fromLTRB(4, 5, 14, 19));
    expect(path.contains(const Offset(6, 12)), isTrue);
  });

  test('numbers run together without separators', () {
    final path = parseSvgPath('M6 4h4v16H6zM14 4h4v16h-4z');
    expect(path.getBounds(), const Rect.fromLTRB(6, 4, 18, 20));
  });

  test('coordinates after a move are lines', () {
    final path = parseSvgPath('M4 10.5 12 4l8 6.5V20h-5.5v-6h-5v6H4z');
    expect(path.getBounds(), const Rect.fromLTRB(4, 4, 20, 20));
  });

  test('arcs draw a full circle from two halves', () {
    final path = parseSvgPath('M12 2a10 10 0 1 0 0 20 10 10 0 0 0 0-20z');
    final bounds = path.getBounds();
    expect(bounds.left, closeTo(2, 0.01));
    expect(bounds.right, closeTo(22, 0.01));
    expect(bounds.top, closeTo(2, 0.01));
    expect(bounds.bottom, closeTo(22, 0.01));
  });

  test('a smooth curve mirrors the last control point', () {
    final path = parseSvgPath('M0 0c0 10 10 10 10 0s10-10 10 0');
    final bounds = path.getBounds();
    expect(bounds.left, 0);
    expect(bounds.right, 20);
    expect(bounds.bottom, greaterThan(5));
    expect(bounds.top, lessThan(-5));
  });

  test('every icon in the set parses', () {
    for (final glyph in CauceGlyph.values) {
      expect(parseSvgPath(glyph.data).getBounds().isEmpty, isFalse, reason: glyph.name);
    }
  });
}
