import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../../../src/rust/api/player.dart' as core;
import '../../../core/app_prefs.dart';
import '../../../core/app_scope.dart';
import '../../../core/dropdown.dart';
import '../../../core/icons.dart';
import '../../../core/l10n.dart';
import '../../../core/motion.dart';
import '../../../core/theme.dart';
import '../../../core/tint_scope.dart';
import '../../../core/widgets.dart';
import '../../accounts/view_models/accounts_view_model.dart';
import '../../library/view_models/favorites_view_model.dart';
import '../../track/track_options.dart';
import '../now_playing_center.dart';
import '../view_models/player_view_model.dart';

/// The like button: a liked heart grows to 125 % and throws six dots out around it; an unliked
/// one shrinks a little and comes back, without the dots.
class HeartButton extends StatefulWidget {
  const HeartButton({
    super.key,
    required this.saved,
    required this.onTap,
    this.size = 44,
    this.fill = const Color(0x1FFFFFFF),
    this.border,
  });

  final bool saved;
  final VoidCallback onTap;
  final double size;
  final Color fill;

  /// A ring round it, as the vinyl's outline buttons have.
  final Color? border;

  @override
  State<HeartButton> createState() => _HeartButtonState();
}

class _HeartButtonState extends State<HeartButton> with SingleTickerProviderStateMixin {
  late final _burst = AnimationController(vsync: this, duration: const Duration(milliseconds: 520));

  @override
  void didUpdateWidget(HeartButton old) {
    super.didUpdateWidget(old);
    if (widget.saved == old.saved || MediaQuery.disableAnimationsOf(context)) return;
    if (widget.saved) thud();
    _burst.forward(from: 0);
  }

