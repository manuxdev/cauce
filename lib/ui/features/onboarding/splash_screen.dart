import 'package:flutter/material.dart';

import '../../core/theme.dart';

/// The name rising in letter by letter, its accent full stop dropping in after and then
/// breathing, with a small spinner low on the screen while the accounts come back.
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> with TickerProviderStateMixin {
  static const _name = 'cauce';

  late final _entrance = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100))
    ..forward().whenComplete(() {
      if (mounted) _breath.repeat(reverse: true);
    });
  late final _breath = AnimationController(vsync: this, duration: const Duration(milliseconds: 900));

  @override
  void dispose() {
    _entrance.dispose();
    _breath.dispose();
    super.dispose();
  }

  /// Each letter's share of the entrance, each starting a little after the one before.
  late final _letters = [
    for (var index = 0; index < _name.length; index++)
      CurvedAnimation(
        parent: _entrance,
        curve: Interval(index * 0.09, 0.45 + index * 0.09, curve: Curves.easeOutCubic),
      ),
  ];

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
      fontFamily: displayFont,
      fontSize: 52,
      fontWeight: FontWeight.w700,
      letterSpacing: -1.5,
      color: CauceColors.foreground,
      decoration: TextDecoration.none,
    );
    final dot = CurvedAnimation(
      parent: _entrance,
      curve: const Interval(0.6, 1, curve: Curves.elasticOut),
    );
    return ColoredBox(
      color: CauceColors.background,
      child: DefaultTextStyle(
        style: style,
        child: Stack(
          children: [
            Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  for (var index = 0; index < _name.length; index++)
                    AnimatedBuilder(
                      animation: _letters[index],
                      builder: (context, child) {
                        final t = _letters[index].value;
                        return Opacity(
                          opacity: t,
                          child: Transform.translate(offset: Offset(0, 18 * (1 - t)), child: child),
                        );
                      },
                      child: Text(_name[index]),
                    ),
                  AnimatedBuilder(
                    animation: Listenable.merge([dot, _breath]),
                    builder: (context, child) => Transform.translate(
                      offset: Offset(0, -40 * (1 - dot.value.clamp(0.0, 1.0))),
                      child: Opacity(opacity: dot.value.clamp(0.0, 1.0) * (1 - 0.35 * _breath.value), child: child),
                    ),
                    child: Text('.', style: TextStyle(color: CauceColors.accent)),
                  ),
                ],
              ),
            ),
            Align(
              alignment: const Alignment(0, 0.72),
              child: FadeTransition(
                opacity: CurvedAnimation(parent: _entrance, curve: const Interval(0.7, 1)),
                child: SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(strokeWidth: 2, color: CauceColors.faintForeground),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
