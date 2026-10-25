import 'package:flutter/material.dart';

import '../features/accounts/view_models/accounts_view_model.dart';
import 'app_prefs.dart';
import 'icons.dart';
import 'l10n.dart';
import 'motion.dart';
import 'theme.dart';
import 'tint_scope.dart';
import 'widgets.dart';

/// The service a tab shows, as a round avatar in its brand colour with its letters. A tap
/// unfolds the connected ones in a row under it to pick another.
class ProviderAvatar extends StatelessWidget {
  const ProviderAvatar({super.key, required this.services, required this.selected, required this.onSelected});

  final List<StreamingService> services;
  final String selected;
  final ValueChanged<String> onSelected;

  Future<void> _open(BuildContext context) async {
    final box = context.findRenderObject()! as RenderBox;
    final navigator = Navigator.of(context, rootNavigator: true);
    final overlay = navigator.overlay!.context.findRenderObject()! as RenderBox;
    tick();
    final picked = await navigator.push(
      _ProviderMenu(
        anchor: box.localToGlobal(Offset.zero, ancestor: overlay) & box.size,
        tint: TintScope.of(context),
        services: services,
        selected: selected,
      ),
    );
    if (picked != null && picked != selected) {
      tick();
      onSelected(picked);
    }
  }

  @override
  Widget build(BuildContext context) {
    final name = services.where((service) => service.slug == selected).firstOrNull?.name ?? selected;
    return Semantics(
      button: services.length > 1,
      label: name,
      child: Pressable(
        scale: 0.9,
        onTap: services.length > 1 ? () => _open(context) : null,
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 220),
          transitionBuilder: (child, animation) => ScaleTransition(
            scale: Tween(begin: 0.6, end: 1.0).animate(animation),
            child: FadeTransition(opacity: animation, child: child),
          ),
          child: _Circle(key: ValueKey(selected), slug: selected, size: 38),
        ),
      ),
    );
  }
}

/// A provider as a circle of its brand colour with its letters.
class _Circle extends StatelessWidget {
  const _Circle({super.key, required this.slug, required this.size, this.ring = false});

  final String slug;
  final double size;

  /// Marks the one in use.
  final bool ring;

  @override
  Widget build(BuildContext context) {
    final brand = brandOf(slug);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: brand.color,
        shape: BoxShape.circle,
        border: ring ? Border.all(color: Colors.white, width: 2.5) : null,
        boxShadow: const [BoxShadow(color: Color(0x40000000), blurRadius: 10, offset: Offset(0, 3))],
      ),
      alignment: Alignment.center,
      child: Text(
        brand.letters,
        style: TextStyle(
          fontFamily: displayFont,
          fontSize: size * 0.36,
          fontWeight: FontWeight.w700,
          color: const Color(0xE6140A14),
        ),
      ),
    );
  }
}

/// The connected providers in a row under the avatar: the card unfolds from the avatar on the
/// vivid spring and the circles arrive one after another from its side.
class _ProviderMenu extends PopupRoute<String> {
  _ProviderMenu({required this.anchor, required this.tint, required this.services, required this.selected});

  final Rect anchor;
  final Tint tint;
  final List<StreamingService> services;
  final String selected;

  @override
  Color? get barrierColor => Colors.black.withValues(alpha: 0.25);

  @override
  bool get barrierDismissible => true;

  @override
  String? get barrierLabel => 'Dismiss';

  @override
  Duration get transitionDuration => const Duration(milliseconds: 420);

  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 180);

  @override
  Widget buildPage(BuildContext context, Animation<double> animation, Animation<double> secondaryAnimation) {
    final screen = MediaQuery.sizeOf(context);
    return Stack(
      children: [
        Positioned(
          right: screen.width - anchor.right,
          top: anchor.bottom + 10,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: screen.width - 2 * CauceMetrics.gutter),
            child: Material(
              type: MaterialType.transparency,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: CauceColors.light ? CauceColors.sheet : tint.shade(0.24, 0.04),
                  borderRadius: BorderRadius.circular(26),
                  border: Border.all(color: CauceColors.foreground.withValues(alpha: 0.06), width: 0.5),
                  boxShadow: const [BoxShadow(color: Color(0x66000000), blurRadius: 30, offset: Offset(0, 12))],
                ),
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final (index, service) in services.indexed)
                        _arrive(
                          animation,
                          // The one nearest the avatar comes first.
                          services.length - 1 - index,
                          GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () => Navigator.of(context).pop(service.slug),
                            child: SizedBox(
                              width: 72,
                              child: Column(
                                children: [
                                  _Circle(slug: service.slug, size: 46, ring: service.slug == selected),
                                  const SizedBox(height: 7),
                                  Text(
                                    service.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: service.slug == selected ? FontWeight.w700 : FontWeight.w500,
                                      color: service.slug == selected
                                          ? CauceColors.foreground
                                          : CauceColors.mutedForeground,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// Item `order` slides in from the avatar's side 40 ms after the one before it.
  Widget _arrive(Animation<double> animation, int order, Widget child) {
    final start = (order * 0.08).clamp(0.0, 0.5);
    final step = CurvedAnimation(
      parent: animation,
      curve: Interval(start, start + 0.5, curve: CauceCurves.exit),
    );
    return AnimatedBuilder(
      animation: step,
      builder: (context, child) => Opacity(
        opacity: step.value,
        child: Transform.translate(offset: Offset(18 * (1 - step.value), 0), child: child),
      ),
      child: child,
    );
  }

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final grow = CurvedAnimation(parent: animation, curve: CauceCurves.vivid, reverseCurve: CauceCurves.exit);
    return FadeTransition(
      opacity: CurvedAnimation(parent: animation, curve: const Interval(0, 0.4)),
      child: AnimatedBuilder(
        animation: grow,
        builder: (context, child) => Transform.scale(
          scale: 0.6 + 0.4 * grow.value,
          alignment: Alignment.topLeft,
          origin: anchor.center,
          child: child,
        ),
        child: child,
      ),
    );
  }
}

/// What a tab shows before any service is connected.
class NothingConnected extends StatelessWidget {
  const NothingConnected({super.key, required this.message, required this.onAccounts});

  final String message;
  final VoidCallback onAccounts;

  @override
  Widget build(BuildContext context) {
    return EmptyState(
      glyph: CauceGlyph.plug,
      badge: true,
      title: message,
      actions: [FilledButton(onPressed: onAccounts, child: Text(context.t('common.connect')))],
    );
  }
}

/// Room left under scrolling content for the dock.
const bottomChromeInset = 170.0;
