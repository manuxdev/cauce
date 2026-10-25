import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../../src/rust/api/player.dart' as core;
import '../../../core/app_prefs.dart';
import '../../../core/app_scope.dart';
import '../../../core/artwork.dart';
import '../../../core/icons.dart';
import '../../../core/l10n.dart';
import '../../../core/motion.dart';
import '../../../core/theme.dart';
import '../../../core/tint_scope.dart';
import '../../../core/widgets.dart';
import '../../lyrics/views/lyrics_view.dart';
import '../audio_levels.dart';
import '../now_playing_center.dart';
import '../player_design.dart';
import '../view_models/player_view_model.dart';
import 'design_motion.dart';
import 'player_parts.dart';
import 'queue_sheet.dart';
import 'seek_bars.dart';

const _label = TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, letterSpacing: 1.3, color: Color(0x80FFFFFF));
const _tabular = [FontFeature.tabularFigures()];

/// The tape deck: a panel with the cover, a big counter, a pilot light and VU meters that follow
/// the sound; the tape under a needle to seek; keys that press in, with hold on previous or next
/// to wind; and a volume in 20 steps. Its lyrics are a prompter, each line with its time.
class TapeDesign extends StatelessWidget {
  const TapeDesign({
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
    // The scaffold's body is loose and the deck only as tall as its keys, so the colour is
    // stretched to the whole screen rather than ending under them.
    return SizedBox.expand(
      child: ColoredBox(
        color: TintScope.of(context).vivid.shade(0.14, 0.012),
        child: SafeArea(
          child: LevelsHold(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 280),
              child: lyrics ? _lyrics(context) : _player(context),
            ),
          ),
        ),
      ),
    );
  }

  Widget _player(BuildContext context) {
    final bar = seekStyleFor(PlayerDesign.tape, appPrefs.seekStyle);
    // Spread over the height, not centred as one block; a phone shorter than the deck needs
    // shrinks it as one rather than cutting off the keys.
    // ponytail: the floor is the deck's measured natural height, raise it if the deck grows.
    const floor = 600.0;
    return LayoutBuilder(
      key: const ValueKey('player'),
      builder: (context, constraints) => FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.topCenter,
        child: SizedBox(
          width: constraints.maxWidth,
          height: math.max(constraints.maxHeight, floor),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18),
            child: Column(
              children: [
                PlayerHeader(track: track, label: context.t('player.nowPlaying').toUpperCase(), album: false),
                const SizedBox(height: 4),
                _Deck(player: player, track: track),
                const SizedBox(height: 10),
                const Spacer(),
                SeekBar(player: player, style: bar, times: bar != SeekStyle.tape),
                const SizedBox(height: 10),
                const Spacer(),
                _Keys(player: player),
                const SizedBox(height: 10),
                const Spacer(),
                const _Volume(),
                const SizedBox(height: 8),
                const Spacer(),
                Row(
                  children: [
                    Expanded(
                      flex: 10,
                      child: _Key(
                        height: 52,
                        radius: 14,
                        label: context.t('player.lyrics').toUpperCase(),
                        onTap: () => onLyrics(true),
                        child: const CauceIcon(CauceGlyph.lyrics, size: 20),
                      ),
                    ),
                    const SizedBox(width: 10),
                    const Expanded(flex: 16, child: _RouteKey()),
                    const SizedBox(width: 10),
                    Expanded(
                      flex: 10,
                      child: _Key(
                        height: 52,
                        radius: 14,
                        label: context.t('player.queue').toUpperCase(),
                        onTap: () => QueueSheet.open(context, player),
                        child: const CauceIcon(CauceGlyph.queue, size: 20),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  context.t('tape.hint').toUpperCase(),
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 9.5,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.2,
                    color: Color(0x52FFFFFF),
                  ),
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _lyrics(BuildContext context) {
    final tint = TintScope.of(context).vivid;
    return Padding(
      key: const ValueKey('lyrics'),
      padding: const EdgeInsets.symmetric(horizontal: 18),
      child: Column(
        children: [
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
            decoration: BoxDecoration(color: tint.shade(0.2, 0.035), borderRadius: BorderRadius.circular(18)),
            child: Row(
              children: [
                Artwork(url: track.cover, size: 36, radius: 6),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        track.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
                      ),
                      Text(
                        track.artists,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12, color: Color(0xBFFFFFFF)),
                      ),
                    ],
                  ),
                ),
                Text(
                  formatDuration(player.position),
                  style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w600, fontFeatures: _tabular),
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
            child: LyricsPanel(lyrics: AppScope.of(context).lyrics, player: player, look: LyricsLook.prompter),
          ),
          SeekBar(
            player: player,
            style: seekStyleFor(PlayerDesign.tape, appPrefs.seekStyle, lyrics: true),
            times: false,
            compact: true,
          ),
          const SizedBox(height: 10),
          _Keys(player: player, compact: true),
          const SizedBox(height: 10),
        ],
      ),
    );
  }
}

/// The bitrate in a stream's encoding, as "256K", for a tag with no room for the codec.
String? compactBitrate(String? quality) {
  final kbps = RegExp(r'(\d+)\s*kbps').firstMatch(quality ?? '')?.group(1);
  return kbps == null ? null : '${kbps}K';
}

/// The deck's panel: the cover and names, the counter with the pilot light and what is left,
/// and the VU meters.
class _Deck extends StatelessWidget {
  const _Deck({required this.player, required this.track});

  final PlayerViewModel player;
  final core.TrackItem track;

  @override
  Widget build(BuildContext context) {
    final tint = TintScope.of(context).vivid;
    final index = player.index;
    final count = player.queue.length;
    final quality = player.quality;
    final source = [brandOf(track.source).letters, ?compactBitrate(quality)].join(' · ');
    final left = player.duration > player.position ? player.duration - player.position : Duration.zero;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 22, 16, 20),
      decoration: BoxDecoration(
        color: tint.shade(0.2, 0.035),
        borderRadius: BorderRadius.circular(26),
        border: Border.all(color: const Color(0x14FFFFFF)),
        boxShadow: [BoxShadow(color: tint.shade(0.08, 0.01), blurRadius: 0, offset: const Offset(0, 4))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TrackSwap(
                id: (track.source, track.id),
                style: SwapStyle.fade,
                child: Artwork(url: track.cover, size: 96, radius: 10),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        if (index != null && count > 0)
                          Text(
                            context.t('tape.track', {
                              'number': '${index + 1}'.padLeft(2, '0'),
                              'count': '$count'.padLeft(2, '0'),
                            }).toUpperCase(),
                            style: _label,
                          ),
                        const Spacer(),
                        Text(source, maxLines: 1, style: _label),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      track.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
                    ),
                    ArtistLink(
                      track: track,
                      style: const TextStyle(fontSize: 14, color: Color(0xBFFFFFFF)),
                    ),
                    if (track.album.isNotEmpty)
                      Text(
                        track.album,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13, color: Color(0x80FFFFFF)),
                      ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.bottomLeft,
                  child: Text(
                    formatDuration(player.position),
                    style: const TextStyle(
                      fontSize: 74,
                      height: 1,
                      fontWeight: FontWeight.w600,
                      fontFeatures: _tabular,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    _Pilot(player: player, id: (track.source, track.id)),
                    const SizedBox(height: 4),
                    Text(
                      '−${formatDuration(left)}',
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: Color(0x99FFFFFF),
                        fontFeatures: _tabular,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          const _Meters(),
        ],
      ),
    );
  }
}

/// "● PLAY" in the accent while playing, its light slowly blinking, or "PAUSE"; a new song blinks
/// it twice.
class _Pilot extends StatefulWidget {
  const _Pilot({required this.player, required this.id});

  final PlayerViewModel player;
  final Object id;

  @override
  State<_Pilot> createState() => _PilotState();
}

class _PilotState extends State<_Pilot> with SingleTickerProviderStateMixin {
  late final _blink = AnimationController(vsync: this, duration: const Duration(milliseconds: 1200));
  bool _twice = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _follow();
  }

  @override
  void didUpdateWidget(_Pilot old) {
    super.didUpdateWidget(old);
    if (old.id != widget.id && moves(context)) {
      _twice = true;
      _blink.duration = const Duration(milliseconds: 300);
      _blink.repeat(count: 4, reverse: true).whenComplete(() {
        if (!mounted) return;
        _twice = false;
        _blink.duration = const Duration(milliseconds: 1200);
        _follow();
      });
      return;
    }
    _follow();
  }

  void _follow() {
    if (_twice) return;
    if (widget.player.playing && moves(context)) {
      if (!_blink.isAnimating) _blink.repeat(reverse: true);
    } else {
      _blink.stop();
      _blink.value = 0;
    }
  }

  @override
  void dispose() {
    _blink.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final playing = widget.player.playing;
    final color = playing ? CauceColors.dark.accent : const Color(0x99FFFFFF);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        AnimatedBuilder(
          animation: _blink,
          builder: (context, _) => Opacity(
            opacity: 1 - 0.75 * _blink.value,
            child: Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
          ),
        ),
        const SizedBox(width: 6),
        Text(
          context.t(playing ? 'tape.play' : 'tape.pause').toUpperCase(),
          style: _label.copyWith(color: color, letterSpacing: 1.4),
        ),
      ],
    );
  }
}

