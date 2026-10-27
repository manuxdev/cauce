import 'dart:math' as math;
import '../../radio/radio_section.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../core/app_prefs.dart';
import '../../../core/l10n.dart';
import '../../../core/theme.dart';
import '../../../core/tint_scope.dart';
import '../audio_levels.dart';
import '../player_design.dart';
import '../view_models/player_view_model.dart';
import 'player_parts.dart';

/// How many bars the wave draws and how many dots the dots bar has.
const waveBars = 52;
const seekDots = 30;

/// How far the tape runs in a second, one tick.
const _tapePerSecond = 4.5;

/// Where the song is, drawn in [style], with the times under it unless [times] is off. Every bar
/// takes touches across a 44-point band and only seeks when the finger lifts:
/// - line: the dot grows to 170 % with the time in a bubble over it, ticking each minute;
/// - wave: the bars under the finger grow like under a magnifier as the rest dim;
/// - ripple: it ripples while playing, flattens in 300 ms on pause and goes straight when held;
/// - capsule: thick with the time inside, it grows when held and the time follows the finger;
/// - dots: it jumps from dot to dot, each a thirtieth, with a tick on each;
/// - tape: the ruler moves under a fixed needle, to the second.
class SeekBar extends StatefulWidget {
  const SeekBar({
    super.key,
    required this.player,
    required this.style,
    this.wave,
    this.level,
    this.times = true,
    this.tag,
    this.compact = false,
  });

  final PlayerViewModel player;

  /// Any but [SeekStyle.auto] and [SeekStyle.ring], which go through [seekStyleFor] and [SeekRing].
  final SeekStyle style;

  /// The song's wave, 0 to 1 per bar; a made-up one until it is known.
  final List<double>? wave;

  /// How loud the music is now, 0 to 1, for the ripple to follow.
  final ValueListenable<double>? level;
  final bool times;

  /// The provider playing, shown between the times.
  final String? tag;

  /// Lower, for under the lyrics.
  final bool compact;

