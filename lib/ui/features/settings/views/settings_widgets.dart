import 'package:flutter/material.dart';

import '../../../core/icons.dart';
import '../../../core/l10n.dart';
import '../../../core/motion.dart';
import '../../../core/service_picker.dart';
import '../../../core/theme.dart';
import '../../../core/tint_scope.dart';
import '../../../core/widgets.dart';

/// The cards the settings rows sit on.
Color get _group => CauceColors.group;

/// A settings page on the neutral dark: the tab's large title, or, pushed, a back link and the
/// title centered, over grouped rows clear of the dock.
class SettingsPage extends StatelessWidget {
  const SettingsPage({
    super.key,
    required this.title,
    required this.children,
    this.root = false,
    this.back,
    this.backLabel = true,
    this.action,
  });

  final String title;
  final List<Widget> children;

  /// What the back link reads; the settings tab's name by default.
  final String? back;

  /// Whether the back link reads at all, or is the chevron alone.
  final bool backLabel;

  /// At the bar's end, such as a reset link.
  final Widget? action;

  /// The tab itself: a large title and no way back.
  final bool root;

  static const _titleStyle = TextStyle(fontSize: 17, fontWeight: FontWeight.w600);
  static const _backStyle = TextStyle(fontSize: 17);

  /// How wide [text] sets in [style] at the reader's text size.
  static double _width(BuildContext context, String text, TextStyle style) => (TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: TextDirection.ltr,
    textScaler: MediaQuery.textScalerOf(context),
    maxLines: 1,
  )..layout()).width;

  Widget _back(BuildContext context, {bool label = true}) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => Navigator.of(context).maybePop(),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(0, 10, 8, 10),
        child: Row(
          children: [
            CauceIcon(CauceGlyph.chevronLeft, size: 22, color: CauceColors.accent, weight: 2.4),
            if (label) ...[
              const SizedBox(width: 2),
              Text(back ?? context.t('tab.settings'), style: _backStyle.copyWith(color: CauceColors.accent)),
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.paddingOf(context).top;
    return TintScope(
      tint: Tint.neutral,
      child: ColoredBox(
        color: CauceColors.settingsBackground,
        child: Scaffold(
          body: ListView(
            padding: EdgeInsets.fromLTRB(16, top + (root ? 8 : 0), 16, bottomChromeInset),
            children: [
              if (root)
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 8, 4, 18),
                  child: Text(title, style: CauceText.largeTitle),
                )
              else
                SizedBox(
                  height: 52,
                  // The back link, then the title centred in what is left; the far side holds the
                  // action, or keeps the link's room. As on iOS, a title too long to sit between
                  // the links drops the link's label and keeps its own size.
                  child: LayoutBuilder(
                    builder: (context, box) {
                      final link = 22 + 2 + 8 + _width(context, back ?? context.t('tab.settings'), _backStyle);
                      final label = backLabel && _width(context, title, _titleStyle) <= box.maxWidth - 2 * link;
                      return Row(
                        children: [
                          _back(context, label: label),
                          Expanded(
                            child: Text(
                              title,
                              textAlign: TextAlign.center,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: _titleStyle,
                            ),
                          ),
                          action ??
                              Visibility(
                                visible: false,
                                maintainSize: true,
                                maintainAnimation: true,
                                maintainState: true,
                                child: _back(context, label: label),
                              ),
                        ],
                      );
                    },
                  ),
                ),
              ...children,
            ],
          ),
        ),
      ),
    );
  }
}

/// Rows under a small heading, on one rounded card.
class SettingsGroup extends StatelessWidget {
  const SettingsGroup({super.key, this.title, this.footer, required this.children});

  final String? title;
  final String? footer;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 22),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (title case final title?) Overline(title, padding: const EdgeInsets.fromLTRB(16, 4, 16, 8)),
          ClipRRect(
            borderRadius: BorderRadius.circular(CauceMetrics.groupRadius),
            child: Material(
              color: _group,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final (index, child) in children.indexed) ...[
                    if (index > 0) Divider(height: 0.5, thickness: 0.5, indent: 16, color: CauceColors.border),
                    child,
                  ],
                ],
              ),
            ),
          ),
          if (footer case final footer?)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text(footer, style: CauceText.caption),
            ),
        ],
      ),
    );
  }
}

/// A row that opens a page or picks something, with a glyph on a coloured square, and its
/// current value quietly at the end.
class SettingsRow extends StatelessWidget {
  const SettingsRow({
    super.key,
    required this.title,
    this.glyph,
    this.leading,
    this.color = const Color(0xFF6E6670),
    this.subtitle,
    this.value,
    this.trailing,
    this.onTap,
    this.enabled = true,
    this.titleColor,
  });