/// The left and right VU meters, segments lighting up with the sound, the loudest in the accent,
/// over their scale. Dark when the listener turned off following the audio.
class _Meters extends StatelessWidget {
  const _Meters();

  static const _segments = 24;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: audioLevels,
      builder: (context, _) => Column(
        children: [
          _row('L', audioLevels.left),
          const SizedBox(height: 5),
          _row('R', audioLevels.right),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.only(left: 16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                for (final mark in ['−40', '−20', '−10', '−5', '0', '+3'])
                  Text(
                    mark,
                    style: const TextStyle(fontSize: 9, fontWeight: FontWeight.w600, color: Color(0x59FFFFFF)),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _row(String side, double level) {
    // The spectrum's average sits low; the meter reads it on a curve so music fills most of it.
    final lit = (math.sqrt(level.clamp(0.0, 1.0)) * 1.25 * _segments).round();
    final accent = CauceColors.dark.accent;
    return Row(
      children: [
        SizedBox(width: 16, child: Text(side, style: _label)),
        for (var segment = 0; segment < _segments; segment++) ...[
          if (segment > 0) const SizedBox(width: 3),
          Expanded(
            child: Container(
              height: 8,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(1.5),
                color: segment < lit
                    ? (segment >= _segments - 4 ? accent : const Color(0xE0FFFFFF))
                    : const Color(0x1AFFFFFF),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// A key face: raised on its shadow, it goes down 3 points onto it when held, with an accent
/// ring and a pilot light.
class _KeyFace extends StatelessWidget {
  const _KeyFace({required this.down, required this.child, this.label, this.height = 72, this.radius = 16});

  final bool down;
  final Widget child;
  final String? label;
  final double height;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final tint = TintScope.of(context).vivid;
    final accent = CauceColors.dark.accent;
    const quick = Duration(milliseconds: 90);
    return AnimatedContainer(
      duration: quick,
      height: height - 5,
      transform: Matrix4.translationValues(0, down ? 3 : 0, 0),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [tint.shade(0.31, 0.02), tint.shade(0.24, 0.018)],
        ),
        border: Border.all(color: down ? accent.withValues(alpha: 0.75) : const Color(0x0FFFFFFF), width: 1.5),
        boxShadow: [BoxShadow(color: tint.shade(0.1, 0.01), offset: Offset(0, down ? 2 : 5))],
      ),
      child: Stack(
        children: [
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                child,
                if (label case final label?) ...[
                  const SizedBox(height: 5),
                  Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 9.5,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.3,
                      color: Color(0xA6FFFFFF),
                    ),
                  ),
                ],
              ],
            ),
          ),
          Positioned(
            top: 7,
            right: 8,
            child: AnimatedOpacity(
              opacity: down ? 1 : 0,
              duration: quick,
              child: Container(
                width: 5,
                height: 5,
                decoration: BoxDecoration(
                  color: accent,
                  shape: BoxShape.circle,
                  boxShadow: [BoxShadow(color: accent, blurRadius: 6)],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A key that presses in while held and acts on a tap.
class _Key extends StatefulWidget {
  const _Key({
    required this.onTap,
    required this.child,
    this.label,
    this.height = 72,
    this.radius = 16,
    this.on,
    this.lit = false,
  });

  final VoidCallback onTap;
  final Widget child;
  final String? label;
  final double height;
  final double radius;

  /// Latched down, as repeat is while on.
  final bool? on;

  /// Held down without being a switch, as play is while the song plays.
  final bool lit;

  @override
  State<_Key> createState() => _KeyState();
}

class _KeyState extends State<_Key> {
  bool _down = false;

  void _set(bool down) {
    if (down != _down) setState(() => _down = down);
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: widget.label,
      toggled: widget.on,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          tick();
          widget.onTap();
        },
        onTapDown: (_) => _set(true),
        onTapUp: (_) => _set(false),
        onTapCancel: () => _set(false),
        child: _KeyFace(
          down: _down || (widget.on ?? false) || widget.lit,
          label: widget.label,
          height: widget.height,
          radius: widget.radius,
          child: widget.child,
        ),
      ),
    );
  }
}

/// Previous, play or pause, next and repeat as keys, or the transport in the buttons picked.
class _Keys extends StatelessWidget {
  const _Keys({required this.player, this.compact = false});

  final PlayerViewModel player;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    if (appPrefs.buttonLook != ButtonLook.auto) {
      return FittedBox(
        fit: BoxFit.scaleDown,
        child: TransportRow(player: player, look: appPrefs.buttonLook, skip: 58, play: 76, repeat: !compact),
      );
    }
    final height = compact ? 60.0 : 72.0;
    Widget skip(bool forward) => SkipButton(
      glyph: forward ? CauceGlyph.next : CauceGlyph.prev,
      onTap: forward ? player.next : player.previous,
      player: player,
      forward: forward,
      size: 22,
      box: height,
      face: (down, glyph) => _KeyFace(
        down: down,
        height: height,
        label: compact ? null : context.t(forward ? 'tape.next' : 'tape.previous').toUpperCase(),
        child: glyph,
      ),
    );
    final playing = player.playing;
    final keys = [
      skip(false),
      _Key(
        height: height,
        label: compact ? null : context.t(playing ? 'tape.pause' : 'tape.play').toUpperCase(),
        onTap: player.togglePlay,
        lit: playing,
        child: PlayPauseIcon(
          playing: playing,
          loading: player.loading,
          color: playing ? CauceColors.dark.accent : Colors.white,
          size: 24,
          icon: (playing, size, color) =>
              CauceIcon(playing ? CauceGlyph.pause : CauceGlyph.play, size: size, color: color),
        ),
      ),
      skip(true),
      if (!compact)
        _Key(
          height: height,
          label: context.t('tape.repeat').toUpperCase(),
          on: player.repeat != core.RepeatMode.off,
          onTap: player.cycleRepeat,
          child: CauceIcon(
            CauceGlyph.repeat,
            size: 22,
            color: player.repeat != core.RepeatMode.off ? CauceColors.dark.accent : Colors.white,
          ),
        ),
    ];
    return Row(
      children: [
        for (final (index, key) in keys.indexed) ...[if (index > 0) const SizedBox(width: 10), Expanded(child: key)],
      ],
    );
  }
}

/// The phone's volume in 20 steps, each a bar a little taller than the last; a tap or a drag
/// across them sets it.
class _Volume extends StatelessWidget {
  const _Volume();

  static const _steps = 20;

  void _set(double x, double width) {
    final step = ((x / width) * _steps).ceil().clamp(0, _steps);
    if (step == ((outputVolume.value ?? 0) * _steps).round()) return;
    tick();
    outputVolume.value = step / _steps;
    NowPlayingCenter.setVolume(step / _steps);
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder(
      valueListenable: outputVolume,
      builder: (context, volume, _) {
        final lit = ((volume ?? 0) * _steps).round();
        return Semantics(
          slider: true,
          label: context.t('tape.volume'),
          value: '$lit',
          increasedValue: '${math.min(_steps, lit + 1)}',
          decreasedValue: '${math.max(0, lit - 1)}',
          onIncrease: () => NowPlayingCenter.setVolume(math.min(_steps, lit + 1) / _steps),
          onDecrease: () => NowPlayingCenter.setVolume(math.max(0, lit - 1) / _steps),
          child: Row(
            children: [
              const SizedBox(width: 34, child: Text('VOL', style: _label)),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) => GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapDown: (details) => _set(details.localPosition.dx, constraints.maxWidth),
                    onHorizontalDragUpdate: (details) => _set(details.localPosition.dx, constraints.maxWidth),
                    child: SizedBox(
                      height: 44,
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          for (var step = 0; step < _steps; step++) ...[
                            if (step > 0) const SizedBox(width: 3),
                            Expanded(
                              child: Container(
                                height: 5 + 9 * step / (_steps - 1),
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(1.5),
                                  color: step < lit ? const Color(0xD9FFFFFF) : const Color(0x24FFFFFF),
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              SizedBox(
                width: 30,
                child: Text(
                  '$lit',
                  textAlign: TextAlign.end,
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, fontFeatures: _tabular),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// The output as a wide key naming it, in the accent; the system's list opens from anywhere on it.
class _RouteKey extends StatelessWidget {
  const _RouteKey();

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder(
      valueListenable: audioOutput,
      builder: (context, output, _) => Stack(
        children: [
          IgnorePointer(
            child: _KeyFace(
              down: false,
              height: 52,
              radius: 14,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CauceIcon(CauceGlyph.headphones, size: 16, color: CauceColors.dark.accent),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      output ?? context.t('player.output'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: CauceColors.dark.accent),
                    ),
                  ),
                ],
              ),
            ),
          ),
          Positioned.fill(
            child: UiKitView(viewType: 'cauce/route_picker_clear', gestureRecognizers: nativeTouches),
          ),
        ],
      ),
    );
  }
}