  @override
  State<SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends State<SeekBar> with TickerProviderStateMixin {
  /// Where the finger holds the bar, 0 to 1, while it is down.
  double? _held;

  /// Where the finger is across the bar while it is down, for the magnifier.
  double _x = 0;

  /// The tape's start and how far it has been dragged.
  Duration _tapeFrom = Duration.zero;
  double _tapeDx = 0;

  /// The ripple's run along the bar, and how high it ripples, 0 flat to 1.
  late final _run = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100));
  late final _swell = AnimationController(vsync: this, duration: const Duration(milliseconds: 300));

  PlayerViewModel get _player => widget.player;

  /// The song, as its wave is kept.
  String get _key => '${_player.track?.source}:${_player.track?.id}';

  /// What the ripple follows: the given level, or the music's when it moves with the audio.
  /// Each crest's swell, kept as it formed at the playhead.
  final _crests = RippleCrests();

  /// How the music swells the ripple now, its beat included.
  double get _heard => rippleSwell(_level?.value, beat: identical(_level, audioLevels) ? audioLevels.beat : 0);

  ValueListenable<double>? get _level =>
      widget.level ?? (widget.style == SeekStyle.ripple && appPrefs.reactive ? audioLevels : null);
  double get _total => _player.duration.inMilliseconds.toDouble();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _follow();
  }

  @override
  void didUpdateWidget(SeekBar old) {
    super.didUpdateWidget(old);
    _follow();
  }

  /// Ripples only while playing, not held, and motion is allowed.
  void _follow() {
    final rippling =
        widget.style == SeekStyle.ripple &&
        _player.playing &&
        _held == null &&
        !MediaQuery.disableAnimationsOf(context);
    if (rippling) {
      if (!_run.isAnimating) _run.repeat();
      _swell.forward();
    } else {
      _run.stop();
      _swell.reverse();
    }
  }

  @override
  void dispose() {
    _run.dispose();
    _swell.dispose();
    super.dispose();
  }

  void _hold(double x, double width) {
    if (_total == 0 || width == 0) return;
    var to = (x / width).clamp(0.0, 1.0);
    if (widget.style == SeekStyle.dots) to = snapToDots(to, seekDots);
    final from = _held;
    switch (widget.style) {
      case SeekStyle.dots when from != to:
        tick();
      case SeekStyle.line when from != null && (from * _total) ~/ 60000 != (to * _total) ~/ 60000:
        tick();
      default:
    }
    setState(() {
      _held = to;
      _x = x;
    });
    _follow();
  }

  void _tapeStart() {
    _tapeFrom = _player.position;
    _tapeDx = 0;
  }

  void _tapeMove(double dx) {
    if (_total == 0) return;
    _tapeDx += dx;
    final to = tapeSeek(_tapeFrom, _tapeDx, _tapePerSecond, _player.duration);
    setState(() => _held = to.inMilliseconds / _total);
    _follow();
  }

  void _release() {
    final held = _held;
    if (held == null) return;
    _player.seek(Duration(milliseconds: (held * _total).round()));
    setState(() => _held = null);
    _follow();
  }

  void _cancel() {
    setState(() => _held = null);
    _follow();
  }

  @override
  Widget build(BuildContext context) {
    // A station is live: nothing to seek in, so "Live" stands where the bar would.
    if (isStation(_player.track)) {
      return SizedBox(
        height: math.max(44.0, _height(widget.style, widget.compact)) + (widget.times ? 18 : 0),
        child: const LiveBadge(),
      );
    }
    final style = widget.style;
    final total = _total;
    final playing = total == 0 ? 0.0 : (_player.position.inMilliseconds / total).clamp(0.0, 1.0);
    final fraction = _held ?? playing;
    final at = Duration(milliseconds: (fraction * total).round());
    final tape = style == SeekStyle.tape;
    final band = math.max(44.0, _height(style, widget.compact));
    final bar = LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: tape ? null : (details) => _hold(details.localPosition.dx, width),
          onTapUp: tape ? null : (_) => _release(),
          onTapCancel: tape ? null : _cancel,
          onHorizontalDragStart: (details) => tape ? _tapeStart() : _hold(details.localPosition.dx, width),
          onHorizontalDragUpdate: (details) =>
              tape ? _tapeMove(details.delta.dx) : _hold(details.localPosition.dx, width),
          onHorizontalDragEnd: (_) => _release(),
          onHorizontalDragCancel: _cancel,
          child: SizedBox(
            height: band,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned.fill(
                  child: TweenAnimationBuilder<double>(
                    tween: Tween(end: _held != null ? 1 : 0),
                    duration: const Duration(milliseconds: 160),
                    curve: Curves.easeOut,
                    builder: (context, grow, _) => AnimatedBuilder(
                      animation: Listenable.merge([_run, _swell, ?_level, if (style == SeekStyle.wave) waveforms]),
                      builder: (context, _) => CustomPaint(
                        painter: SeekPainter(
                          style: style,
                          fraction: fraction,
                          grow: grow,
                          finger: _held != null ? _x : null,
                          wave: widget.wave ?? waveforms.of(_key) ?? placeholderWave(_key, waveBars),
                          ripple: _run.value,
                          crests: style == SeekStyle.ripple ? (_crests..tick(_run.value, _heard)) : null,
                          swell: _swell.value * appPrefs.intensity.scale,
                          height: _height(style, widget.compact),
                          label: formatDuration(at),
                          ink: TintScope.of(context).vivid.ink,
                          needle: CauceColors.dark.accent,
                          seconds: total / 1000,
                        ),
                      ),
                    ),
                  ),
                ),
                if (style == SeekStyle.line && _held != null)
                  Positioned(
                    left: (width * fraction - 32).clamp(-8.0, width - 56),
                    bottom: band / 2 + 18,
                    child: _Bubble(label: formatDuration(at)),
                  ),
              ],
            ),
          ),
        );
      },
    );
    final held = style == SeekStyle.ripple && widget.level == null ? LevelsHold(child: bar) : bar;
    if (!widget.times) return held;
    const timeStyle = TextStyle(fontSize: 12.5, color: Color(0x99FFFFFF), fontFeatures: [FontFeature.tabularFigures()]);
    return Column(
      children: [
        held,
        Row(
          children: [
            Expanded(child: Text(formatDuration(at), style: timeStyle)),
            if (widget.tag case final tag?) SourceTag(slug: tag, player: _player),
            Expanded(
              child: Text(
                '−${formatDuration(Duration(milliseconds: (total - fraction * total).round()))}',
                textAlign: TextAlign.end,
                style: timeStyle,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// How tall each bar is drawn, inside its 44-point band.
double _height(SeekStyle style, bool compact) => switch (style) {
  SeekStyle.wave => compact ? 26 : 38,
  SeekStyle.ripple => 30,
  SeekStyle.capsule => 16,
  SeekStyle.dots => 8,
  SeekStyle.tape => compact ? 40 : 52,
  _ => 4,
};

/// The time over the line's dot while it is held.
class _Bubble extends StatelessWidget {
  const _Bubble({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 64,
      padding: const EdgeInsets.symmetric(vertical: 5),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        boxShadow: const [BoxShadow(color: Color(0x59000000), blurRadius: 12, offset: Offset(0, 4))],
      ),
      child: Text(
        label,
        textAlign: TextAlign.center,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w700,
          color: TintScope.of(context).vivid.ink,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}

/// A bar standing still at [fraction], as the settings show each one.
class SeekPreview extends StatelessWidget {
  const SeekPreview({super.key, required this.style, this.fraction = 0.4, this.width = 118});

  final SeekStyle style;
  final double fraction;
  final double width;

  @override
  Widget build(BuildContext context) {
    final height = style == SeekStyle.tape ? 30.0 : math.min(_height(style, true), 26.0);
    return SizedBox(
      width: width,
      height: math.max(height, 16),
      child: CustomPaint(
        painter: SeekPainter(
          style: style,
          fraction: fraction,
          wave: placeholderWave('preview', 28),
          swell: 1,
          ripple: 0,
          height: height,
          label: '1:24',
          ink: TintScope.of(context).vivid.ink,
          needle: CauceColors.dark.accent,
          seconds: 200,
        ),
      ),
    );
  }
}

/// Draws a bar in [style] at [fraction], centred on its box.
class SeekPainter extends CustomPainter {
  SeekPainter({
    required this.style,
    required this.fraction,
    required this.wave,
    required this.ripple,
    required this.swell,
    required this.height,
    required this.label,
    required this.ink,
    required this.needle,
    required this.seconds,
    this.grow = 0,
    this.finger,
    this.crests,
  });

  final SeekStyle style;
  final double fraction;

  /// 0 at rest to 1 held.
  final double grow;

  /// Where the finger is across the bar, while held.
  final double? finger;
  final List<double> wave;

  /// The ripple's run, 0 to 1, and its height, 0 flat to about 1.
  final double ripple;
  final double swell;
  final double height;

  /// Each ripple crest's own swell, newest at the playhead; without them all swell alike.
  final RippleCrests? crests;

  /// The time at [fraction], for the capsule.
  final String label;
  final Color ink;
  final Color needle;

  /// How long the song is, for the tape.
  final double seconds;

  static const _rest = Color(0x38FFFFFF);

  @override
  void paint(Canvas canvas, Size size) {
    final mid = size.height / 2;
    final x = size.width * fraction;
    final paint = Paint()..isAntiAlias = true;
    switch (style) {
      case SeekStyle.wave:
        _wave(canvas, size, mid);
      case SeekStyle.ripple:
        _ripple(canvas, size, mid, x);
      case SeekStyle.capsule:
        _capsule(canvas, size, mid, x);
      case SeekStyle.dots:
        final step = size.width / seekDots;
        final lit = (fraction * seekDots).round();
        for (var dot = 0; dot < seekDots; dot++) {
          final current = dot == lit - 1 || (lit == 0 && dot == 0 && grow > 0);
          final radius = current ? 3 + 2.5 * grow : 3.0;
          paint.color = dot < lit ? Colors.white : _rest;
          canvas.drawCircle(Offset(step * (dot + 0.5), mid), radius, paint);
        }
      case SeekStyle.tape:
        _tape(canvas, size, mid);
      default:
        // The line: 4 points, 7 held, with a dot that grows to 170 %.
        final thick = 4 + 3 * grow;
        final track = RRect.fromLTRBR(0, mid - thick / 2, size.width, mid + thick / 2, Radius.circular(thick));
        canvas.drawRRect(track, paint..color = const Color(0x33FFFFFF));
        canvas.drawRRect(
          RRect.fromLTRBR(0, mid - thick / 2, x, mid + thick / 2, Radius.circular(thick)),
          paint..color = Colors.white,
        );
        final radius = 7 * (1 + 0.7 * grow);
        canvas.drawCircle(
          Offset(x, mid + 2),
          radius,
          Paint()
            ..color = const Color(0x59000000)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
        );
        canvas.drawCircle(Offset(x, mid), radius, paint..color = Colors.white);
    }
  }

  void _wave(Canvas canvas, Size size, double mid) {
    // Fewer bars when narrow: 52 bars' gaps alone are wider than a preview, leaving none to draw.
    final bars = resampleWave(wave, math.max(1, math.min(waveBars, size.width ~/ 4)));
    const gap = 2.0;
    final width = (size.width - gap * (bars.length - 1)) / bars.length;
    final paint = Paint();
    for (var bar = 0; bar < bars.length; bar++) {
      final left = bar * (width + gap);
      final centre = left + width / 2;
      var tall = height * (0.18 + 0.82 * bars[bar]);
      var alpha = 1.0;
      if (finger case final finger?) {
        // The magnifier: a few bars either side of the finger grow, the rest dim.
        final near = 1 - ((centre - finger).abs() / (5 * (width + gap))).clamp(0.0, 1.0);
        tall = math.min(height * 1.35, tall * (1 + 0.45 * near));
        alpha = 0.55 + 0.45 * near;
      }
      final played = centre <= size.width * fraction;
      paint.color = (played ? Colors.white : const Color(0x38FFFFFF)).withValues(alpha: (played ? 1 : 0.22) * alpha);
      canvas.drawRRect(
        RRect.fromLTRBR(left, mid - tall / 2, left + width, mid + tall / 2, const Radius.circular(2)),
        paint,
      );
    }
    // The playhead.
    final x = size.width * fraction;
    canvas.drawRect(Rect.fromLTWH(x - 1, mid - height / 2 - 3, 2, height + 6), paint..color = Colors.white);
  }

  void _ripple(Canvas canvas, Size size, double mid, double x) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round
      // Round joins: the default mitre left a thin spike glinting on each sharp crest.
      ..strokeJoin = StrokeJoin.round;
    canvas.drawLine(Offset(x, mid), Offset(size.width, mid), paint..color = _rest);
    final path = Path()..moveTo(0, mid);
    final amplitude = 5.5 * swell * (1 - grow);
    // The crests are born at the playhead and travel back along the played part, each as tall as
    // the music was when it formed. A crest starts and ends on the line, so their heights meet.
    for (var at = 0.0; at <= x; at += 1) {
      final cycle = (x - at) / 12 - ripple;
      final crest = crests?.at(cycle.floor() + 1) ?? 1;
      path.lineTo(at, mid + amplitude * crest * math.sin(cycle * 2 * math.pi));
    }
    canvas.drawPath(path, paint..color = Colors.white);
    final knob = RRect.fromLTRBR(x - 3, mid - 10, x + 3, mid + 10, const Radius.circular(3));
    canvas.drawRRect(knob, Paint()..color = Colors.white);
  }

  void _capsule(Canvas canvas, Size size, double mid, double x) {
    final thick = height + 12 * grow;
    final radius = Radius.circular(thick / 2);
    final paint = Paint();
    canvas.drawRRect(
      RRect.fromLTRBR(0, mid - thick / 2, size.width, mid + thick / 2, radius),
      paint..color = const Color(0x2EFFFFFF),
    );
    final fill = math.max(x, thick);
    canvas.drawRRect(RRect.fromLTRBR(0, mid - thick / 2, fill, mid + thick / 2, radius), paint..color = Colors.white);
    final text = TextPainter(
      text: TextSpan(
        text: label,
        style: TextStyle(
          fontSize: 10 + 2 * grow,
          fontWeight: FontWeight.w700,
          color: ink,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    // Inside the fill at its end, or just past it while the fill is too short.
    final inside = fill > text.width + 14;
    final left = inside ? fill - text.width - 7 : fill + 6;
    if (!inside) {
      text.text = TextSpan(
        text: label,
        style: text.text!.style!.copyWith(color: Colors.white),
      );
      text.layout();
    }
    text.paint(canvas, Offset(left, mid - text.height / 2));
  }

  void _tape(Canvas canvas, Size size, double mid) {
    final centre = size.width / 2;
    final run = tapeOffset(Duration(milliseconds: (fraction * seconds * 1000).round()), _tapePerSecond);
    canvas.saveLayer(Offset.zero & size, Paint());
    final paint = Paint();
    final first = math.max(0, ((run - centre) / _tapePerSecond).floor());
    final last = math.min(seconds.floor(), ((run + centre) / _tapePerSecond).ceil());
    for (var second = first; second <= last; second++) {
      final left = centre + second * _tapePerSecond - run;
      final major = second % 10 == 0;
      final tall = height * (major ? 0.62 : (second % 5 == 0 ? 0.42 : 0.24));
      paint.color = Colors.white.withValues(alpha: major ? 0.9 : 0.42);
      canvas.drawRect(Rect.fromLTWH(left - 0.75, mid - tall / 2, 1.5, tall), paint);
    }
    // Faded at both ends.
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..blendMode = BlendMode.dstIn
        ..shader = const LinearGradient(
          colors: [Color(0x00000000), Color(0xFF000000), Color(0xFF000000), Color(0x00000000)],
          stops: [0, 0.18, 0.82, 1],
        ).createShader(Offset.zero & size),
    );
    canvas.restore();
    final line = Rect.fromLTWH(centre - 1, mid - height / 2, 2, height);
    canvas.drawRect(
      line.inflate(2),
      Paint()
        ..color = needle.withValues(alpha: 0.5)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
    );
    canvas.drawRect(line, Paint()..color = needle);
  }

  @override
  bool shouldRepaint(SeekPainter old) =>
      old.fraction != fraction ||
      old.grow != grow ||
      old.finger != finger ||
      old.ripple != ripple ||
      old.swell != swell ||
      old.style != style ||
      old.label != label ||
      !listEquals(old.wave, wave);
}

/// Where the song is as a ring round [child], from the top, clockwise. A finger going round
/// anywhere over it seeks, whatever its distance to the centre, when it lifts.
class SeekRing extends StatefulWidget {
  const SeekRing({super.key, required this.player, required this.size, required this.child, this.stroke = 4});

  final PlayerViewModel player;
  final double size;
  final double stroke;
  final Widget child;

  @override
  State<SeekRing> createState() => _SeekRingState();
}

class _SeekRingState extends State<SeekRing> {
  double? _held;

  Offset get _centre => Offset(widget.size / 2, widget.size / 2);

  void _move(Offset at) {
    final to = fractionAtAngle(at - _centre);
    final from = _held;
    final next = from == null ? to : ringDrag(from, to);
    final total = widget.player.duration.inMilliseconds;
    if (from != null && (from * total) ~/ 60000 != (next * total) ~/ 60000) tick();
    setState(() => _held = next);
  }

  void _release() {
    final held = _held;
    if (held == null) return;
    widget.player.seek(Duration(milliseconds: (held * widget.player.duration.inMilliseconds).round()));
    setState(() => _held = null);
  }

  @override
  Widget build(BuildContext context) {
    final player = widget.player;
    final total = player.duration.inMilliseconds;
    final fraction = _held ?? (total == 0 ? 0.0 : (player.position.inMilliseconds / total).clamp(0.0, 1.0));
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      // Drags either way, so this wins the touch over the player's own drag down to close.
      onVerticalDragStart: (details) => _move(details.localPosition),
      onVerticalDragUpdate: (details) => _move(details.localPosition),
      onVerticalDragEnd: (_) => _release(),
      onVerticalDragCancel: () => setState(() => _held = null),
      onHorizontalDragStart: (details) => _move(details.localPosition),
      onHorizontalDragUpdate: (details) => _move(details.localPosition),
      onHorizontalDragEnd: (_) => _release(),
      onHorizontalDragCancel: () => setState(() => _held = null),
      child: SizedBox.square(
        dimension: widget.size,
        child: CustomPaint(
          foregroundPainter: _RingPainter(fraction: fraction, stroke: widget.stroke, held: _held != null),
          child: Center(child: widget.child),
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter({required this.fraction, required this.stroke, required this.held});

  final double fraction;
  final double stroke;
  final bool held;

  @override
  void paint(Canvas canvas, Size size) {
    final centre = size.center(Offset.zero);
    final radius = size.shortestSide / 2 - 9;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;
    canvas.drawCircle(centre, radius, paint..color = const Color(0x29FFFFFF));
    final rect = Rect.fromCircle(center: centre, radius: radius);
    canvas.drawArc(rect, -math.pi / 2, fraction * 2 * math.pi, false, paint..color = Colors.white);
    final angle = fraction * 2 * math.pi - math.pi / 2;
    final knob = centre + Offset(math.cos(angle), math.sin(angle)) * radius;
    final knobRadius = held ? 11.0 : 7.0;
    canvas.drawCircle(knob, knobRadius + 4, Paint()..color = const Color(0x33FFFFFF));
    canvas.drawCircle(knob, knobRadius, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(_RingPainter old) => old.fraction != fraction || old.held != held;
}

/// "Live", with a red dot, for a station that has no position to show.
class LiveBadge extends StatelessWidget {
  const LiveBadge({super.key});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: const BoxDecoration(color: Color(0xFFFF453A), shape: BoxShape.circle),
          ),
          const SizedBox(width: 8),
          Text(
            context.t('radio.live').toUpperCase(),
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.2,
              color: Color(0xCCFFFFFF),
            ),
          ),
        ],
      ),
    );
  }
}
