import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';

import 'app_prefs.dart';
import 'artwork.dart';
import 'icons.dart';
import 'l10n.dart';
import 'motion.dart';
import 'theme.dart';
import 'tint.dart';

enum ToastTone { ok, info, error }

/// A short note of something that just happened that the screen does not already show: what
/// changed, an optional detail line and at most one action.
@immutable
class Toast {
  const Toast({
    required this.title,
    this.detail,
    this.cover,
    this.glyph,
    this.tone = ToastTone.ok,
    this.badge = false,
    this.action,
    this.onAction,
    this.onUndo,
    this.onGone,
    this.progress,
  });

  /// What happened, in the past and naming where («Added to Running»).
  final String title;
  final String? detail;

  /// The cover of what it is about; without one, [glyph] in a circle.
  final String? cover;
  final CauceGlyph? glyph;
  final ToastTone tone;

  /// A ✓ or ✕ on the cover, in the accent or the error colour.
  final bool badge;

  /// The one action, such as «View» or «Retry». A tap on the rest of the toast does the same.
  final String? action;
  final VoidCallback? onAction;

  /// Makes the action «Undo»: the toast holds back what [onGone] carries out once it goes.
  final VoidCallback? onUndo;
  final VoidCallback? onGone;

  /// Work still going, from 0 to 1, drawn as a line along the bottom.
  final ValueListenable<double>? progress;

  /// 3 s for text, 4 s with an action, 6 s with undo.
  Duration get time => Duration(seconds: onUndo != null ? 6 : (action != null ? 4 : 3));
}

/// The toast showing, one at a time: a new one replaces the one before.
class ToastCenter extends ValueNotifier<Toast?> {
  ToastCenter() : super(null);

  Timer? _timer;
  bool _held = false;

  void show(Toast toast) {
    _end();
    value = toast;
    _start();
    if (appPrefs.haptics) {
      toast.tone == ToastTone.error ? HapticFeedback.heavyImpact() : HapticFeedback.lightImpact();
    }
  }

  /// Stops the time while the toast is touched or read out; it starts over when let go.
  void hold(bool held) {
    if (held == _held) return;
    _held = held;
    held ? _timer?.cancel() : _start();
  }

  /// Takes back what the toast held back, and closes it.
  void undo() {
    final toast = value;
    if (toast == null) return;
    _timer?.cancel();
    value = null;
    toast.onUndo?.call();
  }

  void dismiss() => _end();

  void _start() {
    _timer?.cancel();
    final toast = value;
    if (toast == null || _held) return;
    _timer = Timer(toast.time, _end);
  }

  void _end() {
    _timer?.cancel();
    final toast = value;
    if (toast == null) return;
    value = null;
    toast.onGone?.call();
  }
}

final toasts = ToastCenter();

void showToast(Toast toast) => toasts.show(toast);

/// How tall the dock is, for toasts to sit just above it.
final dockExtent = ValueNotifier<double>(0);

/// Lays toasts over [child]: 8 pt above the dock, or under the Dynamic Island while the full
/// player covers the dock.
class ToastHost extends StatefulWidget {
  const ToastHost({super.key, required this.child});

  final Widget child;

  @override
  State<ToastHost> createState() => _ToastHostState();
}

class _ToastHostState extends State<ToastHost> {
  @override
  void initState() {
    super.initState();
    toasts.addListener(_announce);
  }

  @override
  void dispose() {
    toasts.removeListener(_announce);
    super.dispose();
  }

  void _announce() {
    final toast = toasts.value;
    if (toast == null || !mounted) return;
    final text = [toast.title, ?toast.detail].join('. ');
    SemanticsService.sendAnnouncement(View.of(context), text, TextDirection.ltr);
  }

