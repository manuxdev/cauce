import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../../src/rust/api/player.dart' as core;
import '../../../core/app_prefs.dart';
import '../../../core/app_scope.dart';
import '../../../core/icons.dart';
import '../../../core/l10n.dart';
import '../../../core/theme.dart';
import '../../../core/tint_scope.dart';
import '../../lyrics/views/lyrics_view.dart';
import '../../track/track_options.dart';
import '../player_design.dart';
import '../view_models/player_view_model.dart';
import 'design_motion.dart';
import 'player_parts.dart';
import 'queue_sheet.dart';
import 'seek_bars.dart';

/// The vinyl: the cover as a record's label, turning while it plays, with where the song is as a
/// ring round it; outline buttons under the names. Its lyrics keep a small turning record by the
/// title. A new song rolls in from the right as the old one rolls away, or from the left going back.
class VinylDesign extends StatelessWidget {
  const VinylDesign({
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
    final tint = TintScope.of(context).vivid;
    return PlayerBackdrop(
      top: tint.shade(0.3, 0.08),
      bottom: tint.shade(0.16, 0.05),
      glow: tint.shade(0.5, 0.14),
      moving: appPrefs.movingBackground && player.playing && !lyrics,
      child: SafeArea(
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 280),
          child: lyrics ? _lyrics(context) : _player(context),
        ),
      ),
    );
  }

  Widget _player(BuildContext context) {
    final look = buttonLookFor(PlayerDesign.vinyl, appPrefs.buttonLook);
    final bar = seekStyleFor(PlayerDesign.vinyl, appPrefs.seekStyle);
    final ring = bar == SeekStyle.ring;
    final accent = CauceColors.dark.accent;
    return Padding(
      key: const ValueKey('player'),
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        children: [
          PlayerHeader(track: track),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final side = math.min(330.0, math.min(constraints.maxWidth, constraints.maxHeight - 8));
                final disc = TrackSwap(
                  id: (track.source, track.id),
                  order: player.index ?? 0,
                  style: SwapStyle.roll,
                  child: VinylDisc(url: track.coverLarge ?? track.cover, size: side * 0.867, playing: player.playing),
                );
                return Center(
                  child: ring ? SeekRing(player: player, size: side, child: disc) : disc,
                );
              },
            ),
          ),
          if (ring)
            _Times(player: player)
          else
            SeekBar(player: player, style: bar, tag: track.source == 'local' ? null : track.source),
          const SizedBox(height: 14),
          Row(
            children: [
              _Outline(
                label: context.t('track.addToPlaylist'),
                onTap: () => showAddToPlaylist(context, track),
                child: const CauceIcon(CauceGlyph.plus, size: 20),
              ),
              Expanded(
                child: TrackSwap(
                  id: (track.source, track.id),
                  style: SwapStyle.fade,
                  child: Column(
                    children: [
                      Text(
                        track.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontFamily: displayFont, fontSize: 28, fontWeight: FontWeight.w700),
                      ),
                      ArtistLink(
                        track: track,
                        center: true,
                        style: const TextStyle(fontSize: 16, color: Color(0xC7FFFFFF)),
                      ),
                    ],
                  ),
                ),
              ),
              LikeButton(track: track, fill: Colors.transparent, border: accent.withValues(alpha: 0.7)),
            ],
          ),
          const SizedBox(height: 28),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: TransportRow(player: player, look: look),
          ),
          const SizedBox(height: 26),
          const SystemVolume(),
          const SizedBox(height: 18),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              PlayerChip(
                glyph: CauceGlyph.lyrics,
                label: context.t('player.lyrics'),
                onTap: () => onLyrics(true),
                fill: Colors.transparent,
                height: 44,
                glyphSize: 27,
                iconOnly: true,
              ),
              const SizedBox(width: 22),
              const Flexible(
                child: RouteChip(
                  fill: Color(0x14FFFFFF),
                  height: 40,
                  glyphSize: 19,
                  style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600),
                ),
              ),
              const SizedBox(width: 22),
              PlayerChip(
                glyph: CauceGlyph.queue,
                label: context.t('player.queue'),
                onTap: () => QueueSheet.open(context, player),
                fill: Colors.transparent,
                height: 44,
                glyphSize: 27,
                iconOnly: true,
              ),
            ],
          ),
          const SizedBox(height: 4),
        ],
      ),
    );
  }

  Widget _lyrics(BuildContext context) {
    final look = buttonLookFor(PlayerDesign.vinyl, appPrefs.buttonLook);
    return Column(
      key: const ValueKey('lyrics'),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 12, 0),
          child: Row(
            children: [
              VinylDisc(url: track.cover, size: 52, playing: player.playing),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      track.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                    ),
                    Text(
                      track.artists,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13, color: Color(0xB8FFFFFF)),
                    ),
                  ],
                ),
              ),
              IconButton(
                onPressed: () => onLyrics(false),
                tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
                icon: const CauceIcon(CauceGlyph.chevronDown, weight: 2.4),
              ),
            ],
          ),
        ),
        Expanded(
          child: LyricsPanel(lyrics: AppScope.of(context).lyrics, player: player, look: LyricsLook.vinyl),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28),
          child: SeekBar(
            player: player,
            style: seekStyleFor(PlayerDesign.vinyl, appPrefs.seekStyle, lyrics: true),
            compact: true,
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 10),
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: TransportRow(player: player, look: look, skip: 52, play: 66, gap: 22, repeat: false),
          ),
        ),
      ],
    );
  }
}

/// Where the song is and what is left, under the ring.
class _Times extends StatelessWidget {
  const _Times({required this.player});

  final PlayerViewModel player;

  @override
  Widget build(BuildContext context) {
    const style = TextStyle(fontSize: 13, color: Color(0xB8FFFFFF), fontFeatures: [FontFeature.tabularFigures()]);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(formatDuration(player.position), style: style),
          Text(
            '−${formatDuration(player.duration > player.position ? player.duration - player.position : Duration.zero)}',
            style: style,
          ),
        ],
      ),
    );
  }
}

/// A 44-point outline circle, as the vinyl's side buttons are.
class _Outline extends StatelessWidget {
  const _Outline({required this.label, required this.onTap, required this.child});

  final String label;
  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return LookButton(look: ButtonLook.outline, size: 44, label: label, onTap: onTap, child: child);
  }
}
