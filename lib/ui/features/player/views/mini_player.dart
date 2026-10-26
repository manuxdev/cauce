import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/app_prefs.dart';
import '../../../core/artwork.dart';
import '../../../core/icons.dart';
import '../../../core/motion.dart';
import '../../../core/theme.dart';
import '../../../core/tint_scope.dart';
import '../audio_levels.dart';
import '../player_design.dart';
import '../view_models/player_view_model.dart';
import 'now_playing_screen.dart';
import 'seek_bars.dart';

/// The top of the dock while something is queued: cover, names, play and next, and a progress
/// line that can be dragged through the track. A tap opens the full player.
class MiniPlayer extends StatelessWidget {
  const MiniPlayer({super.key, required this.player});

  final PlayerViewModel player;

  @override
  Widget build(BuildContext context) {
    final tint = TintScope.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([player, appPrefs]),
      builder: (context, _) {
        final track = player.track;
        if (track == null) return const SizedBox.shrink();
        final total = player.duration.inMilliseconds;
        final progress = total == 0 ? 0.0 : (player.position.inMilliseconds / total).clamp(0.0, 1.0);
        void open() {
          final box = context.findRenderObject() as RenderBox?;
          final from = box == null || !box.hasSize ? null : box.localToGlobal(Offset.zero) & box.size;
          NowPlayingScreen.open(context, player, from: from);
        }

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: open,
          onVerticalDragEnd: (details) {
            if ((details.primaryVelocity ?? 0) < -200) open();
          },
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                height: 64,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(10, 0, 8, 0),
                  child: Row(
                    children: [
                      Hero(
                        tag: 'artwork',
                        transitionOnUserGestures: true,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(12),
                            boxShadow: const [
                              BoxShadow(
                                color: Color(0x59000000),
                                blurRadius: 10,
                                offset: Offset(0, 4),
                                spreadRadius: -2,
                              ),
                            ],
                          ),
                          child: Artwork(url: track.cover, size: 44, radius: 12),
                        ),
                      ),
                      const SizedBox(width: 11),
                      Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              track.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontFamily: displayFont,
                                fontSize: 15,
                                height: 1.2,
                                fontWeight: FontWeight.w700,
                                letterSpacing: -0.15,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              track.artists,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 13, color: Color(0xB8FFFFFF)),
                            ),
                          ],
                        ),
                      ),
                      _PlayButton(player: player, ink: tint.ink),
                      SizedBox.square(
                        dimension: 44,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: player.next,
                          child: const Center(child: CauceIcon(CauceGlyph.next, size: 22)),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              _ScrubBar(player: player, progress: progress),
            ],
          ),
        );
      },
    );
  }
}

/// The white disc with play or pause, a spinner while the track loads.
class _PlayButton extends StatelessWidget {
  const _PlayButton({required this.player, required this.ink});

  final PlayerViewModel player;
  final Color ink;

  @override
  Widget build(BuildContext context) {
    return Pressable(
      scale: 0.9,
      onTap: player.togglePlay,
      child: Container(
        width: 44,
        height: 44,
        decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
        alignment: Alignment.center,
        child: PlayPauseIcon(
          playing: player.playing,
          loading: player.loading,
          color: ink,
          size: 20,
          icon: (playing, size, color) =>
              CauceIcon(playing ? CauceGlyph.pause : CauceGlyph.play, size: size, color: color),
        ),
      ),
    );
  }
}

/// The progress line under the mini player. Pressing it thickens it and shows a knob, and a drag
/// moves through the track; the seek goes out when the finger lifts, so the engine is asked once.
class _ScrubBar extends StatefulWidget {
  const _ScrubBar({required this.player, required this.progress});

  final PlayerViewModel player;
  final double progress;

  @override
  State<_ScrubBar> createState() => _ScrubBarState();
}

class _ScrubBarState extends State<_ScrubBar> {
  /// Where the finger holds the bar, from 0 to 1, while it is pressed.
  double? _held;

  static const _margin = 18.0;

  double _at(Offset local, double width) => width == 0 ? 0 : ((local.dx - _margin) / width).clamp(0.0, 1.0);

  /// Where the finger would take the track, drawn over the app since the dock clips its own.
  final _bubble = OverlayPortalController();

  void _hold(Offset local, double width) {
    _bubble.show();
    setState(() => _held = _at(local, width));
  }

  void _release() {
    final held = _held;
    if (held == null) return;
    _bubble.hide();
    setState(() => _held = null);
    final total = widget.player.duration.inMilliseconds;
    if (total > 0) widget.player.seek(Duration(milliseconds: (held * total).round()));
  }

  void _drop() {
    _bubble.hide();
    setState(() => _held = null);
  }

