import 'dart:math' as math;
import 'dart:ui';

/// The colour at OKLCH lightness [l] (0–1), chroma [c] and hue [h] in degrees, clipped into sRGB.
/// The design gives every tint this way, so equal lightness looks equally light at any hue.
Color oklch(double l, double c, double h, [double alpha = 1]) {
  final radians = h * math.pi / 180;
  final a = c * math.cos(radians);
  final b = c * math.sin(radians);
  final l1 = math.pow(l + 0.3963377774 * a + 0.2158037573 * b, 3);
  final m1 = math.pow(l - 0.1055613458 * a - 0.0638541728 * b, 3);
  final s1 = math.pow(l - 0.0894841775 * a - 1.2914855480 * b, 3);
  double channel(num linear) {
    final value = linear <= 0.0031308 ? 12.92 * linear : 1.055 * math.pow(linear, 1 / 2.4) - 0.055;
    return value.clamp(0.0, 1.0).toDouble();
  }

  return Color.from(
    alpha: alpha,
    red: channel(4.0767416621 * l1 - 3.3077115913 * m1 + 0.2309699292 * s1),
    green: channel(-1.2684380046 * l1 + 2.6097574011 * m1 - 0.3413193965 * s1),
    blue: channel(-0.0041960863 * l1 - 0.7034186147 * m1 + 1.7076147010 * s1),
  );
}

/// The OKLab a and b of an sRGB colour, whose angle is the hue and length the chroma.
(double, double) _ab(double red, double green, double blue) {
  double linear(double value) => value <= 0.04045 ? value / 12.92 : math.pow((value + 0.055) / 1.055, 2.4).toDouble();
  final r = linear(red), g = linear(green), b = linear(blue);
  final l = math.pow(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b, 1 / 3);
  final m = math.pow(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b, 1 / 3);
  final s = math.pow(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b, 1 / 3);
  return (
    1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
    0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s,
  );
}

double _degrees(double a, double b) => (math.atan2(b, a) * 180 / math.pi) % 360;

/// The OKLCH hue of [color] in degrees.
double hueOf(Color color) {
  final (a, b) = _ab(color.r, color.g, color.b);
  return _degrees(a, b);
}

/// The hue a cover reads as, from its RGBA bytes: the colourful pixels weighted by how colourful
/// they are, so greys and blacks do not pull it anywhere. `null` for a cover with no colour.
double? coverHue(List<int> rgba) {
  var a = 0.0, b = 0.0, weight = 0.0;
  for (var index = 0; index + 3 < rgba.length; index += 4) {
    final (pa, pb) = _ab(rgba[index] / 255, rgba[index + 1] / 255, rgba[index + 2] / 255);
    final chroma = math.sqrt(pa * pa + pb * pb);
    if (chroma < 0.03) continue;
    a += pa * chroma;
    b += pb * chroma;
    weight += chroma;
  }
  if (weight == 0 || math.sqrt(a * a + b * b) / weight < 0.02) return null;
  return _degrees(a, b);
}

/// The hue [t] of the way from [from] to [to], going the short way round.
double lerpHue(double from, double to, double t) {
  final delta = ((to - from + 540) % 360) - 180;
  return (from + delta * t) % 360;
}

double _linear(double value) => value <= 0.04045 ? value / 12.92 : math.pow((value + 0.055) / 1.055, 2.4).toDouble();

/// The WCAG relative luminance of an sRGB colour from its bytes.
double _relative(int red, int green, int blue) =>
    0.2126 * _linear(red / 255) + 0.7152 * _linear(green / 255) + 0.0722 * _linear(blue / 255);

/// How bright a cover is, from its RGBA bytes: its pixels' average relative luminance, 0 to 1.
double coverLuminance(List<int> rgba) {
  if (rgba.length < 4) return 0;
  var sum = 0.0;
  for (var index = 0; index + 3 < rgba.length; index += 4) {
    sum += _relative(rgba[index], rgba[index + 1], rgba[index + 2]);
  }
  return sum / (rgba.length ~/ 4);
}

/// The relative luminance of the immersive glass's own dark fill, rgb(40, 10, 6).
final glassFill = _relative(40, 10, 6);

/// How opaque the glass's fill must be over something [behind] bright for white text on it to
/// read at 4.5:1: no less than its usual 0.3, more over a bright cover.
double glassAlpha(double behind) {
  // White's 1.05 over the blend's luminance plus 0.05 must reach 4.5.
  const darkest = 1.05 / 4.5 - 0.05;
  if (behind <= darkest) return 0.3;
  return ((behind - darkest) / (behind - glassFill)).clamp(0.3, 1.0);
}
