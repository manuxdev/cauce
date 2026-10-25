import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show Uint8List;
import 'package:flutter/material.dart';

import 'app_prefs.dart';
import 'artwork.dart';
import 'theme.dart';
import 'tint.dart';

/// The colour a part of the app is tinted with: a cover's hue, and how strongly it shows. At
/// strength 0 it is the app's neutral plum grey.
@immutable
class Tint {
  const Tint(this.hue, [this.strength = 1, this.scale = 1]);

  /// No cover: the neutral grey.
  static const neutral = Tint(_neutralHue, 0);

  /// The neutral hue, a faint plum.
  static const _neutralHue = 320.0;
  static const _neutralChroma = 0.013;

  /// Tints for a cover's hue, neutral when it has none.
  factory Tint.of(double? hue, [double scale = 1]) => hue == null ? Tint(_neutralHue, 0, scale) : Tint(hue, 1, scale);

  final double hue;
  final double strength;

  /// How much of the cover the listener lets colour the app, from [CoverColor].
  final double scale;

  /// The same cover at full strength, for the player, which is always coloured by it.
  Tint get vivid => Tint(hue, strength);

  /// The colour at OKLCH lightness [l] with chroma [c] at full strength.
  Color shade(double l, double c, [double alpha = 1]) =>
      oklch(l, _neutralChroma + (c - _neutralChroma) * strength * scale, hue, alpha);

  /// [shade] in the dark theme; in the light one, as light as it is dark there, with softer colour.
  Color tone(double l, double c, [double alpha = 1]) =>
      CauceColors.light ? shade(1.12 - l, c * 0.5, alpha) : shade(l, c, alpha);

  /// A tab page's background.
  Color get page => tone(0.17, 0.03);

  /// Chips, soft buttons and empty-state badges over [page].
  Color get surface => tone(0.25, 0.03);

  /// What is pressed or picked among surfaces.
  Color get raised => tone(0.27, 0.04);

  /// The frosted dock under the tabs.
  Color get dock => CauceColors.light ? shade(0.98, 0.02, 0.85) : shade(0.3, 0.08, 0.9);

  /// The full player.
  Color get player => shade(0.34, 0.09);

  /// The ink on a cover-coloured surface.
  Color get ink => shade(0.3, 0.08);

  static Tint lerp(Tint a, Tint b, double t) {
    // From or to neutral only the strength moves, so the hue never sweeps through others.
    final hue = a.strength == 0
        ? b.hue
        : b.strength == 0
        ? a.hue
        : lerpHue(a.hue, b.hue, t);
    return Tint(hue, a.strength + (b.strength - a.strength) * t, a.scale + (b.scale - a.scale) * t);
  }

  @override
  bool operator ==(Object other) =>
      other is Tint && other.hue == hue && other.strength == strength && other.scale == scale;

  @override
  int get hashCode => Object.hash(hue, strength, scale);
}

/// The tint the widgets under it are drawn with.
class TintScope extends InheritedWidget {
  const TintScope({super.key, required this.tint, required super.child});

  final Tint tint;

  static Tint of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<TintScope>()?.tint ?? Tint.neutral;

  @override
  bool updateShouldNotify(TintScope old) => old.tint != tint;
}

/// Hands [tint] down, fading into each new one over 600 ms, the slowest change in the app on
/// purpose: the colour follows the music.
class AnimatedTint extends StatefulWidget {
  const AnimatedTint({super.key, required this.tint, required this.child});

  final Tint tint;
  final Widget child;

  @override
  State<AnimatedTint> createState() => _AnimatedTintState();
}

class _AnimatedTintState extends State<AnimatedTint> with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(vsync: this, duration: const Duration(milliseconds: 600));
  late Tint _from = widget.tint;
  late Tint _to = widget.tint;

  Tint get _now => Tint.lerp(_from, _to, Curves.easeInOut.transform(_controller.value));

  @override
  void didUpdateWidget(AnimatedTint old) {
    super.didUpdateWidget(old);
    if (widget.tint == _to) return;
    _from = _now;
    _to = widget.tint;
    if (MediaQuery.disableAnimationsOf(context)) {
      _controller.value = 1;
    } else {
      _controller.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _controller,
    builder: (context, child) => TintScope(tint: _now, child: child!),
    child: widget.child,
  );
}

/// Tints [child] with the hue of the cover at [url] as strongly as [CoverColor] lets it, neutral
/// until it is known.
class CoverTint extends StatelessWidget {
  const CoverTint({super.key, required this.url, required this.child});

  final String? url;
  final Widget child;

  @override
  Widget build(BuildContext context) => FutureBuilder<double?>(
    future: coverHueOf(url),
    builder: (context, snapshot) =>
        AnimatedTint(tint: Tint.of(snapshot.data, appPrefs.coverColor.strength), child: child),
  );
}

final _hues = <String, Future<double?>>{};
final _brightness = <String, Future<double?>>{};

/// The hue the cover at [url] reads as, worked out once per cover from a tiny decode of it.
Future<double?> coverHueOf(String? url) {
  if (url == null) return Future.value();
  return _hues.putIfAbsent(url, () async {
    final bytes = await _tiny(url);
    return bytes == null ? null : coverHue(bytes);
  });
}

/// How bright the bottom half of the cover at [url] is, 0 to 1, where the immersive glass sits.
Future<double?> coverBottomLuminance(String? url) {
  if (url == null) return Future.value();
  return _brightness.putIfAbsent(url, () async {
    final bytes = await _tiny(url);
    // The lower 12 of its 24 rows.
    return bytes == null ? null : coverLuminance(bytes.sublist(bytes.length ~/ 2));
  });
}

/// The cover at [url] decoded at 24 by 24, as RGBA bytes.
Future<Uint8List?> _tiny(String url) async {
  final provider = artworkProvider(url);
  if (provider == null) return null;
  final completer = Completer<ui.Image?>();
  final stream = ResizeImage(provider, width: 24, height: 24).resolve(ImageConfiguration.empty);
  late final ImageStreamListener listener;
  listener = ImageStreamListener(
    (info, _) {
      completer.complete(info.image.clone());
      stream.removeListener(listener);
    },
    onError: (_, _) {
      completer.complete(null);
      stream.removeListener(listener);
    },
  );
  stream.addListener(listener);
  final image = await completer.future;
  if (image == null) return null;
  final bytes = await image.toByteData();
  image.dispose();
  return bytes?.buffer.asUint8List();
}
