import 'dart:ui';

import 'package:flutter/material.dart';

import 'icons.dart';
import 'motion.dart';
import 'theme.dart';
import 'tint_scope.dart';

class TabItem {
  const TabItem(this.glyph, this.label);

  final CauceGlyph glyph;
  final String label;
}

/// The frosted dock at the bottom: [top] (the mini player) over a row of tabs, the selected one
/// an accent pill wide enough for its label.
class Dock extends StatelessWidget {
  const Dock({super.key, required this.top, required this.items, required this.selected, required this.onSelected});

  final Widget top;
  final List<TabItem> items;
  final int selected;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    final tint = TintScope.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(30),
          boxShadow: const [
            BoxShadow(color: Color(0x99190005), blurRadius: 44, offset: Offset(0, 20), spreadRadius: -14),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(30),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: tint.dock,
                borderRadius: BorderRadius.circular(30),
                border: Border.all(color: CauceColors.foreground.withValues(alpha: 0.12), width: 0.5),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  top,
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: _Tabs(items: items, selected: selected, onSelected: onSelected),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Tabs extends StatelessWidget {
  const _Tabs({required this.items, required this.selected, required this.onSelected});

  final List<TabItem> items;
  final int selected;
  final ValueChanged<int> onSelected;

  static const _gap = 4.0;
  static const _height = 46.0;

  /// The selected tab takes this many shares of the row to the others' one.
  static const _wide = 2.1;

  @override
  Widget build(BuildContext context) {
    const duration = Duration(milliseconds: 320);
    const curve = CauceCurves.vivid;
    return LayoutBuilder(
      builder: (context, constraints) {
        final unit = (constraints.maxWidth - _gap * (items.length - 1)) / (items.length - 1 + _wide);
        double width(int index) => index == selected ? unit * _wide : unit;
        double left(int index) => [for (var i = 0; i < index; i++) width(i) + _gap].fold(0.0, (a, b) => a + b);
        return SizedBox(
          height: _height,
          child: Stack(
            children: [
              AnimatedPositioned(
                duration: duration,
                curve: curve,
                left: left(selected),
                width: width(selected),
                top: 0,
                bottom: 0,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: CauceColors.accent,
                    borderRadius: BorderRadius.all(Radius.circular(23)),
                  ),
                ),
              ),
              for (final (index, item) in items.indexed)
                AnimatedPositioned(
                  duration: duration,
                  curve: curve,
                  left: left(index),
                  width: width(index),
                  top: 0,
                  bottom: 0,
                  child: _Tab(item: item, selected: index == selected, onTap: () => onSelected(index)),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _Tab extends StatelessWidget {
  const _Tab({required this.item, required this.selected, required this.onTap});

  final TabItem item;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = selected ? CauceColors.onAccent : CauceColors.mutedForeground;
    return Semantics(
      selected: selected,
      button: true,
      label: item.label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CauceIcon(item.glyph, size: 22, color: color, weight: selected ? 2.2 : 1.9),
            if (selected)
              Flexible(
                child: TweenAnimationBuilder<double>(
                  tween: Tween(begin: 0, end: 1),
                  duration: const Duration(milliseconds: 120),
                  builder: (context, opacity, child) => Opacity(opacity: opacity, child: child),
                  child: Padding(
                    padding: const EdgeInsets.only(left: 7),
                    child: Text(
                      item.label,
                      maxLines: 1,
                      overflow: TextOverflow.clip,
                      softWrap: false,
                      style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: color, letterSpacing: -0.14),
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
