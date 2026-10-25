import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../../core/app_prefs.dart';
import '../../../core/artwork.dart';
import '../../../core/motion.dart';

/// How a design's piece goes from one song to the next.
enum SwapStyle {
  /// The vinyl's: going on, the old one rolls away left turning back 50° and the new one rolls in
  /// from the right; going back, the other way round.
  roll,

  /// Out with a fade and a slight grow, in the same way.
  fade,
}

/// Whether the player moves at all: not with Reduce Motion.
bool moves(BuildContext context) => !MediaQuery.disableAnimationsOf(context);

/// [child] swapping in [style] whenever [id] changes; a plain fade with Reduce Motion or when the
/// listener asked for fades.
class TrackSwap extends StatefulWidget {
  const TrackSwap({super.key, required this.id, required this.style, required this.child, this.order = 0});

  final Object id;
  final SwapStyle style;
  final Widget child;

  /// Where the song sits in the queue: a smaller one than before means the listener went back,
  /// and the roll runs the other way.
  final int order;

  @override
  State<TrackSwap> createState() => _TrackSwapState();
}

class _TrackSwapState extends State<TrackSwap> {
  bool _forward = true;

  @override
  void didUpdateWidget(TrackSwap old) {
    super.didUpdateWidget(old);
    // ponytail: repeat wrapping from the last song to the first reads as going back.
    if (old.id != widget.id) _forward = widget.order >= old.order;
  }

  @override
  Widget build(BuildContext context) {
    final TrackSwap(:id, :style, :child) = widget;
    final still = !moves(context);
    final roll = style == SwapStyle.roll && appPrefs.trackChange == TrackChange.design && !still;
    final reach = appPrefs.intensity.scale;
    return AnimatedSwitcher(
      duration: Duration(milliseconds: roll ? 520 : 360),
      switchInCurve: CauceCurves.exit,
      switchOutCurve: Curves.easeIn,
      layoutBuilder: (current, previous) => Stack(alignment: Alignment.center, children: [...previous, ?current]),
      transitionBuilder: (child, animation) {
        final arriving = child.key == ValueKey(id);
        return AnimatedBuilder(
          animation: animation,
          child: child,
          builder: (context, child) {
            final away = 1 - animation.value;
            if (still) return Opacity(opacity: animation.value, child: child);
            if (!roll) {
              return Opacity(
                opacity: animation.value,
                child: Transform.scale(scale: 1 + 0.04 * reach * away, child: child),
              );
            }
            // Going on: arriving from the right, leaving to the left; going back, mirrored.
            final side = (arriving ? 1 : -1) * (_forward ? 1 : -1);
            return Opacity(
              opacity: animation.value.clamp(0.0, 1.0),
              child: FractionalTranslation(
                translation: Offset(0.6 * side * away, 0),
                child: Transform.rotate(angle: side * 50 * math.pi / 180 * away, child: child),
              ),
            );
          },
        );
      },
      child: KeyedSubtree(key: ValueKey(id), child: child),
    );
  }
}

/// [url]'s picture filling its box, drifting slowly as a camera over a still: up to 10 % larger
/// and a little aside, over 16 s each way, while [moving].
class DriftingCover extends StatefulWidget {
  const DriftingCover({super.key, required this.url, required this.moving});

  final String? url;
  final bool moving;

  @override
  State<DriftingCover> createState() => _DriftingCoverState();
}

