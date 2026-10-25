import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:cauce/ui/core/app_prefs.dart';
import 'package:cauce/ui/core/theme.dart';
import 'package:cauce/ui/core/tint.dart';

void main() {
  test('dark is light text on dark pages, light the other way round', () {
    final dark = Palette.of(light: false, accent: AccentChoice.magenta);
    final light = Palette.of(light: true, accent: AccentChoice.magenta);
    expect(dark.background.computeLuminance(), lessThan(0.05));
    expect(dark.foreground.computeLuminance(), greaterThan(0.9));
    expect(light.background.computeLuminance(), greaterThan(0.8));
    expect(light.foreground.computeLuminance(), lessThan(0.05));
  });

  test('the dark magenta accent is the design one', () {
    expect(Palette.of(light: false, accent: AccentChoice.magenta).accent, const Color(0xFFD36FD0));
  });

  test('text on the accent stays readable for every accent in both themes', () {
    for (final light in [false, true]) {
      for (final accent in AccentChoice.values) {
        final palette = Palette.of(light: light, accent: accent, coverHue: 200);
        final a = palette.accent.computeLuminance();
        final b = palette.onAccent.computeLuminance();
        final contrast = (a > b ? a + 0.05 : b + 0.05) / (a > b ? b + 0.05 : a + 0.05);
        expect(contrast, greaterThan(3), reason: '$accent light=$light');
      }
    }
  });

  test('the cover accent takes the cover hue, and magenta when there is none', () {
    expect(hueOf(Palette.of(light: false, accent: AccentChoice.cover, coverHue: 140).accent), closeTo(140, 2));
    expect(
      Palette.of(light: false, accent: AccentChoice.cover).accent,
      Palette.of(light: false, accent: AccentChoice.magenta).accent,
    );
  });
}