  final String title;
  final CauceGlyph? glyph;

  /// Drawn where the glyph goes, for a row that leads with something else.
  final Widget? leading;

  /// The square behind the glyph.
  final Color color;
  final String? subtitle;
  final String? value;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool enabled;

  /// For a row that is only an action, its colour.
  final Color? titleColor;

  @override
  Widget build(BuildContext context) {
    final chevron = trailing == null && onTap != null;
    return Opacity(
      opacity: enabled ? 1 : 0.45,
      child: InkWell(
        onTap: enabled ? onTap : null,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 52),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 8, 12, 8),
            child: Row(
              children: [
                if (glyph case final glyph?) ...[
                  Container(
                    width: 30,
                    height: 30,
                    decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(8)),
                    alignment: Alignment.center,
                    child: CauceIcon(glyph, size: 18, color: Colors.white, weight: 2),
                  ),
                  const SizedBox(width: 13),
                ] else if (leading case final leading?) ...[
                  leading,
                  const SizedBox(width: 13),
                ] else
                  const SizedBox(width: 2),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: TextStyle(fontSize: 16.5, color: titleColor)),
                      if (subtitle case final subtitle?)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(subtitle, style: TextStyle(fontSize: 13, color: CauceColors.mutedForeground)),
                        ),
                    ],
                  ),
                ),
                if (value case final value?)
                  // Kept to part of the row, so a long value is cut rather than the title, which
                  // says what the row is.
                  ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.42),
                    child: Padding(
                      padding: const EdgeInsets.only(left: 10),
                      child: Text(
                        value,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 16, color: CauceColors.mutedForeground),
                      ),
                    ),
                  ),
                ?trailing,
                if (chevron)
                  Padding(
                    padding: EdgeInsets.only(left: 8),
                    child: CauceIcon(
                      CauceGlyph.chevronRight,
                      size: 16,
                      color: CauceColors.faintForeground,
                      weight: 2.2,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A row with a switch.
class SettingsSwitch extends StatelessWidget {
  const SettingsSwitch({super.key, required this.title, this.subtitle, required this.value, required this.onChanged});

  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return SettingsRow(
      title: title,
      subtitle: subtitle,
      onTap: () => onChanged(!value),
      trailing: Switch.adaptive(value: value, onChanged: onChanged, activeTrackColor: CauceColors.accent),
    );
  }
}

/// The accent check at the end of the picked row.
Widget get pickedMark => CauceIcon(CauceGlyph.check, size: 18, color: CauceColors.accent, weight: 2.4);

/// Bytes as a listener reads them.
String formatBytes(int bytes) {
  const units = ['B', 'KB', 'MB', 'GB'];
  var size = bytes.toDouble();
  var unit = 0;
  while (size >= 1024 && unit < units.length - 1) {
    size /= 1024;
    unit++;
  }
  return '${size.toStringAsFixed(unit < 2 ? 0 : 1)} ${units[unit]}';
}

/// A sheet of choices, the current one checked.
Future<T?> pickSetting<T>(BuildContext context, String title, List<T> options, T current, String Function(T) name) =>
    showModalBottomSheet<T>(
      context: context,
      useRootNavigator: true,
      sheetAnimationStyle: sheetAnimation,
      builder: (sheet) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
          child: SettingsGroup(
            title: title,
            children: [
              for (final option in options)
                SettingsRow(
                  title: name(option),
                  trailing: option == current ? pickedMark : null,
                  onTap: () => Navigator.of(sheet).pop(option),
                ),
            ],
          ),
        ),
      ),
    );

/// Options side by side on one track, the picked one raised.
class SettingsSegmented extends StatelessWidget {
  const SettingsSegmented({super.key, required this.options, required this.selected, required this.onSelected});

  final List<String> options;
  final int selected;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 40,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(color: CauceColors.group, borderRadius: BorderRadius.circular(11)),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth / options.length;
          return Stack(
            children: [
              AnimatedPositioned(
                duration: const Duration(milliseconds: 260),
                curve: CauceCurves.standard,
                left: width * selected,
                top: 0,
                bottom: 0,
                width: width,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: CauceColors.light ? Colors.white : CauceColors.raised,
                    borderRadius: BorderRadius.circular(8),
                    boxShadow: CauceColors.light
                        ? const [BoxShadow(color: Color(0x1F000000), blurRadius: 6, offset: Offset(0, 2))]
                        : null,
                  ),
                ),
              ),
              Row(
                children: [
                  for (final (index, option) in options.indexed)
                    Expanded(
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => onSelected(index),
                        child: Center(
                          child: Text(
                            option,
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: index == selected ? FontWeight.w600 : FontWeight.w400,
                              color: index == selected ? CauceColors.foreground : CauceColors.mutedForeground,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}
