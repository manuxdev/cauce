import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:cauce/ui/core/tint.dart';
import 'package:cauce/ui/core/tint_scope.dart';

List<int> _pixels(List<Color> colors) => [
  for (final color in colors) ...[(color.r * 255).round(), (color.g * 255).round(), (color.b * 255).round(), 255],
];

void main() {
  test('the ends of lightness are black and white', () {
    expect(oklch(0, 0, 0).toARGB32(), 0xFF000000);
    expect(oklch(1, 0, 0).toARGB32(), 0xFFFFFFFF);
  });

  test('a colour made from a hue gives that hue back', () {
    for (final hue in <double>[25, 140, 200, 260, 330]) {
      expect(hueOf(oklch(0.6, 0.12, hue)), closeTo(hue, 1.5));
    }
  });

  test('matches the design accent', () {
    // oklch(0.64 0.13 25), a cover placeholder in the design, renders as #cf6963.
    final color = oklch(0.64, 0.13, 25);
    expect((color.r * 255).round(), closeTo(0xcf, 1));
    expect((color.g * 255).round(), closeTo(0x69, 1));
    expect((color.b * 255).round(), closeTo(0x63, 1));
  });

  test('a grey cover has no hue', () {
    expect(coverHue(_pixels([const Color(0xFF808080), const Color(0xFF202020), const Color(0xFFEEEEEE)])), isNull);
  });

  test('a cover takes the hue of its coloured pixels, not its greys', () {
    final red = oklch(0.6, 0.15, 25);
    final hue = coverHue(_pixels([red, red, const Color(0xFF808080), const Color(0xFF111111), red]));
    expect(hue, closeTo(25, 3));
  });

  test('hues blend the short way round the circle', () {
    expect(lerpHue(350, 10, 0.5), closeTo(0, 0.001));
    expect(lerpHue(10, 350, 0.25), closeTo(5, 0.001));
    expect(lerpHue(100, 200, 0.5), closeTo(150, 0.001));
  });

  test('a tint fades in from neutral without sweeping through other hues', () {
    final half = Tint.lerp(Tint.neutral, const Tint(140), 0.5);
    expect(half.hue, 140);
    expect(half.strength, 0.5);
    expect(Tint.lerp(const Tint(140), Tint.neutral, 1).strength, 0);
  });

  test('between two covers the hue takes the short way', () {
    expect(Tint.lerp(const Tint(350), const Tint(30), 0.5).hue, closeTo(10, 0.001));
  });

  test('a cover\'s brightness is its pixels\' average relative luminance', () {
    expect(coverLuminance([255, 255, 255, 255, 0, 0, 0, 255]), closeTo(0.5, 1e-9));
    expect(coverLuminance(const []), 0);
  });

  test('the glass darkens just enough for white text to read at 4.5:1', () {
    for (final behind in [0.0, 0.2, 0.5, 1.0]) {
      final alpha = glassAlpha(behind);
      final under = (1 - alpha) * behind + alpha * glassFill;
      expect((1.05) / (under + 0.05), greaterThanOrEqualTo(4.5 - 1e-9));
      expect(alpha, inInclusiveRange(0.3, 1));
    }
    expect(glassAlpha(0), 0.3);
    expect(glassAlpha(1), greaterThan(glassAlpha(0.5)));
  });
}
