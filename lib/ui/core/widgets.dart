import 'package:flutter/material.dart';

import 'icons.dart';
import 'theme.dart';
import 'tint.dart';
import 'tint_scope.dart';

/// A tab's big title, the way the design opens every tab.
class PageTitle extends StatelessWidget {
  const PageTitle(this.text, {super.key, this.trailing});

  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(CauceMetrics.gutter, 8, CauceMetrics.gutter, 14),
      child: Row(
        children: [
          Expanded(child: Text(text, style: CauceText.largeTitle)),
          ?trailing,
        ],
      ),
    );
  }
}

/// A section's title, with an accent action at its end such as "Play" or "Clear".
class SectionHeader extends StatelessWidget {
  const SectionHeader(this.title, {super.key, this.action, this.onAction, this.count});

  final String title;
  final String? action;
  final VoidCallback? onAction;

  /// A quiet number at the end, such as how many songs there are.
  final int? count;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(CauceMetrics.gutter, 22, CauceMetrics.gutter, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Expanded(child: Text(title, style: CauceText.section)),
          if (count != null) Text('$count', style: TextStyle(fontSize: 14, color: CauceColors.mutedForeground)),
          if (action != null)
            GestureDetector(
              onTap: onAction,
              child: Text(
                action!,
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: CauceColors.accent),
              ),
            ),
        ],
      ),
    );
  }
}

/// The caps label over a list or a group of settings.
class Overline extends StatelessWidget {
  const Overline(this.text, {super.key, this.padding});

  final String text;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding ?? const EdgeInsets.fromLTRB(CauceMetrics.gutter, 18, CauceMetrics.gutter, 8),
      child: Text(text.toUpperCase(), style: CauceText.overline),
    );
  }
}

/// A rounded pill: white when picked, tinted otherwise. A dot can mark a provider's colour and a
/// chevron that it opens a menu.
class Pill extends StatelessWidget {
  const Pill({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.dot,
    this.glyph,
    this.chevron = false,
  });

  final String label;
  final bool selected;
  final VoidCallback? onTap;
  final Color? dot;
  final CauceGlyph? glyph;
  final bool chevron;

  @override
  Widget build(BuildContext context) {
    final ink = selected ? CauceColors.background : CauceColors.foreground;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        height: 34,
        padding: EdgeInsets.only(left: dot == null && glyph == null ? 14 : 12, right: chevron ? 10 : 14),
        decoration: BoxDecoration(
          color: selected
              ? (CauceColors.light ? CauceColors.foreground : const Color(0xFFFBF2F6))
              : TintScope.of(context).surface,
          borderRadius: BorderRadius.circular(17),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (dot != null) ...[
              Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
              ),
              const SizedBox(width: 8),
            ],
            if (glyph != null) ...[CauceIcon(glyph!, size: 15, color: ink, weight: 2.2), const SizedBox(width: 6)],
            Text(
              label,
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: ink, letterSpacing: -0.1),
            ),
            if (chevron) ...[
              const SizedBox(width: 4),
              CauceIcon(CauceGlyph.chevronDown, size: 15, color: ink, weight: 2.4),
            ],
          ],
        ),
      ),
    );
  }
}

/// A pill button on the tinted surface, the quiet partner of the accent [FilledButton].
class SoftButton extends StatelessWidget {
  const SoftButton({super.key, required this.label, required this.onPressed, this.glyph});

  final String label;
  final VoidCallback? onPressed;
  final CauceGlyph? glyph;

  @override
  Widget build(BuildContext context) {
    return FilledButton(
      onPressed: onPressed,
      style: FilledButton.styleFrom(
        backgroundColor: TintScope.of(context).surface,
        foregroundColor: CauceColors.foreground,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (glyph != null) ...[CauceIcon(glyph!, size: 18, weight: 2.1), const SizedBox(width: 8)],
          Flexible(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis)),
        ],
      ),
    );
  }
}

/// An accent pill button with an icon, such as "Play" on an album.
class AccentButton extends StatelessWidget {
  const AccentButton({super.key, required this.label, required this.onPressed, this.glyph = CauceGlyph.play});