  @override
  Widget build(BuildContext context) {
    // VoiceOver reads it at its own pace, so the time does not run.
    toasts.hold(MediaQuery.accessibleNavigationOf(context));
    final still = MediaQuery.disableAnimationsOf(context);
    final padding = MediaQuery.paddingOf(context);
    return Stack(
      children: [
        widget.child,
        ListenableBuilder(
          listenable: Listenable.merge([toasts, playerReveal, dockExtent]),
          builder: (context, _) {
            final top = playerReveal.value > 0.5;
            final toast = toasts.value;
            return Positioned(
              left: 10,
              right: 10,
              top: top ? padding.top + 4 : null,
              bottom: top ? null : dockExtent.value + 8,
              child: AnimatedSwitcher(
                duration: Duration(milliseconds: still ? 200 : 420),
                reverseDuration: Duration(milliseconds: still ? 200 : 220),
                switchInCurve: still ? Curves.linear : CauceCurves.soft,
                switchOutCurve: Curves.easeIn,
                layoutBuilder: (current, previous) =>
                    Stack(alignment: Alignment.center, children: [...previous, ?current]),
                transitionBuilder: (child, animation) {
                  final fade = FadeTransition(opacity: animation, child: child);
                  if (still) return fade;
                  final entering = child.key == ValueKey(toast);
                  return AnimatedBuilder(
                    animation: animation,
                    builder: (context, child) {
                      final t = animation.value;
                      // In: up 24 pt from 94 %. Out: down 16 pt, or shrinking to 96 % under the next.
                      final (dy, scale) = entering
                          ? ((top ? -24.0 : 24.0) * (1 - t), 0.94 + 0.06 * t)
                          : toast == null
                          ? ((top ? -16.0 : 16.0) * (1 - t), 1.0)
                          : (0.0, 0.96 + 0.04 * t);
                      return Transform.translate(
                        offset: Offset(0, dy),
                        child: Transform.scale(scale: scale, child: child),
                      );
                    },
                    child: fade,
                  );
                },
                child: toast == null ? const SizedBox.shrink() : _Swipe(key: ValueKey(toast), toast: toast),
              ),
            );
          },
        ),
      ],
    );
  }
}

/// Follows the finger down or to either side, and lets the toast go past a short distance.
class _Swipe extends StatefulWidget {
  const _Swipe({super.key, required this.toast});

  final Toast toast;

  @override
  State<_Swipe> createState() => _SwipeState();
}

class _SwipeState extends State<_Swipe> {
  Offset _drag = Offset.zero;
  bool _dragging = false;

  void _tap() {
    final toast = widget.toast;
    if (toast.onUndo != null) return;
    toasts.dismiss();
    toast.onAction?.call();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => toasts.hold(true),
      onTapUp: (_) => toasts.hold(false),
      onTapCancel: () => toasts.hold(false),
      onTap: _tap,
      onPanStart: (_) {
        toasts.hold(true);
        setState(() => _dragging = true);
      },
      onPanUpdate: (details) => setState(() {
        final next = _drag + details.delta;
        // Up only resists; down and sideways follow.
        _drag = Offset(next.dx, next.dy < 0 ? next.dy * 0.3 : next.dy);
      }),
      onPanEnd: (details) {
        final velocity = details.velocity.pixelsPerSecond;
        if (_drag.dx.abs() > 90 || _drag.dy > 40 || velocity.dx.abs() > 700 || velocity.dy > 500) {
          toasts.dismiss();
          return;
        }
        toasts.hold(false);
        setState(() {
          _dragging = false;
          _drag = Offset.zero;
        });
      },
      child: AnimatedContainer(
        duration: Duration(milliseconds: _dragging ? 0 : 220),
        curve: CauceCurves.exit,
        transform: Matrix4.translationValues(_drag.dx, _drag.dy, 0),
        child: Opacity(
          opacity: (1 - _drag.dx.abs() / 400).clamp(0.3, 1.0),
          // Above the navigator, so it brings its own text style.
          child: Material(
            type: MaterialType.transparency,
            child: ToastCard(toast: widget.toast),
          ),
        ),
      ),
    );
  }
}

/// A toast as drawn: light over the dark theme and dark over the light one, so it never reads
/// as part of the dock or a sheet.
class ToastCard extends StatelessWidget {
  const ToastCard({super.key, required this.toast});

  final Toast toast;