  @override
  void dispose() {
    _burst.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Pressable(
      scale: 0.9,
      onTap: widget.onTap,
      child: Container(
        width: widget.size,
        height: widget.size,
        decoration: BoxDecoration(
          color: widget.fill,
          shape: BoxShape.circle,
          border: widget.border == null ? null : Border.all(color: widget.border!, width: 1.5),
        ),
        child: AnimatedBuilder(
          animation: _burst,
          builder: (context, _) {
            final t = _burst.value;
            // Up to 125 % in the first third, then back.
            final grow = t < 0.35 ? Curves.easeOut.transform(t / 0.35) : 1 - Curves.easeIn.transform((t - 0.35) / 0.65);
            final spread = Curves.easeOutCubic.transform(t);
            return Stack(
              clipBehavior: Clip.none,
              alignment: Alignment.center,
              children: [
                if (_burst.isAnimating && widget.saved)
                  for (var dot = 0; dot < 6; dot++)
                    Transform.translate(
                      offset: Offset.fromDirection(dot * math.pi / 3 - math.pi / 2, 14 + 16 * spread),
                      child: Opacity(
                        opacity: 1 - t,
                        child: Container(
                          width: 5,
                          height: 5,
                          decoration: BoxDecoration(color: CauceColors.dark.accent, shape: BoxShape.circle),
                        ),
                      ),
                    ),
                Transform.scale(
                  scale: widget.saved ? 1 + 0.25 * grow : 1 - 0.2 * grow,
                  child: CauceIcon(
                    widget.saved ? CauceGlyph.heartFilled : CauceGlyph.heart,
                    size: 22,
                    color: widget.saved ? CauceColors.dark.accent : CauceColors.dark.foreground,
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// The provider playing, as a dot of its colour, and how its stream is encoded.
class SourceTag extends StatelessWidget {
  const SourceTag({super.key, required this.slug, required this.player});

  final String slug;
  final PlayerViewModel player;

  /// The levels this provider serves, under the tag, to change the one for the network in use.
  Future<void> _pick(BuildContext context) async {
    final playback = AppScope.of(context).playbackSettings;
    final settings = playback.settings;
    if (settings == null) return;
    final offers = await core.qualities(slug: slug).catchError((Object _) => <core.QualityOption>[]);
    if (offers.isEmpty || !context.mounted) return;
    final stored = player.cellular ? settings.qualityCellular : settings.quality;
    // The stored level as this service plays it: the best offered at or below it.
    const order = ['low', 'normal', 'high', 'lossless', 'hi-res'];
    final playing =
        offers.where((offer) => order.indexOf(offer.id) <= order.indexOf(stored)).firstOrNull?.id ??
        offers.lastOrNull?.id;
    final picked = await showDropdown<String>(
      context,
      items: [
        for (final offer in offers)
          DropdownItem(
            value: offer.id,
            title: context.t('quality.${offer.id}'),
            subtitle: offer.upTo ? context.t('quality.upTo', {'encoding': offer.encoding}) : offer.encoding,
            selected: offer.id == playing,
          ),
      ],
    );
    if (picked == null || picked == playing) return;
    tick();
    if (player.cellular) {
      playback.update(qualityCellular: picked);
    } else {
      playback.update(quality: picked);
    }
  }

  @override
  Widget build(BuildContext context) {
    final brand = brandOf(slug);
    final name = streamingServices
        .firstWhere((service) => service.slug == slug, orElse: () => StreamingService(slug, slug))
        .name;
    final quality = player.quality;
    if (slug == 'local') return _tag(brand.color, quality ?? name);
    return Builder(
      // Its own context, so the levels open under the tag.
      builder: (context) =>
          Pressable(scale: 0.92, onTap: () => _pick(context), child: _tag(brand.color, quality ?? name, more: true)),
    );
  }

  Widget _tag(Color dot, String label, {bool more = false}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(6)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: const TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              color: Color(0xB3FFFFFF),
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

class SystemVolume extends StatelessWidget {
  const SystemVolume({super.key});

  @override
  Widget build(BuildContext context) {
    // The system's own slider: it is the phone's volume, so it follows the volume buttons.
    return Row(
      children: [
        const CauceIcon(CauceGlyph.volumeLow, size: 18, color: Color(0x99FFFFFF)),
        const SizedBox(width: 10),
        Expanded(
          child: SizedBox(
            height: 34,
            child: UiKitView(viewType: 'cauce/volume', gestureRecognizers: nativeTouches),
          ),
        ),
        const SizedBox(width: 10),
        const CauceIcon(CauceGlyph.volumeHigh, size: 18, color: Color(0x99FFFFFF)),
      ],
    );
  }
}

/// Native controls take their touches before the swipe-to-close drag can.
final nativeTouches = {Factory<OneSequenceGestureRecognizer>(EagerGestureRecognizer.new)};

/// Previous or next on a tap. Held, it runs through the track at twice the speed after 400 ms
/// and four times after 2 s, backwards for previous, with the speed shown over it. Each change
/// of speed ticks.
class SkipButton extends StatefulWidget {
  const SkipButton({
    super.key,
    required this.glyph,
    required this.onTap,
    required this.player,
    required this.forward,
    required this.size,
    this.look = ButtonLook.circle,
    this.box = 56,
    this.radius,
    this.face,
  });

  final CauceGlyph glyph;
  final ButtonLook look;

  /// The side of the square it takes, its face 4 points inside.
  final double box;

  /// Its face's corner, for a square face; see [ButtonFace.radius].
  final double? radius;

  /// Draws the face in place of a [ButtonFace], as wide as it is given and [box] high, from
  /// whether it is held and the glyph.
  final Widget Function(bool down, Widget glyph)? face;
  final VoidCallback onTap;
  final PlayerViewModel player;
  final bool forward;
  final double size;

  @override
  State<SkipButton> createState() => _SkipButtonState();
}

class _SkipButtonState extends State<SkipButton> {
  /// How often the run asks the engine to move; it lags behind faster seeks.
  static const _every = Duration(milliseconds: 450);

  bool _down = false;

  /// 0 for a plain press, else how many times faster the run goes.
  int _speed = 0;
  Timer? _wait;
  Timer? _faster;
  Timer? _tick;

  /// Where the run has got to, and when it was last moved.
  Duration _at = Duration.zero;
  final _clock = Stopwatch();

  void _press() {
    setState(() => _down = true);
    _wait = Timer(const Duration(milliseconds: 400), () {
      _at = widget.player.position;
      _clock
        ..reset()
        ..start();
      _speedUp(2);
      _tick = Timer.periodic(_every, (_) => _run());
      _faster = Timer(const Duration(milliseconds: 1600), () => _speedUp(4));
    });
  }

  void _speedUp(int speed) {
    tick();
    setState(() => _speed = speed);
  }

  void _run() {
    final elapsed = _clock.elapsed;
    _clock
      ..reset()
      ..start();
    // The track plays on meanwhile: next adds what makes it `speed` times as fast, previous
    // takes that back and goes as fast the other way.
    final step = elapsed * (widget.forward ? _speed - 1 : -(_speed + 1));
    final end = widget.player.duration;
    final to = _at + elapsed + step;
    _at = to < Duration.zero ? Duration.zero : (to > end ? end : to);
    widget.player.seek(_at);
  }

  void _release({required bool tapped}) {
    final ran = _speed > 0;
    _stop();
    if (tapped && !ran) widget.onTap();
  }

  void _stop() {
    for (final timer in [_wait, _faster, _tick]) {
      timer?.cancel();
    }
    _wait = _faster = _tick = null;
    _clock.stop();
    if (mounted) {
      setState(() {
        _down = false;
        _speed = 0;
      });
    }
  }

  @override
  void dispose() {
    for (final timer in [_wait, _faster, _tick]) {
      timer?.cancel();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final label = widget.forward ? '×$_speed ▸▸' : '◂◂ ×$_speed';
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => _press(),
      onTapUp: (_) => _release(tapped: true),
      onTapCancel: () => _release(tapped: false),
      child: SizedBox(
        width: widget.face == null ? widget.box : null,
        height: widget.box,
        child: Stack(
          clipBehavior: Clip.none,
          alignment: Alignment.center,
          children: [
            widget.face?.call(_down, CauceIcon(widget.glyph, size: widget.size)) ??
                ButtonFace(
                  look: widget.look,
                  size: widget.box - 4,
                  down: _down,
                  radius: widget.radius,
                  child: CauceIcon(widget.glyph, size: widget.size),
                ),
            Positioned(
              top: -26,
              child: AnimatedOpacity(
                opacity: _speed > 0 ? 1 : 0,
                duration: const Duration(milliseconds: 120),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10)),
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                      color: TintScope.of(context).vivid.ink,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A transport button's face in [look], as big as [size]: [primary] is play, which the circle
/// fills white. Pressed, a key goes down 3 points onto its shadow with an accent ring; the others
/// shrink a little.
class ButtonFace extends StatelessWidget {
  const ButtonFace({
    super.key,
    required this.look,
    required this.size,
    required this.down,
    required this.child,
    this.primary = false,
    this.radius,
  });

  final ButtonLook look;
  final double size;
  final bool down;
  final bool primary;
  final Widget child;

  /// The corner of a key, a third of its side unless set; set on a circle, a soft square.
  final double? radius;

  @override
  Widget build(BuildContext context) {
    final tint = TintScope.of(context).vivid;
    const quick = Duration(milliseconds: 120);
    final decoration = switch (look) {
      ButtonLook.circle || ButtonLook.auto when primary => const BoxDecoration(
        color: Colors.white,
        shape: BoxShape.circle,
        boxShadow: [BoxShadow(color: Color(0x40000000), blurRadius: 24, offset: Offset(0, 8))],
      ),
      // With a corner, the poster's soft squares.
      ButtonLook.circle || ButtonLook.auto when radius != null => BoxDecoration(
        color: Colors.white.withValues(alpha: down ? 0.2 : 0.12),
        borderRadius: BorderRadius.circular(radius!),
      ),
      ButtonLook.circle || ButtonLook.auto => BoxDecoration(
        color: Colors.white.withValues(alpha: down ? 0.14 : 0),
        shape: BoxShape.circle,
      ),
      ButtonLook.outline => BoxDecoration(
        color: Colors.white.withValues(alpha: down ? 0.12 : 0),
        shape: BoxShape.circle,
        border: Border.all(
          color: Colors.white.withValues(alpha: primary ? 1 : 0.38),
          width: primary ? 2 : 1.5,
        ),
      ),
      ButtonLook.key => BoxDecoration(
        borderRadius: BorderRadius.circular(radius ?? size / 3.5),
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [tint.shade(0.31, 0.02), tint.shade(0.24, 0.018)],
        ),
        border: down ? Border.all(color: CauceColors.dark.accent.withValues(alpha: 0.7), width: 1.5) : null,
        boxShadow: [BoxShadow(color: tint.shade(0.1, 0.01), offset: Offset(0, down ? 2 : 5))],
      ),
      ButtonLook.plain => const BoxDecoration(),
    };
    final face = AnimatedContainer(
      duration: quick,
      width: size,
      height: size,
      decoration: decoration,
      alignment: Alignment.center,
      child: child,
    );
    if (look == ButtonLook.key) {
      return AnimatedSlide(offset: Offset(0, down ? 3 / size : 0), duration: quick, child: face);
    }
    return AnimatedScale(
      scale: down ? 0.9 : 1,
      duration: down ? quick : CauceCurves.vivid.duration,
      curve: down ? Curves.easeOut : CauceCurves.vivid,
      child: face,
    );
  }
}

/// A button drawn in [look] that knows when it is held down, for its face to press.
class LookButton extends StatefulWidget {
  const LookButton({
    super.key,
    required this.look,
    required this.size,
    required this.onTap,
    required this.child,
    this.primary = false,
    this.label,
  });

  final ButtonLook look;
  final double size;
  final VoidCallback onTap;
  final Widget child;
  final bool primary;

  /// What a screen reader says.
  final String? label;

  @override
  State<LookButton> createState() => _LookButtonState();
}

class _LookButtonState extends State<LookButton> {
  bool _down = false;

  void _set(bool down) {
    if (down != _down) setState(() => _down = down);
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: widget.label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        onTapDown: (_) => _set(true),
        onTapUp: (_) => _set(false),
        onTapCancel: () => _set(false),
        child: SizedBox.square(
          dimension: math.max(44, widget.size),
          child: Center(
            child: ButtonFace(
              look: widget.look,
              size: widget.size,
              down: _down,
              primary: widget.primary,
              child: widget.child,
            ),
          ),
        ),
      ),
    );
  }
}

/// Play or pause in [look], [size] across.
class PlayButton extends StatelessWidget {
  const PlayButton({super.key, required this.player, required this.look, required this.size, this.iconSize});

  final PlayerViewModel player;
  final ButtonLook look;
  final double size;
  final double? iconSize;

  @override
  Widget build(BuildContext context) {
    final filled = look == ButtonLook.circle || look == ButtonLook.auto;
    return LookButton(
      look: look,
      size: size,
      primary: true,
      label: context.t(player.playing ? 'player.pause' : 'player.play'),
      onTap: player.togglePlay,
      child: PlayPauseIcon(
        playing: player.playing,
        loading: player.loading,
        color: filled ? TintScope.of(context).vivid.ink : Colors.white,
        size: iconSize ?? size * 0.44,
        icon: (playing, size, color) =>
            CauceIcon(playing ? CauceGlyph.pause : CauceGlyph.play, size: size, color: color),
      ),
    );
  }
}

/// Repeat, cycling off, all and one, in the accent with a dot under it while on.
class RepeatButton extends StatelessWidget {
  const RepeatButton({super.key, required this.player, this.size = 22});

  final PlayerViewModel player;
  final double size;

  @override
  Widget build(BuildContext context) {
    final repeat = player.repeat;
    final on = repeat != core.RepeatMode.off;
    final color = on ? CauceColors.dark.accent : Colors.white.withValues(alpha: 0.72);
    return Semantics(
      button: true,
      toggled: on,
      label: context.t(repeat == core.RepeatMode.one ? 'queue.repeatOne' : 'queue.repeat'),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          tick();
          player.cycleRepeat();
        },
        child: SizedBox.square(
          dimension: 44,
          child: Stack(
            alignment: Alignment.center,
            children: [
              CauceIcon(CauceGlyph.repeat, size: size, color: color),
              if (repeat == core.RepeatMode.one)
                Text(
                  '1',
                  style: TextStyle(fontSize: size * 0.4, fontWeight: FontWeight.w800, color: color),
                ),
              Positioned(
                bottom: 4,
                child: AnimatedOpacity(
                  opacity: on ? 1 : 0,
                  duration: const Duration(milliseconds: 160),
                  child: Container(
                    width: 4,
                    height: 4,
                    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
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

/// Likes [track], or nothing for a local file, which has no account to save it in.
class LikeButton extends StatelessWidget {
  const LikeButton({super.key, required this.track, this.size = 44, this.fill = const Color(0x1FFFFFFF), this.border});

  final core.TrackItem track;
  final double size;
  final Color fill;
  final Color? border;

  @override
  Widget build(BuildContext context) {
    if (track.source == 'local') return SizedBox.square(dimension: size);
    final FavoritesViewModel favorites = AppScope.of(context).favorites;
    return ListenableBuilder(
      listenable: favorites,
      builder: (context, _) => HeartButton(
        saved: favorites.saved(track),
        onTap: () => favorites.toggle(track),
        size: size,
        fill: fill,
        border: border,
      ),
    );
  }
}

/// The artists, which open their menu, with a chevron after them.
class ArtistLink extends StatelessWidget {
  const ArtistLink({super.key, required this.track, required this.style, this.center = false});

  final core.TrackItem track;
  final TextStyle style;
  final bool center;

  @override
  Widget build(BuildContext context) {
    return Builder(
      // Its own context, so the menu opens under the name.
      builder: (context) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => showArtistMenu(context, track, leave: Navigator.of(context).pop),
        child: Row(
          mainAxisSize: center ? MainAxisSize.min : MainAxisSize.max,
          children: [
            Flexible(
              child: Text(track.artists, maxLines: 1, overflow: TextOverflow.ellipsis, style: style),
            ),
            const SizedBox(width: 4),
            CauceIcon(CauceGlyph.chevronRight, size: (style.fontSize ?? 16) * 0.85, color: style.color, weight: 2.2),
          ],
        ),
      ),
    );
  }
}

/// Closes the player, says where it plays from, and opens the track's options. [glass] draws
/// both buttons as frosted circles, for over a cover.
class PlayerHeader extends StatelessWidget {
  const PlayerHeader({super.key, required this.track, this.label, this.glass = false, this.album = true});

  final core.TrackItem track;

  /// Over the album, in place of "From the album" or "Now playing".
  final String? label;
  final bool glass;

  /// Whether the album is named under the label.
  final bool album;

  Widget _button(CauceGlyph glyph, double size, VoidCallback onTap, String tooltip) {
    if (glass) return GlassButton(glyph: glyph, onTap: onTap, label: tooltip, iconSize: size * 0.85);
    return IconButton(
      onPressed: onTap,
      tooltip: tooltip,
      icon: CauceIcon(glyph, size: size, weight: 2.4),
    );
  }

  @override
  Widget build(BuildContext context) {
    final named = album && track.album.isNotEmpty;
    return Row(
      children: [
        Transform.translate(
          offset: Offset(glass ? 0 : -10, 0),
          child: _button(
            CauceGlyph.chevronDown,
            26,
            () => Navigator.of(context).pop(),
            MaterialLocalizations.of(context).closeButtonTooltip,
          ),
        ),
        Expanded(
          child: Column(
            children: [
              Text(
                label ?? context.t(track.album.isNotEmpty ? 'player.fromAlbum' : 'player.nowPlaying').toUpperCase(),
                style: const TextStyle(
                  fontSize: 11,
                  letterSpacing: 1.2,
                  fontWeight: FontWeight.w600,
                  color: Color(0x99FFFFFF),
                ),
              ),
              if (named)
                Text(
                  track.album,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                ),
            ],
          ),
        ),
        Transform.translate(
          offset: Offset(glass ? 0 : 10, 0),
          child: _button(
            CauceGlyph.more,
            22,
            () => showTrackOptions(context, track, leave: Navigator.of(context).pop),
            context.t('player.options'),
          ),
        ),
      ],
    );
  }
}

/// A rounded chip along the bottom of a design: lyrics, the output, or the queue.
class PlayerChip extends StatelessWidget {
  const PlayerChip({
    super.key,
    required this.glyph,
    required this.label,
    required this.onTap,
    this.accent = false,
    this.height = 36,
    this.radius,
    this.fill = const Color(0x1AFFFFFF),
    this.style,
    this.iconOnly = false,
    this.glyphSize,
  });

  final CauceGlyph glyph;

  /// Overrides the glyph's size, 23 alone or 16 beside the label.
  final double? glyphSize;
  final String label;

  /// Draws the glyph alone, larger, with [label] left for VoiceOver.
  final bool iconOnly;
  final VoidCallback? onTap;
  final bool accent;
  final double height;
  final double? radius;
  final Color fill;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final color = accent ? CauceColors.dark.accent : Colors.white;
    return Semantics(
      button: true,
      label: label,
      child: Pressable(
        scale: 0.95,
        onTap: onTap,
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: math.max(44, height)),
          // Only as wide as the chip: an Align left to fill would spread a Flexible chip's row.
          child: Align(
            widthFactor: 1,
            child: Container(
              height: height,
              padding: EdgeInsets.symmetric(horizontal: iconOnly ? 10 : 14),
              decoration: BoxDecoration(color: fill, borderRadius: BorderRadius.circular(radius ?? height / 2)),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  CauceIcon(glyph, size: glyphSize ?? (iconOnly ? 23 : 16), color: color),
                  if (!iconOnly) ...[
                    const SizedBox(width: 7),
                    Flexible(
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: (style ?? const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)).copyWith(
                          color: color,
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
    );
  }
}

/// The output as a chip naming it, in the accent; a tap anywhere on it opens the system's list
/// of outputs, through an invisible picker laid over it.
class RouteChip extends StatelessWidget {
  const RouteChip({
    super.key,
    this.height = 36,
    this.radius,
    this.fill = const Color(0x1AFFFFFF),
    this.style,
    this.iconOnly = false,
    this.glyphSize,
  });

  /// As [PlayerChip.iconOnly] and [PlayerChip.glyphSize].
  final bool iconOnly;
  final double? glyphSize;
  final double height;
  final double? radius;
  final Color fill;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder(
      valueListenable: audioOutput,
      builder: (context, output, _) => Stack(
        children: [
          IgnorePointer(
            child: PlayerChip(
              glyph: CauceGlyph.headphones,
              label: output ?? context.t('player.output'),
              onTap: null,
              accent: true,
              height: height,
              radius: radius,
              fill: fill,
              style: style,
              iconOnly: iconOnly,
              glyphSize: glyphSize,
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

/// A frosted round button, for over a cover, in a 44-point touch area.
class GlassButton extends StatelessWidget {
  const GlassButton({
    super.key,
    required this.glyph,
    required this.onTap,
    required this.label,
    this.size = 40,
    this.iconSize = 20,
    this.tint = const Color(0x47140604),
    this.child,
  });

  final CauceGlyph glyph;
  final VoidCallback onTap;
  final String label;
  final double size;
  final double iconSize;
  final Color tint;

  /// Drawn in place of the glyph.
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      child: Pressable(
        scale: 0.92,
        onTap: onTap,
        child: SizedBox.square(
          dimension: math.max(44, size),
          child: Center(
            child: ClipOval(
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                child: Container(
                  width: size,
                  height: size,
                  color: tint,
                  alignment: Alignment.center,
                  child: child ?? CauceIcon(glyph, size: iconSize, weight: 2.4),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Repeat, previous, play and next in [look], with a space as wide as repeat after them so play
/// stays in the middle.
class TransportRow extends StatelessWidget {
  const TransportRow({
    super.key,
    required this.player,
    required this.look,
    this.skip = 62,
    this.play = 86,
    this.gap = 14,
    this.repeat = true,
  });

  final PlayerViewModel player;
  final ButtonLook look;

  /// The sides of previous and next, and of play.
  final double skip;
  final double play;
  final double gap;
  final bool repeat;

  @override
  Widget build(BuildContext context) {
    final glyph = skip * 0.42;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (repeat) ...[RepeatButton(player: player), SizedBox(width: gap)],
        SkipButton(
          glyph: CauceGlyph.prev,
          onTap: player.previous,
          player: player,
          forward: false,
          size: glyph,
          look: look,
          box: math.max(48, skip + 4),
        ),
        SizedBox(width: gap),
        PlayButton(player: player, look: look, size: play),
        SizedBox(width: gap),
        SkipButton(
          glyph: CauceGlyph.next,
          onTap: player.next,
          player: player,
          forward: true,
          size: glyph,
          look: look,
          box: math.max(48, skip + 4),
        ),
        if (repeat) ...[SizedBox(width: gap), const SizedBox(width: 44)],
      ],
    );
  }
}

/// The player's gradient, with a soft glow of the cover's colour that drifts slowly round the page
/// while the music plays, unless motion is reduced.
class PlayerBackdrop extends StatefulWidget {
  const PlayerBackdrop({
    super.key,
    required this.top,
    required this.bottom,
    required this.glow,
    required this.moving,
    required this.child,
  });

  final Color top;
  final Color bottom;
  final Color glow;
  final bool moving;
  final Widget child;

  @override
  State<PlayerBackdrop> createState() => _PlayerBackdropState();
}

class _PlayerBackdropState extends State<PlayerBackdrop> with SingleTickerProviderStateMixin {
  late final _drift = AnimationController(vsync: this, duration: const Duration(seconds: 24));

  bool get _moving => widget.moving && !MediaQuery.disableAnimationsOf(context);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _follow();
  }

  @override
  void didUpdateWidget(PlayerBackdrop old) {
    super.didUpdateWidget(old);
    _follow();
  }

  void _follow() {
    if (_moving && !_drift.isAnimating) {
      _drift.repeat();
    } else if (!_moving && _drift.isAnimating) {
      _drift.stop();
    }
  }

  @override
  void dispose() {
    _drift.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final on = appPrefs.movingBackground && !MediaQuery.disableAnimationsOf(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          stops: const [0.4, 1],
          colors: [widget.top, widget.bottom],
        ),
      ),
      child: on
          ? AnimatedBuilder(
              animation: _drift,
              builder: (context, child) {
                final turn = _drift.value * 2 * math.pi;
                return DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: RadialGradient(
                      center: Alignment(0.7 * math.sin(turn), -0.35 + 0.45 * math.cos(turn)),
                      radius: 0.95,
                      colors: [widget.glow.withValues(alpha: 0.55), widget.glow.withValues(alpha: 0)],
                    ),
                  ),
                  child: child,
                );
              },
              child: widget.child,
            )
          : widget.child,
    );
  }
}
