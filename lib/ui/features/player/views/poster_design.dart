import 'package:flutter/material.dart';

import '../../../../src/rust/api/player.dart' as core;
import '../../../core/app_prefs.dart';
import '../../../core/app_scope.dart';
import '../../../core/icons.dart';
import '../../../core/l10n.dart';
import '../../../core/motion.dart';
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

/// The poster: the cover across the top, drifting, under a huge title that sets itself letter by
/// letter for each song; the song's wave, a wide play key and chips along the bottom. Its lyrics
/// are set large and left under a band of the cover.
class PosterDesign extends StatelessWidget {
  const PosterDesign({
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
    final base = tint.shade(0.16, 0.035);
    final height = MediaQuery.sizeOf(context).height;
    return ColoredBox(
      color: base,
      child: Stack(
        children: [
          AnimatedPositioned(
            duration: const Duration(milliseconds: 420),
            curve: CauceCurves.exit,
            top: 0,
            left: 0,
            right: 0,
            height: lyrics ? 210 + MediaQuery.paddingOf(context).top : height * 0.52,
            child: Stack(
              fit: StackFit.expand,
              children: [
                TrackSwap(
                  id: (track.source, track.id),
                  style: SwapStyle.fade,
                  child: DriftingCover(url: track.coverLarge ?? track.cover, moving: player.playing),
                ),
                DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      stops: const [0, 0.45, 1],
                      colors: [base.withValues(alpha: 0.1), base.withValues(alpha: 0.2), base],
                    ),
                  ),
                ),
              ],
            ),
          ),
          SafeArea(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 280),
              child: lyrics ? _lyrics(context) : _player(context),
            ),
          ),
        ],
      ),
    );
  }

  Widget _player(BuildContext context) {
    final bar = seekStyleFor(PlayerDesign.poster, appPrefs.seekStyle);
    final album = track.album.isNotEmpty ? track.album : context.t('player.nowPlaying');
    return Padding(
      key: const ValueKey('player'),
      padding: const EdgeInsets.symmetric(horizontal: 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              GlassButton(
                glyph: CauceGlyph.chevronDown,
                label: MaterialLocalizations.of(context).closeButtonTooltip,
                onTap: () => Navigator.of(context).pop(),
              ),
              const Spacer(),
              GlassButton(
                glyph: CauceGlyph.more,
                label: context.t('player.options'),
                onTap: () => showTrackOptions(context, track, leave: Navigator.of(context).pop),
              ),
            ],
          ),
          const Spacer(),
          Text(
            album.toUpperCase(),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.4,
              color: Color(0xD1FFFFFF),
            ),
          ),
          const SizedBox(height: 6),
          LetterTitle(
            text: track.title,
            style: const TextStyle(
              fontFamily: displayFont,
              fontWeight: FontWeight.w700,
              height: 0.86,
              letterSpacing: -4,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: ArtistLink(
                  track: track,
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w500, color: Color(0xD9FFFFFF)),
                ),
              ),
              LookButton(
                look: ButtonLook.circle,
                size: 40,
                label: context.t('track.addToPlaylist'),
                onTap: () => showAddToPlaylist(context, track),
                child: const _Soft(child: CauceIcon(CauceGlyph.plus, size: 18)),
              ),
              const SizedBox(width: 12),
              LikeButton(track: track, size: 40),
            ],
          ),
          const SizedBox(height: 10),
          SeekBar(player: player, style: bar, tag: track.source == 'local' ? null : track.source),
          const SizedBox(height: 14),
          _Controls(player: player),
          const SizedBox(height: 10),
          const SystemVolume(),
          Row(
            children: [
              PlayerChip(glyph: CauceGlyph.lyrics, label: context.t('player.lyrics'), onTap: () => onLyrics(true)),
              const SizedBox(width: 6),
              const Flexible(child: RouteChip()),
              const SizedBox(width: 6),
              PlayerChip(
                glyph: CauceGlyph.queue,
                label: context.t('player.queue'),
                onTap: () => QueueSheet.open(context, player),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _lyrics(BuildContext context) {
    return Column(
      key: const ValueKey('lyrics'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: 210,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(22, 0, 12, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Align(
                  alignment: Alignment.topRight,
                  child: GlassButton(
                    glyph: CauceGlyph.chevronDown,
                    label: MaterialLocalizations.of(context).closeButtonTooltip,
                    onTap: () => onLyrics(false),
                  ),
                ),
                const Spacer(),
                Text(
                  '${context.t('player.lyrics')} · ${track.artists}'.toUpperCase(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.4,
                    color: Color(0xD1FFFFFF),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  track.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontFamily: displayFont,
                    fontSize: 28,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -1,
                  ),
                ),
              ],
            ),
          ),
        ),
        Expanded(
          child: LyricsPanel(lyrics: AppScope.of(context).lyrics, player: player, look: LyricsLook.poster),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 22),
          child: SeekBar(
            player: player,
            style: seekStyleFor(PlayerDesign.poster, appPrefs.seekStyle, lyrics: true),
            times: false,
            compact: true,
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(22, 6, 22, 10),
          child: Row(
            children: [
              Expanded(child: _PlayKey(player: player)),
              const SizedBox(width: 10),
              _Skip(player: player, forward: false),
              const SizedBox(width: 6),
              _Skip(player: player, forward: true),
              const SizedBox(width: 10),
              LikeButton(track: track, size: 52),
            ],
          ),
        ),
      ],
    );
  }
}

