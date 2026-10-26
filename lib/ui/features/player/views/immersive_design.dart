import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../../../../src/rust/api/player.dart' as core;
import '../../../core/app_prefs.dart';
import '../../../core/app_scope.dart';
import '../../../core/icons.dart';
import '../../../core/l10n.dart';
import '../../../core/theme.dart';
import '../../../core/tint.dart';
import '../../../core/tint_scope.dart';
import '../../lyrics/views/lyrics_view.dart';
import '../../track/track_options.dart';
import '../player_design.dart';
import '../view_models/player_view_model.dart';
import 'design_motion.dart';
import 'player_parts.dart';
import 'queue_sheet.dart';
import 'seek_bars.dart';

/// The immersive player: the cover fills the screen, drifting, and everything else sits in a
/// glass capsule at the bottom that darkens over a bright cover so its text keeps 4.5:1. Its
/// lyrics are centred over the cover blurred.
class ImmersiveDesign extends StatelessWidget {
  const ImmersiveDesign({
    super.key,
    required this.player,
    required this.track,
    required this.lyrics,
    required this.onLyrics,
  });

  final PlayerViewModel player;
  final core.TrackItem track;
  final bool lyrics;
  final ValueChanged<bool> onLyrics;

  @override
  Widget build(BuildContext context) {
    final url = track.cover;
    return Stack(
      fit: StackFit.expand,
      children: [
        TrackSwap(
          id: (track.source, track.id),
          style: SwapStyle.fade,
          child: DriftingCover(url: url, moving: player.playing && !lyrics),
        ),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 360),
          child: lyrics
              ? BackdropFilter(
                  key: const ValueKey('blur'),
                  filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
                  child: const ColoredBox(color: Color(0x73120402)),
                )
              : const DecoratedBox(
                  key: ValueKey('shade'),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      stops: [0, 0.22, 0.55, 1],
                      colors: [Color(0x66000000), Color(0x00000000), Color(0x00000000), Color(0x8C000000)],
                    ),
                  ),
                ),
        ),
        SafeArea(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 280),
            child: lyrics ? _lyrics(context) : _player(context),
          ),
        ),
      ],
    );
  }

  Widget _top(BuildContext context, {required bool lyrics}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          GlassButton(
            glyph: CauceGlyph.chevronDown,
            label: MaterialLocalizations.of(context).closeButtonTooltip,
            onTap: lyrics ? () => onLyrics(false) : () => Navigator.of(context).pop(),
          ),
          Expanded(
            child: lyrics
                ? Column(
                    children: [
                      Text(
                        track.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                      ),
                      Text(
                        track.artists,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13, color: Color(0xD9FFFFFF)),
                      ),
                    ],
                  )
                : const SizedBox.shrink(),
          ),
          GlassButton(
            glyph: CauceGlyph.more,
            label: context.t('player.options'),
            onTap: () => showTrackOptions(context, track, leave: Navigator.of(context).pop),
          ),
        ],
      ),
    );
  }

  Widget _player(BuildContext context) {
    final look = buttonLookFor(PlayerDesign.immersive, appPrefs.buttonLook);
    return Column(
      key: const ValueKey('player'),
      children: [
        _top(context, lyrics: false),
        const Spacer(),
        _Glass(
          url: track.cover,
          radius: 38,
          padding: const EdgeInsets.fromLTRB(22, 24, 22, 14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          track.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontFamily: displayFont, fontSize: 26, fontWeight: FontWeight.w700),
                        ),
                        ArtistLink(
                          track: track,
                          style: const TextStyle(fontSize: 16, color: Color(0xD9FFFFFF)),
                        ),
                      ],
                    ),
                  ),
                  LikeButton(track: track, fill: const Color(0x29FFFFFF)),
                ],
              ),
              const SizedBox(height: 10),
              SeekBar(
                player: player,
                style: seekStyleFor(PlayerDesign.immersive, appPrefs.seekStyle),
                tag: track.source == 'local' ? null : track.source,
              ),
              const SizedBox(height: 6),
              FittedBox(
                fit: BoxFit.scaleDown,
                child: TransportRow(player: player, look: look, skip: 52, play: 80, gap: 18),
              ),
              const SizedBox(height: 4),
              const SystemVolume(),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  PlayerChip(
                    glyph: CauceGlyph.lyrics,
                    label: context.t('player.lyrics'),
                    onTap: () => onLyrics(true),
                    fill: Colors.transparent,
                    iconOnly: true,
                  ),
                  const RouteChip(fill: Colors.transparent, iconOnly: true),
                  PlayerChip(
                    glyph: CauceGlyph.queue,
                    label: context.t('player.queue'),
                    onTap: () => QueueSheet.open(context, player),
                    fill: Colors.transparent,
                    iconOnly: true,
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
      ],
    );
  }

  Widget _lyrics(BuildContext context) {
    final look = buttonLookFor(PlayerDesign.immersive, appPrefs.buttonLook);
    return Column(
      key: const ValueKey('lyrics'),
      children: [
        _top(context, lyrics: true),
        Expanded(
          child: LyricsPanel(lyrics: AppScope.of(context).lyrics, player: player, look: LyricsLook.immersive),
        ),
        _Glass(
          url: track.cover,
          radius: 32,
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SeekBar(
                player: player,
                style: seekStyleFor(PlayerDesign.immersive, appPrefs.seekStyle, lyrics: true),
                compact: true,
              ),
              FittedBox(
                fit: BoxFit.scaleDown,
                child: TransportRow(player: player, look: look, skip: 44, play: 68, gap: 36, repeat: false),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
      ],
    );
  }
}

/// The frosted capsule: the cover blurred behind a dark fill, as opaque as the cover under it
/// needs for white text to read at 4.5:1, with a highlight that sweeps across it slowly, on a soft
/// shadow.
class _Glass extends StatelessWidget {
  const _Glass({required this.url, required this.radius, required this.padding, required this.child});

  final String? url;
  final double radius;
  final EdgeInsets padding;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final shape = BorderRadius.circular(radius);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: shape,
          boxShadow: const [
            // The dock's shadow, so the capsule floats the way the mini player does.
            BoxShadow(color: Color(0x99190005), blurRadius: 44, offset: Offset(0, 20), spreadRadius: -14),
          ],
        ),
        // The sweep spans the whole capsule under the clip: inside the padding its edges showed as
        // a hard pale box. It sits over the blur in a layer of its own, not inside it: there it
        // made the blur redraw every frame, and the glass flickered.
        child: ClipRRect(
          borderRadius: shape,
          child: Stack(
            children: [
              BackdropFilter(
                filter: ImageFilter.compose(
                  outer: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
                  inner: const ColorFilter.matrix(_saturate),
                ),
                child: FutureBuilder(
                  future: coverBottomLuminance(url),
                  builder: (context, brightness) => AnimatedContainer(
                    duration: const Duration(milliseconds: 400),
                    padding: padding,
                    decoration: BoxDecoration(
                      color: const Color(0xFF280A06).withValues(alpha: glassAlpha(brightness.data ?? 1)),
                      borderRadius: shape,
                      border: Border.all(color: const Color(0x47FFFFFF), width: 0.5),
                    ),
                    child: child,
                  ),
                ),
              ),
              Positioned.fill(
                child: RepaintBoundary(child: _Sweep(tint: TintScope.of(context).vivid.shade(0.9, 0.02))),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A saturation of 1.6, as the glass deepens the cover's colour behind it.
const _saturate = <double>[
  1.4723, -0.4287, -0.0436, 0, 0, //
  -0.1277, 1.1713, -0.0436, 0, 0, //
  -0.1277, -0.4287, 1.5564, 0, 0, //
  0, 0, 0, 1, 0,
];

/// How much of the 7 s cycle the band takes to cross.
const _passShare = 5 / 11;

/// A narrow band of light crossing the glass every 11 s while the background moves.
class _Sweep extends StatefulWidget {
  const _Sweep({required this.tint});

  final Color tint;

  @override
  State<_Sweep> createState() => _SweepState();
}

class _SweepState extends State<_Sweep> with SingleTickerProviderStateMixin {
  late final _run = AnimationController(vsync: this, duration: const Duration(seconds: 11));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final on = appPrefs.movingBackground && moves(context);
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
    if (!_run.isAnimating) return const SizedBox.shrink();
    final strength = 0.06 * appPrefs.intensity.scale;
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: _run,
        builder: (context, _) {
          // A narrow band crosses in the first 5 s of the 11, then the glass rests: a glint, not
          // a change of tone.
          final pass = (_run.value / _passShare).clamp(0.0, 1.0);
          if (pass >= 1) return const SizedBox.shrink();
          final at = -1.8 + 3.6 * Curves.easeInOut.transform(pass);
          // It fades in as it sets off and out as it leaves, so it never pops on or off.
          final glow = strength * Curves.easeInOut.transform(1 - (2 * pass - 1).abs());
          return DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment(at - 0.7, -1),
                end: Alignment(at + 0.7, 1),
                stops: const [0.26, 0.5, 0.74],
                colors: [
                  widget.tint.withValues(alpha: 0),
                  widget.tint.withValues(alpha: glow),
                  widget.tint.withValues(alpha: 0),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
