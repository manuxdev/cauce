import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/material.dart';

import '../../../core/app_prefs.dart';
import '../../../../src/rust/api/player.dart' as core;
import '../../../core/app_scope.dart';
import '../../../core/artwork.dart';
import '../../../core/icons.dart';
import '../../../core/l10n.dart';
import '../../../core/motion.dart';
import '../../../core/theme.dart';
import '../../../core/tint_scope.dart';
import '../../library/view_models/favorites_view_model.dart';
import '../../lyrics/views/lyrics_view.dart';
import '../../track/track_options.dart';
import '../view_models/player_view_model.dart';
import '../player_design.dart';
import 'player_parts.dart';
import 'immersive_design.dart';
import 'poster_design.dart';
import 'tape_design.dart';
import 'vinyl_design.dart';
import 'seek_bars.dart';
import 'queue_sheet.dart';

/// The full player on the cover's colour: the cover, the names, the seek bar, transport and
/// volume. The lyrics take the whole page when shown, on a lighter shade of the same colour.
class NowPlayingScreen extends StatefulWidget {
  const NowPlayingScreen({super.key, required this.player});

  final PlayerViewModel player;

  /// Opens the player growing out of `from`, the mini player's place on screen.
  static Future<void> open(BuildContext context, PlayerViewModel player, {Rect? from}) =>
      Navigator.of(context, rootNavigator: true).push(_PlayerRoute(from: from, player: player));

  @override
  State<NowPlayingScreen> createState() => _NowPlayingScreenState();
}

class _NowPlayingScreenState extends State<NowPlayingScreen> {
  /// Whether the lyrics take the page.
  /// Opens on them when the listener asks to and the track has some.
  late bool _showLyrics = appPrefs.openLyrics && AppScope.of(context).lyrics.lyrics != null;

  PlayerViewModel get player => widget.player;

  /// The route the player opened on, which a drag down closes by hand.
  _PlayerRoute? get _route => switch (ModalRoute.of(context)) {
    final _PlayerRoute route => route,
    _ => null,
  };

