import 'dart:math' as math;
import 'dart:ui';

import '../../core/app_prefs.dart';

/// The bar [design] draws: the chosen one, or the design's own for [SeekStyle.auto]. The ring only
/// goes round the vinyl, so anywhere else, and over the lyrics, it is the line.
SeekStyle seekStyleFor(PlayerDesign design, SeekStyle chosen, {bool lyrics = false}) {
  final style = chosen != SeekStyle.auto
      ? chosen
      : switch (design) {
          PlayerDesign.classic => SeekStyle.line,
          PlayerDesign.vinyl => SeekStyle.ring,
          PlayerDesign.poster => SeekStyle.wave,
          PlayerDesign.tape => SeekStyle.tape,
          PlayerDesign.immersive => SeekStyle.ripple,
        };
  return style == SeekStyle.ring && (design != PlayerDesign.vinyl || lyrics) ? SeekStyle.line : style;
}

/// The buttons [design] draws: the chosen look, or the design's own for [ButtonLook.auto].
ButtonLook buttonLookFor(PlayerDesign design, ButtonLook chosen) => chosen != ButtonLook.auto
    ? chosen
    : switch (design) {
        PlayerDesign.classic || PlayerDesign.poster => ButtonLook.circle,
        PlayerDesign.vinyl => ButtonLook.outline,
        PlayerDesign.tape => ButtonLook.key,
        PlayerDesign.immersive => ButtonLook.plain,
      };

/// How far round a ring a point [fromCenter] is, from 0 at the top, clockwise, to 1.
double fractionAtAngle(Offset fromCenter) {
  final turn = math.atan2(fromCenter.dx, -fromCenter.dy) / (2 * math.pi);
  return turn < 0 ? turn + 1 : turn;
}

/// Where a finger going round the ring from [previous] to [next] leaves it: crossing the top stops
/// at the end it came from rather than jumping round.
double ringDrag(double previous, double next) {
  if ((next - previous).abs() <= 0.5) return next;
  return previous > 0.5 ? 1 : 0;
}

/// [fraction] on the nearest of [dots] steps.
double snapToDots(double fraction, int dots) => (fraction.clamp(0.0, 1.0) * dots).round() / dots;

/// How far the tape has run past the needle at [position], at [pixelsPerSecond].
double tapeOffset(Duration position, double pixelsPerSecond) => position.inMilliseconds / 1000 * pixelsPerSecond;

/// Where the song is once the tape under the needle is dragged [dx] from [from]: dragged left,
/// later music comes under it. To the second, and inside the song.
Duration tapeSeek(Duration from, double dx, double pixelsPerSecond, Duration length) {
  final seconds = (from.inMilliseconds / 1000 - dx / pixelsPerSecond).round();
  return Duration(seconds: seconds).clamp(Duration.zero, length);
}

extension on Duration {
  Duration clamp(Duration low, Duration high) => this < low ? low : (this > high ? high : this);
}

/// A wave of [bars] heights, the same every time for [id], drawn until the song's own is known.
List<double> placeholderWave(String id, int bars) {
  // FNV-1a over the id seeds a small generator, so each song keeps its shape.
  var seed = 0x811c9dc5;
  for (final unit in id.codeUnits) {
    seed = ((seed ^ unit) * 0x01000193) & 0xffffffff;
  }
  final random = math.Random(seed);
  return [for (var bar = 0; bar < bars; bar++) 0.2 + 0.8 * (0.5 + 0.5 * math.sin(bar * 0.45)) * random.nextDouble()];
}

/// A song's wave, built while it plays from the level heard at each point: [buckets] slots along
/// the song, each the average of what was heard there.
class WaveformBuilder {
  WaveformBuilder(this.buckets) : _sum = List.filled(buckets, 0), _count = List.filled(buckets, 0);

  final int buckets;
  final List<double> _sum;
  final List<int> _count;

  /// Adds [level], heard at [fraction] of the song.
  void add(double fraction, double level) {
    final slot = (fraction.clamp(0.0, 1.0) * buckets).floor().clamp(0, buckets - 1);
    _sum[slot] += level;
    _count[slot]++;
  }

  /// How much of the song has been heard, 0 to 1.
  double get filled => _count.where((count) => count > 0).length / buckets;

  /// Each slot's level, the loudest at 1; slots not heard are 0.
  List<double> get bars {
    final levels = [for (var slot = 0; slot < buckets; slot++) _count[slot] == 0 ? 0.0 : _sum[slot] / _count[slot]];
    final loudest = levels.fold(0.0, math.max);
    return loudest == 0 ? levels : [for (final level in levels) level / loudest];
  }
}

/// [wave] drawn as [bars] bars: neighbours averaged when there are fewer, repeated when more.
List<double> resampleWave(List<double> wave, int bars) {
  if (wave.isEmpty) return List.filled(bars, 0);
  return [
    for (var bar = 0; bar < bars; bar++)
      () {
        final start = bar * wave.length ~/ bars;
        final end = math.max(start + 1, (bar + 1) * wave.length ~/ bars);
        return wave.sublist(start, end).reduce((a, b) => a + b) / (end - start);
      }(),
  ];
}
