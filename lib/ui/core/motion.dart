import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'theme.dart';

/// The curves and springs the design names, so every movement in the app comes from one set.
abstract final class CauceCurves {
  /// Everything that comes in or arrives.
  static const exit = Cubic(0.22, 1, 0.36, 1);

  /// Changes in place: the tint, going back.
  static const standard = Cubic(0.4, 0, 0.2, 1);

  /// Leaving, which is quicker than arriving.
  static const accelerate = Cubic(0.4, 0, 1, 1);

  /// The full player, sheets, lyrics.
  static const soft = SpringCurve(170, 26);

  /// Tabs, likes, presses: a little bounce.
  static const vivid = SpringCurve(300, 20);
}

/// The step response of a spring with unit mass, squeezed into 0..1 over the time it takes to
/// settle, as the design draws its springs.
class SpringCurve extends Curve {
  const SpringCurve(this.stiffness, this.damping);

  final double stiffness;
  final double damping;

  double get _omega => math.sqrt(stiffness);
  double get _zeta => damping / (2 * _omega);

  /// How long the spring takes to settle, which is how long an animation on it should run.
  Duration get duration => Duration(microseconds: (_settle * 1e6).round());

  double get _settle => math.min(6.9 / (_zeta * _omega), 2.2);

  @override
  double transformInternal(double t) {
    final w = _omega;
    final z = _zeta;
    final wd = w * math.sqrt(math.max(1e-4, 1 - z * z));
    final time = _settle * t;
    return 1 - math.exp(-z * w * time) * (math.cos(wd * time) + (z * w / wd) * math.sin(wd * time));
  }
}

/// How many sheets are open over the app, which shrinks back while any is.
final sheetsOpen = ValueNotifier<int>(0);

/// Whether the dock is folded to its tabs, the mini player tucked away, as scrolling down the
/// home feed does.
final dockCompact = ValueNotifier<bool>(false);

/// How far the full player has opened, 0 to 1, which the dock moves away with.
final playerReveal = ValueNotifier<double>(0);

/// The stretch of the full player's opening, from closed, over which the dock and the panel
/// cross-fade.
const panelFade = 0.3;

/// How a sheet comes in and goes: a soft spring in, quicker out.
final sheetAnimation = AnimationStyle(
  duration: CauceCurves.soft.duration,
  reverseDuration: const Duration(milliseconds: 260),
  curve: CauceCurves.soft,
  reverseCurve: CauceCurves.accelerate,
);

/// Shows `sheet` with the app shrunk back behind it until it closes.
Future<T?> behindSheet<T>(Future<T?> sheet) async {
  sheetsOpen.value++;
  try {
    return await sheet;
  } finally {
    sheetsOpen.value--;
  }
}

/// The app as it sits behind a sheet: down to 92 %, a little lower, with rounded corners while
/// one is open. It goes back as fast as the sheet leaves.
class BehindSheet extends StatefulWidget {
  const BehindSheet({super.key, required this.child});

  final Widget child;

  @override
  State<BehindSheet> createState() => _BehindSheetState();
}

class _BehindSheetState extends State<BehindSheet> with SingleTickerProviderStateMixin {
  late final _depth = AnimationController(
    vsync: this,
    duration: CauceCurves.soft.duration,
    reverseDuration: const Duration(milliseconds: 260),
  );
  late final _curve = CurvedAnimation(parent: _depth, curve: CauceCurves.soft, reverseCurve: CauceCurves.accelerate);

  @override
  void initState() {
    super.initState();
    sheetsOpen.addListener(_follow);
  }

  void _follow() => sheetsOpen.value > 0 ? _depth.forward() : _depth.reverse();