  /// Everything but the cover comes in a beat after the panel starts opening, rising 16 points.
  Widget _arrive(Widget child) {
    final animation = ModalRoute.of(context)?.animation;
    if (animation == null) return child;
    final arrive = CurvedAnimation(
      parent: animation,
      curve: const Interval(0.22, 1, curve: CauceCurves.exit),
    );
    return AnimatedBuilder(
      animation: arrive,
      builder: (context, child) => Opacity(
        opacity: arrive.value.clamp(0.0, 1.0),
        child: Transform.translate(offset: Offset(0, 16 * (1 - arrive.value)), child: child),
      ),
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    // The player stays dark in both themes, so its own text and controls are drawn on dark.
    return AnnotatedRegion(
      value: SystemUiOverlayStyle.light,
      child: Theme(
        data: cauceTheme(CauceColors.dark),
        child: DefaultTextStyle.merge(
          style: TextStyle(color: CauceColors.dark.foreground),
          child: _page(context),
        ),
      ),
    );
  }

  Widget _page(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([player, appPrefs]),
      builder: (context, _) {
        final track = player.track;
        if (track == null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) Navigator.of(context).maybePop();
          });
          return const SizedBox.shrink();
        }
        final design = appPrefs.playerDesign;
        void lyrics(bool show) => setState(() => _showLyrics = show);
        if (design != PlayerDesign.classic) {
          return Scaffold(
            backgroundColor: Colors.transparent,
            body: _closable(context, switch (design) {
              PlayerDesign.vinyl => VinylDesign(player: player, track: track, lyrics: _showLyrics, onLyrics: lyrics),
              PlayerDesign.poster => PosterDesign(player: player, track: track, lyrics: _showLyrics, onLyrics: lyrics),
              PlayerDesign.tape => TapeDesign(player: player, track: track, lyrics: _showLyrics, onLyrics: lyrics),
              _ => ImmersiveDesign(player: player, track: track, lyrics: _showLyrics, onLyrics: lyrics),
            }),
          );
        }
        final tint = TintScope.of(context).vivid;
        final top = _showLyrics ? tint.shade(0.4, 0.1) : tint.player;
        final bottom = _showLyrics ? tint.shade(0.36, 0.09) : tint.shade(0.24, 0.07);
        return Scaffold(
          backgroundColor: Colors.transparent,
          body: TweenAnimationBuilder<Color?>(
            tween: ColorTween(end: top),
            duration: const Duration(milliseconds: 600),
            builder: (context, top, child) => PlayerBackdrop(
              top: top!,
              bottom: bottom,
              glow: tint.shade(0.5, 0.14),
              moving: appPrefs.movingBackground && player.playing && !_showLyrics,
              child: child!,
            ),
            child: SafeArea(
              child: _closable(
                context,
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 280),
                  child: _showLyrics ? _lyrics(track) : _player(track),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  /// A drag down anywhere closes the player by hand.
  Widget _closable(BuildContext context, Widget child) {
    final height = MediaQuery.sizeOf(context).height;
    return GestureDetector(
      onVerticalDragStart: (_) => _route?.dragStart(),
      onVerticalDragUpdate: (details) => _route?.dragUpdate((details.primaryDelta ?? 0) / height),
      onVerticalDragEnd: (details) => _route?.dragEnd((details.primaryVelocity ?? 0) / height),
      onVerticalDragCancel: () => _route?.dragEnd(0),
      child: child,
    );
  }

  Widget _player(core.TrackItem track) {
    return Padding(
      key: const ValueKey('player'),
      padding: const EdgeInsets.symmetric(horizontal: 28),
      child: Column(
        children: [
          _arrive(PlayerHeader(track: track)),
          const SizedBox(height: 16),
          Expanded(
            child: Center(
              child: _CoverDeck(player: player, track: track),
            ),
          ),
          const SizedBox(height: 24),
          _arrive(_Titles(track: track, favorites: AppScope.of(context).favorites)),
          const SizedBox(height: 20),
          _arrive(
            SeekBar(
              player: player,
              style: seekStyleFor(PlayerDesign.classic, appPrefs.seekStyle),
              tag: track.source == 'local' ? null : track.source,
            ),
          ),
          const SizedBox(height: 18),
          _arrive(_Transport(player: player)),
          const SizedBox(height: 22),
          _arrive(const SystemVolume()),
          const SizedBox(height: 14),
          _arrive(
            _Extras(
              onLyrics: () => setState(() => _showLyrics = true),
              onQueue: () => QueueSheet.open(context, player),
            ),
          ),
          const SizedBox(height: 6),
        ],
      ),
    );
  }

  Widget _lyrics(core.TrackItem track) {
    return Column(
      key: const ValueKey('lyrics'),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 12, 0),
          child: Row(
            children: [
              Artwork(url: track.cover, size: 44, radius: 8),
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
                      style: const TextStyle(fontSize: 13, color: Color(0xA6FFFFFF)),
                    ),
                  ],
                ),
              ),
              IconButton(
                onPressed: () => setState(() => _showLyrics = false),
                icon: const CauceIcon(CauceGlyph.chevronDown, weight: 2.4),
              ),
            ],
          ),
        ),
        Expanded(
          child: LyricsPanel(lyrics: AppScope.of(context).lyrics, player: player),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28),
          child: SeekBar(
            player: player,
            style: seekStyleFor(PlayerDesign.classic, appPrefs.seekStyle, lyrics: true),
            times: false,
            compact: true,
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(60, 6, 60, 10),
          child: _Transport(player: player, compact: true),
        ),
      ],
    );
  }
}

class _Titles extends StatelessWidget {
  const _Titles({required this.track, required this.favorites});

  final core.TrackItem track;
  final FavoritesViewModel favorites;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 220),
            layoutBuilder: (current, previous) =>
                Stack(alignment: Alignment.centerLeft, children: [...previous, ?current]),
            child: Column(
              key: ValueKey((track.id, track.source)),
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  track.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontFamily: displayFont,
                    fontSize: 26,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.5,
                  ),
                ),
                const SizedBox(height: 2),
                Builder(
                  // Its own context, so the menu opens under the name.
                  builder: (context) => GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => showArtistMenu(context, track, leave: Navigator.of(context).pop),
                    child: Row(
                      children: [
                        Flexible(
                          child: Text(
                            track.artists,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 17, color: Color(0xB3FFFFFF)),
                          ),
                        ),
                        const SizedBox(width: 4),
                        const CauceIcon(CauceGlyph.chevronRight, size: 15, color: Color(0xB3FFFFFF), weight: 2.2),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (track.source != 'local')
          ListenableBuilder(
            listenable: favorites,
            builder: (context, _) {
              final saved = favorites.saved(track);
              return HeartButton(saved: saved, onTap: () => favorites.toggle(track));
            },
          ),
      ],
    );
  }
}