  Widget _time(BuildContext _) {
    // The bar's own place, not the overlay's.
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return const SizedBox.shrink();
    final at = box.localToGlobal(Offset.zero);
    final total = widget.player.duration;
    return Positioned(
      left: at.dx + _margin - 8,
      // Above the mini player, clear of the dock.
      top: at.dy - 64 - 46,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(color: const Color(0xF2000000), borderRadius: BorderRadius.circular(8)),
        child: Text(
          '${formatDuration(total * (_held ?? 0))} / ${formatDuration(total)}',
          style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: Colors.white,
            decoration: TextDecoration.none,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
        ),
      ),
    );
  }

  /// The full player's bar drawn small, when the listener asked for it; the ring and the tape
  /// have no line shape, so they keep the plain one.
  Widget? _styled(BuildContext context, double value) {
    if (!appPrefs.miniSeekStyle) return null;
    final style = seekStyleFor(appPrefs.playerDesign, appPrefs.seekStyle);
    if (style == SeekStyle.line || style == SeekStyle.ring || style == SeekStyle.tape) return null;
    if (style == SeekStyle.ripple) {
      return _MiniRipple(fraction: value, playing: widget.player.playing && _held == null);
    }
    final track = widget.player.track;
    final key = '${track?.source}:${track?.id}';
    return SizedBox(
      height: 12,
      child: ListenableBuilder(
        listenable: waveforms,
        builder: (context, _) => CustomPaint(
          painter: SeekPainter(
            style: style,
            fraction: value,
            wave: waveforms.of(key) ?? placeholderWave(key, waveBars),
            ripple: 0,
            swell: 1,
            height: style == SeekStyle.dots ? 6 : 10,
            label: '',
            ink: TintScope.of(context).vivid.ink,
            needle: CauceColors.dark.accent,
            seconds: widget.player.duration.inMilliseconds / 1000,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final held = _held != null;
    final value = _held ?? widget.progress;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth - _margin * 2;
        return OverlayPortal(
          controller: _bubble,
          overlayChildBuilder: _time,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (details) => _hold(details.localPosition, width),
            onTapUp: (_) => _release(),
            onTapCancel: _drop,
            onHorizontalDragStart: (details) => _hold(details.localPosition, width),
            onHorizontalDragUpdate: (details) => _hold(details.localPosition, width),
            onHorizontalDragEnd: (_) => _release(),
            onHorizontalDragCancel: _drop,
            // Taller than it looks, so a thumb finds it.
            child: SizedBox(
              height: 14,
              child: Stack(
                clipBehavior: Clip.none,
                alignment: Alignment.centerLeft,
                children: [
                  Positioned(
                    left: _margin,
                    right: _margin,
                    child:
                        _styled(context, value) ??
                        AnimatedContainer(
                          duration: const Duration(milliseconds: 150),
                          curve: Curves.easeOut,
                          height: held ? 6 : 3,
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.2),
                            borderRadius: BorderRadius.circular(3),
                          ),
                          alignment: Alignment.centerLeft,
                          child: FractionallySizedBox(
                            widthFactor: value,
                            heightFactor: 1,
                            child: DecoratedBox(
                              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(3)),
                            ),
                          ),
                        ),
                  ),
                  if (held)
                    Positioned(
                      left: _margin + width * value - 7,
                      child: Container(
                        width: 14,
                        height: 14,
                        decoration: const BoxDecoration(
                          color: Colors.white,
                          shape: BoxShape.circle,
                          boxShadow: [BoxShadow(color: Color(0x73000000), blurRadius: 5, offset: Offset(0, 1))],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// The ripple drawn for the mini player's thin line: a fine wave over the part played that runs
/// while it plays and swells with the music and its beat, without the full bar's knob.
class _MiniRipple extends StatefulWidget {
  const _MiniRipple({required this.fraction, required this.playing});

  final double fraction;
  final bool playing;

  @override
  State<_MiniRipple> createState() => _MiniRippleState();
}

class _MiniRippleState extends State<_MiniRipple> with SingleTickerProviderStateMixin {
  late final _run = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100));
  final _crests = RippleCrests();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _follow();
  }

  @override
  void didUpdateWidget(_MiniRipple old) {
    super.didUpdateWidget(old);
    _follow();
  }

  void _follow() {
    final on = widget.playing && !MediaQuery.disableAnimationsOf(context);
    if (on && !_run.isAnimating) _run.repeat();
    if (!on) _run.stop();
  }

  @override
  void dispose() {
    _run.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reactive = appPrefs.reactive;
    final ripple = SizedBox(
      // The whole touch strip, so the taller crests have room.
      height: 14,
      child: AnimatedBuilder(
        animation: Listenable.merge([_run, if (reactive) audioLevels]),
        builder: (context, _) => CustomPaint(
          painter: _MiniRipplePainter(
            fraction: widget.fraction,
            phase: _run.value,
            crests: _crests
              ..tick(
                _run.value,
                rippleSwell(reactive ? audioLevels.value : null, beat: reactive ? audioLevels.beat : 0),
              ),
            // Under half the full bar's swing, so the wave stays inside the line's strip.
            amplitude: widget.playing ? 2.6 * appPrefs.intensity.scale : 0,
          ),
        ),
      ),
    );
    return reactive ? LevelsHold(child: ripple) : ripple;
  }
}

class _MiniRipplePainter extends CustomPainter {
  _MiniRipplePainter({required this.fraction, required this.phase, required this.crests, required this.amplitude});

  final double fraction;
  final double phase;
  final RippleCrests crests;
  final double amplitude;

  @override
  void paint(Canvas canvas, Size size) {
    final mid = size.height / 2;
    final x = size.width * fraction;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      // Round joins: the default mitre left a thin spike glinting on each sharp crest.
      ..strokeJoin = StrokeJoin.round;
    canvas.drawLine(Offset(x, mid), Offset(size.width, mid), paint..color = Colors.white.withValues(alpha: 0.2));
    final path = Path()..moveTo(0, mid);
    // As on the full bar: born at the playhead, each crest as tall as the music when it formed,
    // and never past the strip.
    for (var at = 0.0; at <= x; at += 1) {
      final cycle = (x - at) / 10 - phase;
      final swing = math.min(amplitude * crests.at(cycle.floor() + 1), mid - 1);
      path.lineTo(at, mid + swing * math.sin(cycle * 2 * math.pi));
    }
    canvas.drawPath(path, paint..color = Colors.white);
    // Where the song is, as the full bar marks it.
    canvas.drawRRect(
      RRect.fromLTRBR(x - 1.5, 0, x + 1.5, size.height, const Radius.circular(1.5)),
      Paint()..color = Colors.white,
    );
  }

  @override
  bool shouldRepaint(_MiniRipplePainter old) =>
      old.fraction != fraction || old.phase != phase || old.amplitude != amplitude;
}