  @override
  void dispose() {
    sheetsOpen.removeListener(_follow);
    _curve.dispose();
    _depth.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) return widget.child;
    return AnimatedBuilder(
      animation: _curve,
      builder: (context, child) {
        final depth = _curve.value;
        if (depth == 0) return child!;
        return Transform.translate(
          offset: Offset(0, 14 * depth),
          child: Transform.scale(
            scale: 1 - 0.08 * depth,
            child: ClipRRect(borderRadius: BorderRadius.circular(26 * depth), child: child),
          ),
        );
      },
      child: widget.child,
    );
  }
}

/// Folds the dock while the user scrolls `child` down, and opens it again on the way up or
/// back near the top.
class FoldsDock extends StatelessWidget {
  const FoldsDock({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return NotificationListener<ScrollUpdateNotification>(
      onNotification: (notification) {
        if (notification.depth != 0 || notification.dragDetails == null) return false;
        final delta = notification.scrollDelta ?? 0;
        if (notification.metrics.pixels <= 40) {
          dockCompact.value = false;
        } else if (delta > 2) {
          dockCompact.value = true;
        } else if (delta < -2) {
          dockCompact.value = false;
        }
        return false;
      },
      child: child,
    );
  }
}

/// Sinks while pressed, quickly, and springs back with a little bounce. Cards sink to 96 %,
/// buttons to 90 %.
class Pressable extends StatefulWidget {
  const Pressable({super.key, required this.onTap, required this.child, this.scale = 0.96, this.onLongPress});

  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final Widget child;
  final double scale;

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  bool _down = false;

  void _set(bool down) {
    if (down != _down) setState(() => _down = down);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      onTapDown: widget.onTap == null ? null : (_) => _set(true),
      onTapUp: (_) => _set(false),
      onTapCancel: () => _set(false),
      child: AnimatedScale(
        scale: _down ? widget.scale : 1,
        duration: _down ? const Duration(milliseconds: 120) : CauceCurves.vivid.duration,
        curve: _down ? Curves.easeOut : CauceCurves.vivid,
        child: widget.child,
      ),
    );
  }
}

/// Play or pause, as the design times it: the icon leaving turns 90° away and shrinks to 60 %
/// as it fades, in 256 ms on the exit curve; the one arriving turns in from −90° on the lively
/// spring, in 384 ms. Loading keeps the icon it is heading for, with a thin ring around it once
/// it takes long enough to notice.
class PlayPauseIcon extends StatefulWidget {
  const PlayPauseIcon({
    super.key,
    required this.playing,
    required this.loading,
    required this.color,
    required this.icon,
    this.size = 24,
  });

  final bool playing;
  final bool loading;
  final Color color;
  final double size;

  /// Builds the glyph, so this file stays free of the icon set.
  final Widget Function(bool playing, double size, Color color) icon;

  @override
  State<PlayPauseIcon> createState() => _PlayPauseIconState();
}

class _PlayPauseIconState extends State<PlayPauseIcon> with TickerProviderStateMixin {
  late final _in = AnimationController(vsync: this, duration: const Duration(milliseconds: 384), value: 1);
  late final _out = AnimationController(vsync: this, duration: const Duration(milliseconds: 256), value: 1);

  /// Pause shows while playing and while loading towards playing.
  late bool _shown = widget.playing || widget.loading;
  bool? _leaving;

  /// The ring only after a short wait, so a quick load never flashes it.
  Timer? _wait;
  bool _ring = false;

  @override
  void initState() {
    super.initState();
    _watchLoading();
  }

  @override
  void didUpdateWidget(PlayPauseIcon old) {
    super.didUpdateWidget(old);
    final shown = widget.playing || widget.loading;
    if (shown != _shown) {
      _leaving = _shown;
      _shown = shown;
      if (MediaQuery.disableAnimationsOf(context)) {
        _in.value = 1;
        _out.value = 1;
      } else {
        _in.forward(from: 0);
        _out.forward(from: 0);
      }
    }
    if (widget.loading != old.loading) _watchLoading();
  }