/// Previous, play and next in the buttons the listener picked.
class _Transport extends StatelessWidget {
  const _Transport({required this.player, this.compact = false});

  final PlayerViewModel player;

  /// Smaller, for under the lyrics.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final look = buttonLookFor(PlayerDesign.classic, appPrefs.buttonLook);
    // Under the lyrics the circle's play has no fill, as it always had.
    final playLook = compact && look == ButtonLook.circle ? ButtonLook.plain : look;
    final skip = compact ? 26.0 : 32.0;
    return Row(
      mainAxisAlignment: compact ? MainAxisAlignment.spaceBetween : MainAxisAlignment.spaceEvenly,
      children: [
        SkipButton(
          glyph: CauceGlyph.prev,
          onTap: player.previous,
          player: player,
          forward: false,
          size: skip,
          look: look,
        ),
        PlayButton(player: player, look: playLook, size: compact ? 56 : 78, iconSize: 34),
        SkipButton(glyph: CauceGlyph.next, onTap: player.next, player: player, forward: true, size: skip, look: look),
      ],
    );
  }
}

/// Lyrics, the audio output and the queue along the bottom.
class _Extras extends StatelessWidget {
  const _Extras({required this.onLyrics, required this.onQueue});

  final VoidCallback onLyrics;
  final VoidCallback onQueue;

  @override
  Widget build(BuildContext context) {
    // Larger and closer together than an even spread, as one group in the middle.
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        IconButton(
          iconSize: 28,
          icon: const CauceIcon(CauceGlyph.lyrics, size: 28),
          tooltip: context.t('player.lyrics'),
          onPressed: onLyrics,
        ),
        const SizedBox(width: 28),
        // The phone's output list: the phone, AirPlay or cast, and Bluetooth devices.
        const SizedBox.square(dimension: 48, child: RoutePicker()),
        const SizedBox(width: 28),
        IconButton(
          iconSize: 28,
          icon: const CauceIcon(CauceGlyph.queue, size: 28),
          tooltip: context.t('player.queue'),
          onPressed: onQueue,
        ),
      ],
    );
  }
}

/// The full player growing out of the mini player: the panel opens from its place with its
/// rounded corners to the whole screen on a soft spring, the cover flies on its hero, and the
/// dock drops away. A drag down shrinks it back by hand.
class _PlayerRoute extends PageRoute<void> with DragToLeave<void> {
  _PlayerRoute({required this.from, required this.player});

  final Rect? from;
  final PlayerViewModel player;

  @override
  Duration get transitionDuration => CauceCurves.soft.duration;

  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 380);

  @override
  bool get opaque => false;

  @override
  bool get maintainState => true;

  @override
  Color? get barrierColor => null;

  @override
  String? get barrierLabel => null;

  @override
  void install() {
    super.install();
    animation!.addListener(_reveal);
  }

  /// How far the panel is open, on the same curve it is drawn with, so the dock fades with it.
  double get _open {
    final value = animation!.value;
    if (dragging) return value;
    return animation!.status == AnimationStatus.reverse
        ? CauceCurves.standard.transform(value)
        : CauceCurves.soft.transform(value);
  }

  void _reveal() => playerReveal.value = _open.clamp(0.0, 1.0);

  @override
  void dispose() {
    animation?.removeListener(_reveal);
    playerReveal.value = 0;
    super.dispose();
  }

  @override
  Widget buildPage(BuildContext context, Animation<double> animation, Animation<double> secondaryAnimation) =>
      NowPlayingScreen(player: player);

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final size = MediaQuery.sizeOf(context);
    final full = Offset.zero & size;
    final start = from ?? Rect.fromLTWH(8, size.height - 150, size.width - 16, 64);
    if (MediaQuery.disableAnimationsOf(context)) return FadeTransition(opacity: animation, child: child);
    final open = dragging
        ? animation
        : CurvedAnimation(parent: animation, curve: CauceCurves.soft, reverseCurve: CauceCurves.standard);
    return AnimatedBuilder(
      animation: open,
      builder: (context, child) {
        final t = open.value.clamp(0.0, 1.0);
        final panel = ClipRRect(clipper: _PanelClip(Rect.lerp(start, full, t)!, 18 * (1 - t)), child: child);
        // Closing, the panel fades over its last stretch as the mini player fades in under it.
        if (animation.status != AnimationStatus.reverse) return panel;
        return Opacity(opacity: (t / panelFade).clamp(0.0, 1.0), child: panel);
      },
      child: child,
    );
  }
}