class _DriftingCoverState extends State<DriftingCover> with SingleTickerProviderStateMixin {
  late final _drift = AnimationController(vsync: this, duration: const Duration(seconds: 16));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _follow();
  }

  @override
  void didUpdateWidget(DriftingCover old) {
    super.didUpdateWidget(old);
    _follow();
  }

  void _follow() {
    final on = widget.moving && appPrefs.movingBackground && moves(context);
    if (on && !_drift.isAnimating) _drift.repeat(reverse: true);
    if (!on && _drift.isAnimating) _drift.stop();
  }

  @override
  void dispose() {
    _drift.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reach = appPrefs.intensity.scale;
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        return ClipRect(
          child: AnimatedBuilder(
            animation: _drift,
            builder: (context, child) {
              final t = Curves.easeInOut.transform(_drift.value);
              return Transform.translate(
                offset: Offset(-0.03 * size.width * t * reach, 0.02 * size.height * t * reach),
                child: Transform.scale(scale: 1 + 0.1 * t * reach, child: child),
              );
            },
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 600),
              child: SizedBox.expand(
                key: ValueKey(widget.url),
                child: FullCover(url: widget.url),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// A title that sets itself letter by letter whenever it changes, each rising into place 50 ms
/// after the one before, at [size] or smaller down to [smallest] when it does not fit two lines.
class LetterTitle extends StatefulWidget {
  const LetterTitle({super.key, required this.text, required this.style, this.size = 84, this.smallest = 56});

  final String text;
  final TextStyle style;
  final double size;
  final double smallest;

  @override
  State<LetterTitle> createState() => _LetterTitleState();
}

class _LetterTitleState extends State<LetterTitle> with SingleTickerProviderStateMixin {
  late final _rise = AnimationController(vsync: this, value: 1);

  @override
  void didUpdateWidget(LetterTitle old) {
    super.didUpdateWidget(old);
    if (old.text == widget.text) return;
    final letters = widget.text.characters.length;
    _rise.duration = Duration(milliseconds: 420 + 50 * letters);
    if (moves(context) && appPrefs.trackChange == TrackChange.design) {
      _rise.forward(from: 0);
    } else {
      _rise.value = 1;
    }
  }

  @override
  void dispose() {
    _rise.dispose();
    super.dispose();
  }

  /// The largest size from [LetterTitle.size] down that sets the title in two lines.
  double _fit(double width, TextScaler scaler) {
    for (var size = widget.size; size > widget.smallest; size -= 4) {
      final painter = TextPainter(
        text: TextSpan(
          text: widget.text,
          style: widget.style.copyWith(fontSize: size),
        ),
        textDirection: TextDirection.ltr,
        textScaler: scaler,
        maxLines: 2,
      )..layout(maxWidth: width);
      final fits = !painter.didExceedMaxLines && !_breaksWord(size, width, scaler);
      painter.dispose();
      if (fits) return size;
    }
    return widget.smallest;
  }

  /// Whether a single word is wider than the line, which would break it mid-word.
  bool _breaksWord(double size, double width, TextScaler scaler) {
    for (final word in widget.text.split(' ')) {
      final painter = TextPainter(
        text: TextSpan(
          text: word,
          style: widget.style.copyWith(fontSize: size),
        ),
        textDirection: TextDirection.ltr,
        textScaler: scaler,
      )..layout();
      final wide = painter.width > width;
      painter.dispose();
      if (wide) return true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = _fit(constraints.maxWidth, MediaQuery.textScalerOf(context));
        final style = widget.style.copyWith(fontSize: size);
        final letters = widget.text.characters.toList();
        final total = _rise.duration?.inMilliseconds ?? 1;
        return Semantics(
          label: widget.text,
          child: ExcludeSemantics(
            child: AnimatedBuilder(
              animation: _rise,
              builder: (context, _) => Text.rich(
                TextSpan(
                  children: [
                    for (final (index, letter) in letters.indexed)
                      WidgetSpan(
                        alignment: PlaceholderAlignment.baseline,
                        baseline: TextBaseline.alphabetic,
                        child: _letter(letter, style, index, total),
                      ),
                  ],
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _letter(String letter, TextStyle style, int index, int total) {
    if (_rise.value == 1) return Text(letter, style: style);
    final start = 50 * index / total;
    final end = math.min(1.0, start + 420 / total);
    final t = CauceCurves.exit.transform(((_rise.value - start) / (end - start)).clamp(0.0, 1.0));
    return Opacity(
      opacity: t,
      child: FractionalTranslation(
        translation: Offset(0, 0.45 * (1 - t)),
        child: Text(letter, style: style),
      ),
    );
  }
}

/// Turns while [playing], once every 5 s, and slows to a stop with inertia on pause rather than
/// halting; still with Reduce Motion or when the listener turned spinning off.
class Spinning extends StatefulWidget {
  const Spinning({super.key, required this.playing, required this.child});

  final bool playing;
  final Widget child;

  @override
  State<Spinning> createState() => _SpinningState();
}

class _SpinningState extends State<Spinning> with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  Duration _last = Duration.zero;

  /// Turns so far, and turns a second now.
  double _angle = 0;
  double _speed = 0;

  static const _full = 1 / 5;

  bool get _on => widget.playing && appPrefs.spinVinyl && moves(context);

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_turn);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _follow();
  }

  @override
  void didUpdateWidget(Spinning old) {
    super.didUpdateWidget(old);
    _follow();
  }

  void _follow() {
    if (!moves(context) || !appPrefs.spinVinyl) {
      _ticker.stop();
      _speed = 0;
      return;
    }
    if ((_on || _speed > 0) && !_ticker.isActive) {
      _last = Duration.zero;
      _ticker.start();
    }
  }

  void _turn(Duration elapsed) {
    final step = (elapsed - _last).inMicroseconds / 1e6;
    _last = elapsed;
    // Eases toward full speed or a stop over about a third of a second, so a pause coasts.
    final target = _on ? _full : 0.0;
    _speed += (target - _speed) * (1 - math.exp(-step / 0.35));
    if (!_on && _speed < 0.002) {
      _speed = 0;
      _ticker.stop();
    }
    setState(() => _angle = (_angle + _speed * step) % 1);
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Transform.rotate(angle: _angle * 2 * math.pi, child: widget.child);
}

/// A record with [url]'s cover as its label, grooves round it and a sheen that stays put as it
/// turns.
class VinylDisc extends StatelessWidget {
  const VinylDisc({super.key, required this.url, required this.size, required this.playing});

  final String? url;
  final double size;
  final bool playing;

  @override
  Widget build(BuildContext context) {
    final label = size * 0.36;
    return SizedBox.square(
      dimension: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Spinning(
            playing: playing,
            child: Container(
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: Color(0xFF17131A),
                boxShadow: [BoxShadow(color: Color(0x80000000), blurRadius: 40, offset: Offset(0, 18))],
              ),
              child: CustomPaint(
                painter: _Grooves(),
                child: Center(
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      ClipOval(
                        child: Artwork(url: url, size: label, radius: 0),
                      ),
                      Container(
                        width: label * 0.1,
                        height: label * 0.1,
                        decoration: const BoxDecoration(color: Color(0xFF17131A), shape: BoxShape.circle),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          // The light on it does not turn with it.
          IgnorePointer(
            child: Container(
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                gradient: SweepGradient(
                  colors: [
                    Color(0x00FFFFFF),
                    Color(0x14FFFFFF),
                    Color(0x00FFFFFF),
                    Color(0x00FFFFFF),
                    Color(0x14FFFFFF),
                    Color(0x00FFFFFF),
                  ],
                  stops: [0, 0.12, 0.25, 0.5, 0.62, 0.75],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Grooves extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final centre = size.center(Offset.zero);
    final outer = size.shortestSide / 2;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    for (var radius = outer * 0.4; radius < outer - 4; radius += 3) {
      paint.color = (radius ~/ 3).isEven ? const Color(0xFF251F27) : const Color(0xFF1B161D);
      canvas.drawCircle(centre, radius, paint);
    }
  }

  @override
  bool shouldRepaint(_Grooves old) => false;
}

/// [url]'s picture filling whatever box it is given.
class FullCover extends StatelessWidget {
  const FullCover({super.key, required this.url});

  final String? url;

  @override
  Widget build(BuildContext context) {
    final provider = artworkProvider(url);
    if (provider == null) return const ColoredBox(color: Color(0xFF2A2026));
    return Image(image: provider, fit: BoxFit.cover, gaplessPlayback: true);
  }
}
