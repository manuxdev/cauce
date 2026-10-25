import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:cauce/ui/core/app_prefs.dart';
import 'package:cauce/ui/features/player/player_design.dart';

void main() {
  test('auto takes each design\'s own bar, and the ring only goes round the vinyl', () {
    expect(seekStyleFor(PlayerDesign.classic, SeekStyle.auto), SeekStyle.line);
    expect(seekStyleFor(PlayerDesign.vinyl, SeekStyle.auto), SeekStyle.ring);
    expect(seekStyleFor(PlayerDesign.vinyl, SeekStyle.auto, lyrics: true), SeekStyle.line);
    expect(seekStyleFor(PlayerDesign.poster, SeekStyle.auto), SeekStyle.wave);
    expect(seekStyleFor(PlayerDesign.tape, SeekStyle.auto), SeekStyle.tape);
    expect(seekStyleFor(PlayerDesign.immersive, SeekStyle.auto), SeekStyle.ripple);
    expect(seekStyleFor(PlayerDesign.poster, SeekStyle.dots), SeekStyle.dots);
    expect(seekStyleFor(PlayerDesign.classic, SeekStyle.ring), SeekStyle.line);
    expect(seekStyleFor(PlayerDesign.vinyl, SeekStyle.ring, lyrics: true), SeekStyle.line);
    expect(seekStyleFor(PlayerDesign.vinyl, SeekStyle.ring), SeekStyle.ring);
  });

  test('auto takes each design\'s own buttons', () {
    expect(buttonLookFor(PlayerDesign.classic, ButtonLook.auto), ButtonLook.circle);
    expect(buttonLookFor(PlayerDesign.vinyl, ButtonLook.auto), ButtonLook.outline);
    expect(buttonLookFor(PlayerDesign.tape, ButtonLook.auto), ButtonLook.key);
    expect(buttonLookFor(PlayerDesign.immersive, ButtonLook.auto), ButtonLook.plain);
    expect(buttonLookFor(PlayerDesign.immersive, ButtonLook.outline), ButtonLook.outline);
  });

  test('the ring starts at the top and runs clockwise, whatever the distance to the centre', () {
    expect(fractionAtAngle(const Offset(0, -10)), closeTo(0, 1e-9));
    expect(fractionAtAngle(const Offset(50, 0)), closeTo(0.25, 1e-9));
    expect(fractionAtAngle(const Offset(0, 3)), closeTo(0.5, 1e-9));
    expect(fractionAtAngle(const Offset(-1, 0)), closeTo(0.75, 1e-9));
    expect(fractionAtAngle(Offset(math.sin(0.2), -math.cos(0.2)) * 80), closeTo(0.2 / (2 * math.pi), 1e-9));
  });

  test('dragging the ring past the top stops at the end it came from', () {
    expect(ringDrag(0.4, 0.45), 0.45);
    expect(ringDrag(0.97, 0.02), 1);
    expect(ringDrag(0.03, 0.98), 0);
  });

  test('dots snap to the nearest of thirty', () {
    expect(snapToDots(0, 30), 0);
    expect(snapToDots(1, 30), 1);
    expect(snapToDots(0.51, 30), closeTo(15 / 30, 1e-9));
    expect(snapToDots(0.52, 30), closeTo(16 / 30, 1e-9));
    expect(snapToDots(1.4, 30), 1);
  });

  test('the tape moves under the needle, to the second, and stays inside the song', () {
    const length = Duration(minutes: 3);
    const at = Duration(seconds: 60);
    // Dragged left, the tape brings later music under the needle.
    expect(tapeSeek(at, -30, 10, length), const Duration(seconds: 63));
    expect(tapeSeek(at, 34, 10, length), const Duration(seconds: 57));
    expect(tapeSeek(at, 2000, 10, length), Duration.zero);
    expect(tapeSeek(at, -9000, 10, length), length);
    expect(tapeOffset(const Duration(milliseconds: 1500), 10), 15);
  });

  test('the intensity scales how far things move', () {
    expect(MotionIntensity.soft.scale, lessThan(MotionIntensity.normal.scale));
    expect(MotionIntensity.normal.scale, 1);
    expect(MotionIntensity.vivid.scale, greaterThan(1));
  });

  test('a song with no wave yet gets the same made-up one every time, and each song its own', () {
    final wave = placeholderWave('deezer:42', 52);
    expect(wave, hasLength(52));
    expect(wave, placeholderWave('deezer:42', 52));
    expect(wave, isNot(placeholderWave('deezer:43', 52)));
    expect(wave.every((bar) => bar > 0 && bar <= 1), isTrue);
  });

  test('the wave is built from the levels heard at each point of the song', () {
    final builder = WaveformBuilder(4);
    expect(builder.filled, 0);
    builder
      ..add(0.1, 0.2)
      ..add(0.2, 0.4)
      ..add(0.6, 0.8)
      ..add(1.0, 0.4);
    expect(builder.filled, 0.75);
    expect(builder.bars, [closeTo(0.375, 1e-9), 0, 1, 0.5]);
    builder.add(0.3, 0.1);
    expect(builder.filled, 1);
  });

  test('a wave is drawn with as many bars as fit', () {
    expect(resampleWave([0.2, 0.4, 0.6, 0.8], 2), [closeTo(0.3, 1e-9), closeTo(0.7, 1e-9)]);
    expect(resampleWave([0.5, 1], 4), [0.5, 0.5, 1, 1]);
    expect(resampleWave(const [], 3), [0, 0, 0]);
  });
}
