import 'package:flutter/material.dart';

import 'icons.dart';
import 'motion.dart';
import 'theme.dart';
import 'tint_scope.dart';

/// One row of a [showDropdown] menu.
class DropdownItem<T> {
  const DropdownItem({
    required this.value,
    this.leading,
    required this.title,
    this.subtitle,
    this.subtitleColor,
    this.color,
    this.selected = false,
  });

  final T value;
  final Widget? leading;
  final String title;
  final String? subtitle;
  final Color? subtitleColor;

  /// The title's colour, for an action such as "Connect another".
  final Color? color;

  /// Marked with a check.
  final bool selected;
}

/// The outlined plus square an action row such as "Connect another" leads with.
class DropdownPlus extends StatelessWidget {
  const DropdownPlus({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 30,
      height: 30,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: CauceColors.accent.withValues(alpha: 0.6)),
      ),
      alignment: Alignment.center,
      child: CauceIcon(CauceGlyph.plus, size: 16, color: CauceColors.accent, weight: 2.2),
    );
  }
}

/// The app's dropdown: a tinted card under [anchor] listing [items], then [footer] past a rule.
/// Resolves to the value of the row tapped, or null when dismissed.
Future<T?> showDropdown<T>(
  BuildContext anchor, {
  required List<DropdownItem<T>> items,
  List<DropdownItem<T>> footer = const [],
}) {
  final box = anchor.findRenderObject()! as RenderBox;
  final navigator = Navigator.of(anchor, rootNavigator: true);
  final overlay = navigator.overlay!.context.findRenderObject()! as RenderBox;
  final rect = box.localToGlobal(Offset.zero, ancestor: overlay) & box.size;
  return navigator.push(
    _DropdownRoute<T>(
      anchor: rect,
      tint: TintScope.of(anchor),
      items: items,
      footer: footer,
      barrierLabel: MaterialLocalizations.of(anchor).modalBarrierDismissLabel,
    ),
  );
}

class _DropdownRoute<T> extends PopupRoute<T> {
  _DropdownRoute({
    required this.anchor,
    required this.tint,
    required this.items,
    required this.footer,
    required this.barrierLabel,
  });

  final Rect anchor;
  final Tint tint;
  final List<DropdownItem<T>> items;
  final List<DropdownItem<T>> footer;

  @override
  final String barrierLabel;

  @override
  Color? get barrierColor => null;

  @override
  bool get barrierDismissible => true;

  @override
  Duration get transitionDuration => const Duration(milliseconds: 260);

  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 160);

  @override
  Widget buildPage(BuildContext context, Animation<double> animation, Animation<double> secondaryAnimation) {
    final padding = MediaQuery.paddingOf(context);
    return CustomSingleChildLayout(
      delegate: _Placement(anchor, padding),
      child: Material(
        type: MaterialType.transparency,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: CauceColors.light ? CauceColors.sheet : tint.shade(0.24, 0.04),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: CauceColors.foreground.withValues(alpha: 0.06), width: 0.5),
            boxShadow: const [BoxShadow(color: Color(0x66000000), blurRadius: 30, offset: Offset(0, 12))],
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final item in items) _row(context, item),
                if (footer.isNotEmpty) ...[
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                    child: Divider(height: 1, thickness: 0.5, color: CauceColors.foreground.withValues(alpha: 0.1)),
                  ),
                  for (final item in footer) _row(context, item),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _row(BuildContext context, DropdownItem<T> item) {
    return InkWell(
      onTap: () => Navigator.of(context).pop(item.value),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        child: Row(
          children: [
            if (item.leading case final leading?) ...[
              SizedBox(width: 30, height: 30, child: Center(child: leading)),
              const SizedBox(width: 12),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500, color: item.color),
                  ),
                  if (item.subtitle case final subtitle?)
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 13, color: item.subtitleColor ?? CauceColors.mutedForeground),
                    ),
                ],
              ),
            ),
            if (item.selected) CauceIcon(CauceGlyph.check, size: 18, color: CauceColors.accent, weight: 2.2),
          ],
        ),
      ),
    );
  }

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    // Unfolds from under the trigger on the vivid spring, and fades away on close.
    final grow = CurvedAnimation(parent: animation, curve: CauceCurves.vivid, reverseCurve: CauceCurves.exit);
    return FadeTransition(
      opacity: CurvedAnimation(parent: animation, curve: const Interval(0, 0.5)),
      child: AnimatedBuilder(
        animation: grow,
        builder: (context, child) => Transform.scale(
          scale: 0.92 + 0.08 * grow.value,
          alignment: Alignment.topLeft,
          origin: anchor.center,
          child: child,
        ),
        child: child,
      ),
    );
  }
}

/// Under the trigger, lined up with it on the left half of the screen and centred under it
/// elsewhere; above it when there is no room below.
class _Placement extends SingleChildLayoutDelegate {
  _Placement(this.anchor, this.padding);

  final Rect anchor;
  final EdgeInsets padding;

  static const _width = 290.0;
  static const _gap = 8.0;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) => BoxConstraints(
    minWidth: _width,
    maxWidth: _width,
    maxHeight: constraints.maxHeight - padding.vertical - 2 * _gap,
  );

  @override
  Offset getPositionForChild(Size size, Size child) {
    final x = anchor.center.dx < size.width / 3 ? anchor.left : anchor.center.dx - child.width / 2;
    final below = anchor.bottom + _gap;
    final fits = below + child.height <= size.height - padding.bottom - _gap;
    final y = fits ? below : anchor.top - _gap - child.height;
    return Offset(
      x.clamp(CauceMetrics.gutter, size.width - child.width - CauceMetrics.gutter),
      y.clamp(padding.top + _gap, size.height - child.height - _gap),
    );
  }

  @override
  bool shouldRelayout(_Placement old) => old.anchor != anchor || old.padding != padding;
}