  @override
  Widget build(BuildContext context) {
    final light = !CauceColors.light;
    final palette = Palette.of(light: light, accent: appPrefs.accent);
    final background = light ? const Color(0xFFF8F3F7) : oklch(0.23, 0.03, 320);
    final ink = light ? palette.foreground : Colors.white;
    final soft = light ? palette.mutedForeground : const Color(0xA8FFFFFF);
    final accent = palette.accent;
    final error = palette.error;
    final track = light ? const Color(0x1A000000) : const Color(0x2EFFFFFF);
    final mark = toast.tone == ToastTone.error ? error : accent;
    final undo = toast.onUndo != null;
    final action = undo ? context.t('toast.undo') : toast.action;
    return Semantics(
      liveRegion: true,
      child: Container(
        constraints: const BoxConstraints(minHeight: 60),
        padding: const EdgeInsets.fromLTRB(10, 9, 8, 9),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
              color: light ? const Color(0x99000000) : const Color(0x80280A28),
              blurRadius: 40,
              offset: const Offset(0, 18),
              spreadRadius: -13,
            ),
          ],
        ),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Row(
              children: [
                if (toast.cover case final cover?)
                  SizedBox.square(
                    dimension: 42,
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        Artwork(url: cover, size: 42, radius: 10),
                        if (toast.badge)
                          Positioned(
                            right: -5,
                            bottom: -5,
                            child: Container(
                              width: 20,
                              height: 20,
                              decoration: BoxDecoration(
                                color: mark,
                                shape: BoxShape.circle,
                                border: Border.all(color: background, width: 2.5),
                              ),
                              alignment: Alignment.center,
                              child: CauceIcon(
                                toast.tone == ToastTone.error ? CauceGlyph.close : CauceGlyph.check,
                                size: 10,
                                color: Colors.white,
                                weight: 3,
                              ),
                            ),
                          ),
                      ],
                    ),
                  )
                else
                  Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      color: switch (toast.tone) {
                        ToastTone.error => error.withValues(alpha: 0.14),
                        ToastTone.info => ink.withValues(alpha: 0.08),
                        ToastTone.ok => accent.withValues(alpha: 0.14),
                      },
                      shape: BoxShape.circle,
                    ),
                    alignment: Alignment.center,
                    child: CauceIcon(
                      toast.glyph ?? (toast.tone == ToastTone.error ? CauceGlyph.alert : CauceGlyph.check),
                      size: 21,
                      color: toast.tone == ToastTone.info ? ink : mark,
                      weight: 2.2,
                    ),
                  ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Two lines: an error explained in a sentence must be read whole.
                      Text(
                        toast.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 15, height: 1.25, fontWeight: FontWeight.w600, color: ink),
                      ),
                      if (toast.detail case final detail?)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            detail,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 13, height: 1.3, color: soft),
                          ),
                        ),
                    ],
                  ),
                ),
                if (undo)
                  Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: TweenAnimationBuilder<double>(
                      tween: Tween(begin: 1, end: 0),
                      duration: toast.time,
                      builder: (context, left, _) => SizedBox.square(
                        dimension: 22,
                        child: CircularProgressIndicator(
                          value: left,
                          strokeWidth: 2.5,
                          strokeCap: StrokeCap.round,
                          color: accent,
                          backgroundColor: track,
                        ),
                      ),
                    ),
                  ),
                if (action != null)
                  Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: Pressable(
                      scale: 0.94,
                      onTap: () {
                        if (undo) {
                          toasts.undo();
                        } else {
                          toasts.dismiss();
                          toast.onAction?.call();
                        }
                      },
                      child: Container(
                        height: 40,
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        decoration: BoxDecoration(
                          color: mark.withValues(alpha: light ? 0.1 : 0.16),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        alignment: Alignment.center,
                        child: Text(
                          action,
                          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: mark),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            if (toast.progress case final progress?)
              Positioned(
                left: 6,
                right: 6,
                bottom: -4,
                child: ValueListenableBuilder(
                  valueListenable: progress,
                  builder: (context, value, _) => ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: LinearProgressIndicator(value: value, minHeight: 3, color: accent, backgroundColor: track),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