  void _watchLoading() {
    _wait?.cancel();
    if (!widget.loading) {
      if (_ring) setState(() => _ring = false);
      return;
    }
    _wait = Timer(const Duration(milliseconds: 400), () {
      if (mounted) setState(() => _ring = true);
    });
  }

  @override
  void dispose() {
    _wait?.cancel();
    _in.dispose();
    _out.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = widget.size;
    return SizedBox.square(
      dimension: size * 1.5,
      child: AnimatedBuilder(
        animation: Listenable.merge([_in, _out]),
        builder: (context, _) {
          final arrive = CauceCurves.vivid.transform(_in.value);
          final leave = CauceCurves.exit.transform(_out.value);
          return Stack(
            alignment: Alignment.center,
            children: [
              if (_leaving case final leaving? when _out.isAnimating)
                Opacity(
                  opacity: (1 - leave).clamp(0.0, 1.0),
                  child: Transform.rotate(
                    angle: math.pi / 2 * leave,
                    child: Transform.scale(scale: 1 - 0.4 * leave, child: widget.icon(leaving, size, widget.color)),
                  ),
                ),
              Opacity(
                // Fades in over the first third, then the spring carries the turn and the size.
                opacity: (_in.value * 3).clamp(0.0, 1.0),
                child: Transform.rotate(
                  angle: -math.pi / 2 * (1 - arrive),
                  child: Transform.scale(scale: 0.6 + 0.4 * arrive, child: widget.icon(_shown, size, widget.color)),
                ),
              ),
              if (_ring)
                SizedBox.square(
                  dimension: size * 1.5,
                  child: CircularProgressIndicator(strokeWidth: 2, color: widget.color.withValues(alpha: 0.6)),
                ),
            ],
          );
        },
      ),
    );
  }
}

/// Content arriving where its skeleton was: the skeleton fades as the content fades in rising
/// 8 points, in 260 ms. Both take the same place, so nothing jumps.
class LoadSwitch extends StatelessWidget {
  const LoadSwitch({super.key, required this.loading, required this.skeleton, required this.child});

  final bool loading;
  final Widget skeleton;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 260),
      switchInCurve: CauceCurves.exit,
      switchOutCurve: CauceCurves.standard,
      layoutBuilder: (current, previous) => Stack(alignment: Alignment.topCenter, children: [...previous, ?current]),
      transitionBuilder: (child, animation) => AnimatedBuilder(
        animation: animation,
        builder: (context, child) => Opacity(
          opacity: animation.value,
          child: Transform.translate(offset: Offset(0, 8 * (1 - animation.value)), child: child),
        ),
        child: child,
      ),
      child: KeyedSubtree(key: ValueKey(loading), child: loading ? skeleton : child),
    );
  }
}

/// Content that has just arrived, in place of its skeleton or for a fresh result: it fades in
/// rising 8 points over 260 ms, once, after `delay` so a list of groups can come in a beat apart.
class Arrive extends StatefulWidget {
  const Arrive({super.key, required this.child, this.delay = Duration.zero});

  final Widget child;
  final Duration delay;

  @override
  State<Arrive> createState() => _ArriveState();
}

class _ArriveState extends State<Arrive> with SingleTickerProviderStateMixin {
  late final _in = AnimationController(vsync: this, duration: const Duration(milliseconds: 260));
  late final _curve = CurvedAnimation(parent: _in, curve: CauceCurves.exit);
  Timer? _wait;

  @override
  void initState() {
    super.initState();
    if (widget.delay == Duration.zero) {
      _in.forward();
    } else {
      _wait = Timer(widget.delay, _in.forward);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) _in.value = 1;
  }

  @override
  void dispose() {
    _wait?.cancel();
    _curve.dispose();
    _in.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _curve,
      builder: (context, child) => Opacity(
        opacity: _curve.value.clamp(0.0, 1.0),
        child: Transform.translate(offset: Offset(0, 8 * (1 - _curve.value)), child: child),
      ),
      child: widget.child,
    );
  }
}