/// The poster's own controls, a wide play key between soft squares, unless the listener picked
/// other buttons.
class _Controls extends StatelessWidget {
  const _Controls({required this.player});

  final PlayerViewModel player;

  @override
  Widget build(BuildContext context) {
    if (appPrefs.buttonLook != ButtonLook.auto) {
      return FittedBox(
        fit: BoxFit.scaleDown,
        child: TransportRow(player: player, look: appPrefs.buttonLook, skip: 58, play: 76),
      );
    }
    return Row(
      children: [
        Expanded(child: _PlayKey(player: player)),
        const SizedBox(width: 10),
        _Skip(player: player, forward: false),
        const SizedBox(width: 6),
        _Skip(player: player, forward: true),
        RepeatButton(player: player),
      ],
    );
  }
}

/// Previous or next as a soft square.
class _Skip extends StatelessWidget {
  const _Skip({required this.player, required this.forward});

  final PlayerViewModel player;
  final bool forward;

  @override
  Widget build(BuildContext context) {
    return SkipButton(
      glyph: forward ? CauceGlyph.next : CauceGlyph.prev,
      onTap: forward ? player.next : player.previous,
      player: player,
      forward: forward,
      size: 24,
      box: 62,
      radius: 20,
    );
  }
}

/// Play or pause as a wide accent key that says which, the word shrinking rather than cut.
class _PlayKey extends StatelessWidget {
  const _PlayKey({required this.player});

  final PlayerViewModel player;

  @override
  Widget build(BuildContext context) {
    final ink = CauceColors.dark.onAccent;
    final label = context.t(player.playing ? 'player.pause' : 'player.play');
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      child: Pressable(
        scale: 0.96,
        onTap: player.togglePlay,
        child: Container(
          height: 64,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(color: CauceColors.dark.accent, borderRadius: BorderRadius.circular(20)),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              PlayPauseIcon(
                playing: player.playing,
                loading: player.loading,
                color: ink,
                size: 24,
                icon: (playing, size, color) =>
                    CauceIcon(playing ? CauceGlyph.pause : CauceGlyph.play, size: size, color: color),
              ),
              const SizedBox(width: 10),
              Flexible(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    label,
                    maxLines: 1,
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: ink),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A faint round fill, as the poster's side buttons have.
class _Soft extends StatelessWidget {
  const _Soft({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 40,
      height: 40,
      decoration: const BoxDecoration(color: Color(0x1FFFFFFF), shape: BoxShape.circle),
      alignment: Alignment.center,
      child: child,
    );
  }
}