class _PanelClip extends CustomClipper<RRect> {
  const _PanelClip(this.rect, this.radius);

  final Rect rect;
  final double radius;

  @override
  RRect getClip(Size size) => RRect.fromRectAndRadius(rect, Radius.circular(radius));

  @override
  bool shouldReclip(_PanelClip old) => old.rect != rect || old.radius != radius;
}

/// The cover, which slides aside for the next one when the track changes: the old one leaves
/// 300 points one way as the new one comes in from the other, in 380 ms. Next comes from the
/// right. A swipe across it changes the track too.
class _CoverDeck extends StatefulWidget {
  const _CoverDeck({required this.player, required this.track});

  final PlayerViewModel player;
  final core.TrackItem track;

  @override
  State<_CoverDeck> createState() => _CoverDeckState();
}

class _CoverDeckState extends State<_CoverDeck> with SingleTickerProviderStateMixin {
  late final _slide = AnimationController(vsync: this, duration: const Duration(milliseconds: 380), value: 1);
  late final _curve = CurvedAnimation(parent: _slide, curve: CauceCurves.exit);
  core.TrackItem? _leaving;
  int? _index;

  /// 1 when the new cover comes from the right, -1 from the left.
  int _direction = 1;

  @override
  void initState() {
    super.initState();
    _index = widget.player.index;
  }

  @override
  void didUpdateWidget(_CoverDeck old) {
    super.didUpdateWidget(old);
    final index = widget.player.index;
    if (old.track.id != widget.track.id || old.track.source != widget.track.source) {
      _direction = (index != null && _index != null && index < _index!) ? -1 : 1;
      _leaving = old.track;
      if (!MediaQuery.disableAnimationsOf(context)) _slide.forward(from: 0);
    }
    _index = index;
  }

  @override
  void dispose() {
    _curve.dispose();
    _slide.dispose();
    super.dispose();
  }

  Widget _art(core.TrackItem track, double side) => DecoratedBox(
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(16),
      boxShadow: const [BoxShadow(color: Color(0x73000000), blurRadius: 50, offset: Offset(0, 22))],
    ),
    child: Artwork(url: track.coverLarge ?? track.cover, size: side, radius: 16),
  );

  @override
  Widget build(BuildContext context) {
    final player = widget.player;
    return LayoutBuilder(
      builder: (context, constraints) {
        final side = constraints.biggest.shortestSide;
        return GestureDetector(
          onHorizontalDragEnd: (details) {
            final velocity = details.primaryVelocity ?? 0;
            if (velocity < -300) player.next();
            if (velocity > 300) player.previous();
          },
          child: AnimatedScale(
            scale: player.playing ? 1 : 0.88,
            duration: const Duration(milliseconds: 380),
            curve: Curves.easeOutBack,
            child: AnimatedBuilder(
              animation: _curve,
              builder: (context, current) {
                final t = _curve.value;
                return Stack(
                  clipBehavior: Clip.none,
                  alignment: Alignment.center,
                  children: [
                    if (_leaving case final leaving? when _slide.isAnimating)
                      Transform.translate(
                        offset: Offset(-300 * _direction * t, 0),
                        child: Opacity(opacity: 1 - t, child: _art(leaving, side)),
                      ),
                    Transform.translate(offset: Offset(300 * _direction * (1 - t), 0), child: current),
                  ],
                );
              },
              child: Hero(tag: 'artwork', transitionOnUserGestures: true, child: _art(widget.track, side)),
            ),
          ),
        );
      },
    );
  }
}