  final String label;
  final VoidCallback? onPressed;
  final CauceGlyph glyph;

  @override
  Widget build(BuildContext context) {
    return FilledButton(
      onPressed: onPressed,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          CauceIcon(glyph, size: 16, color: CauceColors.onAccent),
          const SizedBox(width: 8),
          Flexible(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis)),
        ],
      ),
    );
  }
}

/// What a screen shows instead of content: a mark, a title, a line of help and what to do.
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.glyph,
    required this.title,
    this.message,
    this.actions = const [],
    this.badge = false,
    this.danger = false,
  });

  final CauceGlyph glyph;
  final String title;
  final String? message;
  final List<Widget> actions;

  /// Puts the mark in a round tinted badge.
  final bool badge;

  /// Draws the badge in the error colour, for failures.
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final tint = TintScope.of(context);
    final icon = CauceIcon(
      glyph,
      size: badge ? 24 : 34,
      color: danger ? CauceColors.error : CauceColors.mutedForeground,
      weight: 2,
    );
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 36),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (badge)
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: danger ? CauceColors.error.withValues(alpha: 0.2) : tint.surface,
                  shape: BoxShape.circle,
                ),
                alignment: Alignment.center,
                child: icon,
              )
            else
              icon,
            const SizedBox(height: 18),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontFamily: displayFont,
                fontSize: 21,
                height: 1.25,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.3,
              ),
            ),
            if (message != null) ...[
              const SizedBox(height: 10),
              Text(
                message!,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 15, height: 1.45, color: CauceColors.mutedForeground),
              ),
            ],
            if (actions.isNotEmpty) ...[
              const SizedBox(height: 22),
              Wrap(spacing: 10, runSpacing: 10, alignment: WrapAlignment.center, children: actions),
            ],
          ],
        ),
      ),
    );
  }
}

/// A stable hue for [text], so a name without a picture always gets the same colour.
double hueFor(String text) => (text.hashCode % 360).abs().toDouble();

/// A name's first letter on a cover-coloured square or circle, for things without a picture.
class InitialAvatar extends StatelessWidget {
  const InitialAvatar({super.key, required this.name, this.size = 48, this.round = true});

  final String name;
  final double size;
  final bool round;

  @override
  Widget build(BuildContext context) {
    final hue = hueFor(name);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: oklch(0.64, 0.13, hue),
        shape: round ? BoxShape.circle : BoxShape.rectangle,
        borderRadius: round ? null : BorderRadius.circular(8),
      ),
      alignment: Alignment.center,
      child: Text(
        name.isEmpty ? '?' : name.characters.first.toUpperCase(),
        style: TextStyle(
          fontFamily: displayFont,
          fontSize: size * 0.36,
          fontWeight: FontWeight.w700,
          color: oklch(0.3, 0.08, hue),
        ),
      ),
    );
  }
}

/// A provider's brand colour and the two letters on its badge.
({Color color, String letters}) brandOf(String slug) => switch (slug) {
  'subsonic' => (color: const Color(0xFFEFA02E), letters: 'SS'),
  _ => (color: CauceColors.accent, letters: slug.isEmpty ? '?' : slug.substring(0, 2).toUpperCase()),
};

/// A provider's square badge with its letters.
class BrandBadge extends StatelessWidget {
  const BrandBadge({super.key, required this.slug, this.size = 36});

  final String slug;
  final double size;

  @override
  Widget build(BuildContext context) {
    final brand = brandOf(slug);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: brand.color, borderRadius: BorderRadius.circular(size * 0.28)),
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

/// The name in its own type, with the accent full stop.
class Wordmark extends StatelessWidget {
  const Wordmark({super.key, this.size = 22});

  final double size;

  @override
  Widget build(BuildContext context) {
    return Text.rich(
      TextSpan(
        text: 'cauce',
        children: [
          TextSpan(
            text: '.',
            style: TextStyle(color: CauceColors.accent),
          ),
        ],
      ),
      style: TextStyle(fontFamily: displayFont, fontSize: size, fontWeight: FontWeight.w700, letterSpacing: -0.5),
    );
  }
}