/// Fades out as the scroll view it sits in passes `from`, gone `over` points later, such as a
/// big play button handing over to the small one in the bar.
class ScrollFade extends StatefulWidget {
  const ScrollFade({super.key, required this.from, required this.child, this.over = 80});

  final double from;
  final double over;
  final Widget child;

  @override
  State<ScrollFade> createState() => _ScrollFadeState();
}

class _ScrollFadeState extends State<ScrollFade> {
  ScrollPosition? _position;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _position?.removeListener(_moved);
    _position = Scrollable.maybeOf(context)?.position?..addListener(_moved);
  }

  void _moved() => setState(() {});

  @override
  void dispose() {
    _position?.removeListener(_moved);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pixels = _position?.hasPixels ?? false ? _position!.pixels : 0.0;
    final shown = 1 - ((pixels - widget.from) / widget.over).clamp(0.0, 1.0);
    return IgnorePointer(
      ignoring: shown == 0,
      child: Opacity(
        opacity: shown,
        child: Transform.scale(scale: 0.8 + 0.2 * shown, child: widget.child),
      ),
    );
  }
}

/// Pull down to reload, as the design draws it: a ring above the title fills as the page is
/// pulled, ticks once it is far enough, and spins in its own room above the title while the page
/// reloads, also when something else reloads it, such as picking another provider.
class PullToRefresh extends StatefulWidget {
  const PullToRefresh({super.key, required this.onRefresh, required this.builder, this.busy = false});

  final Future<void> Function() onRefresh;

  /// Reloading for another reason.
  final bool busy;

  /// Builds the scroll view, which puts `header` first, above the title.
  final Widget Function(BuildContext context, Widget header) builder;

  @override
  State<PullToRefresh> createState() => _PullToRefreshState();
}

class _PullToRefreshState extends State<PullToRefresh> {
  /// How far past the top the page is pulled to reload.
  static const _reach = 90.0;

  double _pull = 0;
  bool _armed = false;
  bool _refreshing = false;

  bool _scrolled(ScrollNotification notification) {
    if (notification.depth != 0 || _refreshing) return false;
    final metrics = notification.metrics;
    final over = (metrics.minScrollExtent - metrics.pixels).clamp(0.0, double.infinity);
    final dragging = notification is ScrollUpdateNotification && notification.dragDetails != null;
    if (dragging) {
      final armed = over >= _reach;
      if (armed && !_armed) HapticFeedback.selectionClick();
      setState(() {
        _pull = (over / _reach).clamp(0.0, 1.0);
        _armed = armed;
      });
    } else if (_armed && (notification is ScrollEndNotification || notification is ScrollUpdateNotification)) {
      _refresh();
    } else if (_pull != 0 && over == 0) {
      setState(() => _pull = 0);
    }
    return false;
  }

  Future<void> _refresh() async {
    setState(() {
      _armed = false;
      _pull = 0;
      _refreshing = true;
    });
    try {
      await widget.onRefresh();
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  static Widget _ring(double? value) => SizedBox.square(
    dimension: 26,
    child: CircularProgressIndicator(
      value: value,
      strokeWidth: 2.6,
      color: CauceColors.accent,
      backgroundColor: Colors.white.withValues(alpha: 0.12),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final spinning = _refreshing || widget.busy;
    final header = AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      curve: CauceCurves.exit,
      height: spinning ? 46 : 0,
      alignment: Alignment.center,
      child: spinning ? _ring(null) : null,
    );
    return NotificationListener<ScrollNotification>(
      onNotification: _scrolled,
      child: Stack(
        children: [
          widget.builder(context, header),
          if (_pull > 0 && !spinning)
            Positioned(
              top: MediaQuery.paddingOf(context).top + 8,
              left: 0,
              right: 0,
              child: IgnorePointer(
                child: Center(
                  child: Opacity(opacity: _pull, child: _ring(_pull)),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// A route that the user can drag back by hand: the page follows the finger, and letting go
/// fast or far enough finishes leaving, otherwise it springs back.
mixin DragToLeave<T> on TransitionRoute<T> {
  bool get dragging => navigator?.userGestureInProgress ?? false;

  void dragStart() => navigator?.didStartUserGesture();

  /// Moves the page by `fraction` of the way back.
  void dragUpdate(double fraction) {
    controller!.value = (controller!.value - fraction).clamp(0.0, 1.0);
  }

  /// `velocity` in fractions of the way back per second.
  void dragEnd(double velocity) {
    final leave = velocity > 1 || (velocity > -1 && controller!.value < 0.6);
    if (leave) {
      navigator?.pop();
    } else {
      controller!.forward();
    }
    if (controller!.isAnimating) {
      late final AnimationStatusListener done;
      done = (status) {
        if (status.isAnimating) return;
        navigator?.didStopUserGesture();
        controller!.removeStatusListener(done);
      };
      controller!.addStatusListener(done);
    } else {
      navigator?.didStopUserGesture();
    }
  }
}

/// Opening an album, playlist or artist: the cover flies to the header on its hero, the page
/// fades in rising 20 points, and the page behind moves aside 24 points and fades. A drag from
/// the left edge goes back by hand.
class CoverRoute<T> extends PageRoute<T> with DragToLeave<T> {
  CoverRoute({required this.builder, super.settings});

  final WidgetBuilder builder;

  @override
  Duration get transitionDuration => const Duration(milliseconds: 420);

  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 380);

  @override
  bool get opaque => true;

  @override
  bool get maintainState => true;

  @override
  Color? get barrierColor => null;

  @override
  String? get barrierLabel => null;

  @override
  DelegatedTransitionBuilder? get delegatedTransition => _aside;

  static Widget? _aside(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    bool allowSnapshotting,
    Widget? child,
  ) {
    if (MediaQuery.disableAnimationsOf(context)) {
      return FadeTransition(opacity: ReverseAnimation(secondaryAnimation), child: child);
    }
    final aside = CurvedAnimation(
      parent: secondaryAnimation,
      curve: CauceCurves.exit,
      reverseCurve: CauceCurves.standard,
    );
    return AnimatedBuilder(
      animation: aside,
      builder: (context, child) => Opacity(
        opacity: 1 - aside.value,
        child: Transform.translate(
          offset: Offset(-24 * aside.value, 0),
          child: Transform.scale(scale: 1 - 0.03 * aside.value, child: child),
        ),
      ),
      child: child,
    );
  }

  @override
  Widget buildPage(BuildContext context, Animation<double> animation, Animation<double> secondaryAnimation) =>
      builder(context);

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final arrive = dragging
        ? animation
        : CurvedAnimation(parent: animation, curve: CauceCurves.exit, reverseCurve: CauceCurves.standard);
    final still = MediaQuery.disableAnimationsOf(context);
    final width = MediaQuery.sizeOf(context).width;
    return Stack(
      children: [
        AnimatedBuilder(
          animation: arrive,
          builder: (context, child) => Opacity(
            opacity: arrive.value.clamp(0.0, 1.0),
            child: still ? child : Transform.translate(offset: Offset(0, 20 * (1 - arrive.value)), child: child),
          ),
          child: child,
        ),
        // The edge a back swipe starts from.
        Positioned(
          left: 0,
          top: 0,
          bottom: 0,
          width: 20,
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onHorizontalDragStart: (_) => dragStart(),
            onHorizontalDragUpdate: (details) => dragUpdate((details.primaryDelta ?? 0) / width),
            onHorizontalDragEnd: (details) => dragEnd((details.primaryVelocity ?? 0) / width),
            onHorizontalDragCancel: () => dragEnd(0),
          ),
        ),
      ],
    );
  }
}

/// A stable hero tag for one card on screen, so the same album twice on a page never clashes.
Object coverTag(String place, String id) => 'cover:$place:$id';
