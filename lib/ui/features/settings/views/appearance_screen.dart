import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/app_prefs.dart';
import '../../../core/l10n.dart';
import '../../../core/motion.dart';
import '../../../core/theme.dart';
import '../../../core/widgets.dart';
import 'player_design_screen.dart';
import 'settings_widgets.dart';
import '../../../core/toast.dart';

/// Switches the home screen icon; the night one is the app's own.
const _icons = MethodChannel('cauce/app_icon');

/// The theme, how much the cover colours the app, the accent, the app icon, the player's moving
/// background, and how lists look.
class AppearanceScreen extends StatelessWidget {
  const AppearanceScreen({super.key});

  Future<void> _setIcon(BuildContext context, AppIconChoice icon) async {
    if (icon == appPrefs.appIcon) return;
    tick();
    try {
      await _icons.invokeMethod('set', icon == AppIconChoice.night ? null : icon.name);
      appPrefs.update((prefs) => prefs.appIcon = icon);
    } on PlatformException {
      if (!context.mounted) return;
      showToast(Toast(title: context.t('appearance.iconFailed'), tone: ToastTone.error));
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: appPrefs,
      builder: (context, _) => SettingsPage(
        title: context.t('settings.appearance'),
        children: [
          SettingsGroup(
            title: context.t('appearance.theme'),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 14),
                child: Row(
                  children: [
                    for (final (index, theme) in ThemeChoice.values.indexed) ...[
                      if (index > 0) const SizedBox(width: 10),
                      Expanded(
                        child: _ThemeCard(
                          theme: theme,
                          selected: appPrefs.theme == theme,
                          onTap: () {
                            tick();
                            appPrefs.update((prefs) => prefs.theme = theme);
                          },
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(bottom: 22),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Overline(context.t('appearance.cover'), padding: const EdgeInsets.fromLTRB(16, 4, 16, 8)),
                SettingsSegmented(
                  options: [for (final option in CoverColor.values) context.t('appearance.cover.${option.name}')],
                  selected: appPrefs.coverColor.index,
                  onSelected: (index) {
                    tick();
                    appPrefs.update((prefs) => prefs.coverColor = CoverColor.values[index]);
                  },
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: Text(context.t('appearance.cover.detail'), style: CauceText.caption),
                ),
              ],
            ),
          ),
          SettingsGroup(
            title: context.t('appearance.accent'),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(6, 14, 6, 12),
                child: Row(
                  children: [
                    for (final accent in AccentChoice.values)
                      Expanded(
                        child: _Choice(
                          label: context.t('accent.${accent.name}'),
                          selected: appPrefs.accent == accent,
                          onTap: () {
                            tick();
                            appPrefs.update((prefs) => prefs.accent = accent);
                          },
                          child: _AccentDot(accent: accent),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
          SettingsGroup(
            title: context.t('appearance.icon'),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 12, 8, 12),
                child: Row(
                  children: [
                    for (final icon in AppIconChoice.values)
                      Expanded(
                        child: _Choice(
                          label: context.t('icon.${icon.name}'),
                          selected: appPrefs.appIcon == icon,
                          onTap: () => _setIcon(context, icon),
                          child: _IconPreview(icon: icon),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
          SettingsGroup(
            title: context.t('appearance.nowPlaying'),
            children: [
              SettingsRow(
                title: context.t('appearance.playerDesign'),
                value: context.t('design.${appPrefs.playerDesign.name}'),
                onTap: () =>
                    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const PlayerDesignScreen())),
              ),
            ],
          ),
          SettingsGroup(
            title: context.t('appearance.lists'),
            children: [
              SettingsSwitch(
                title: context.t('appearance.providerTag'),
                subtitle: context.t('appearance.providerTag.detail'),
                value: appPrefs.providerTag,
                onChanged: (on) => appPrefs.update((prefs) => prefs.providerTag = on),
              ),
              SettingsRow(
                title: context.t('appearance.density'),
                value: context.t('density.${appPrefs.density.name}'),
                onTap: () async {
                  final picked = await pickSetting(
                    context,
                    context.t('appearance.density'),
                    ListDensity.values,
                    appPrefs.density,
                    (density) => context.t('density.${density.name}'),
                  );
                  if (picked != null) appPrefs.update((prefs) => prefs.density = picked);
                },
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// A small page in a theme's colours: the system one split light and dark.
class _ThemeCard extends StatelessWidget {
  const _ThemeCard({required this.theme, required this.selected, required this.onTap});

  final ThemeChoice theme;
  final bool selected;
  final VoidCallback onTap;

  static const _light = Color(0xFFFFF1EF);
  static const _dark = Color(0xFF1E0B0D);

  Widget _page(bool light) => ColoredBox(
    color: light ? _light : _dark,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(10, 12, 10, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(color: const Color(0xFFD26A62), borderRadius: BorderRadius.circular(6)),
          ),
          const SizedBox(height: 8),
          _line(56, light ? const Color(0xFF2A1416) : Colors.white),
          const SizedBox(height: 5),
          _line(36, const Color(0xFF9C8A8C)),
          const Spacer(),
          Container(
            height: 20,
            decoration: BoxDecoration(color: const Color(0xFF7A2A26), borderRadius: BorderRadius.circular(10)),
          ),
        ],
      ),
    ),
  );

  static Widget _line(double width, Color color) => Container(
    width: width,
    height: 5,
    decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(3)),
  );

  @override
  Widget build(BuildContext context) {
    final label = switch (theme) {
      ThemeChoice.system => context.t('appearance.system'),
      ThemeChoice.light => context.t('appearance.light'),
      ThemeChoice.dark => context.t('appearance.dark'),
    };
    return Pressable(
      scale: 0.96,
      onTap: onTap,
      child: Column(
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            height: 136,
            padding: const EdgeInsets.all(2),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: selected ? CauceColors.accent : CauceColors.border, width: 2),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(11),
              child: switch (theme) {
                ThemeChoice.light => _page(true),
                ThemeChoice.dark => _page(false),
                // The light page with its right half dark.
                ThemeChoice.system => Stack(
                  fit: StackFit.expand,
                  children: [
                    _page(false),
                    ClipRect(clipper: const _LeftHalf(), child: _page(true)),
                  ],
                ),
              },
            ),
          ),
          const SizedBox(height: 7),
          Text(
            label,
            style: TextStyle(
              fontSize: 15,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
              color: selected ? CauceColors.foreground : CauceColors.mutedForeground,
            ),
          ),
        ],
      ),
    );
  }
}

class _LeftHalf extends CustomClipper<Rect> {
  const _LeftHalf();

  @override
  Rect getClip(Size size) => Rect.fromLTWH(0, 0, size.width / 2, size.height);

  @override
  bool shouldReclip(_LeftHalf old) => false;
}

/// A swatch or icon with its name under it, ringed in the accent when picked.
class _Choice extends StatelessWidget {
  const _Choice({required this.label, required this.selected, required this.onTap, required this.child});

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Pressable(
      scale: 0.92,
      onTap: onTap,
      child: Column(
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: selected ? CauceColors.accent : Colors.transparent, width: 2),
            ),
            child: child,
          ),
          const SizedBox(height: 5),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12.5, color: selected ? CauceColors.foreground : CauceColors.mutedForeground),
          ),
        ],
      ),
    );
  }
}

/// An accent's colour in this theme; the cover one a wheel of every hue.
class _AccentDot extends StatelessWidget {
  const _AccentDot({required this.accent});

  final AccentChoice accent;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: accent == AccentChoice.cover ? null : Palette.of(light: CauceColors.light, accent: accent).accent,
        gradient: accent == AccentChoice.cover
            ? const SweepGradient(
                colors: [
                  Color(0xFFE5677A),
                  Color(0xFFE9B04F),
                  Color(0xFF6CC27A),
                  Color(0xFF5AA2F7),
                  Color(0xFFB06FD8),
                  Color(0xFFE5677A),
                ],
              )
            : null,
      ),
    );
  }
}

/// The "c." mark on each icon's ground, as it shows on the home screen.
class _IconPreview extends StatelessWidget {
  const _IconPreview({required this.icon});

  final AppIconChoice icon;

  @override
  Widget build(BuildContext context) {
    final (ground, mark, dot) = switch (icon) {
      AppIconChoice.night => (const Color(0xFF140A14), Colors.white, const Color(0xFFD36FD0)),
      AppIconChoice.paper => (const Color(0xFFF7F0F2), const Color(0xFF140A14), const Color(0xFFD36FD0)),
      AppIconChoice.magenta => (const Color(0xFFD36FD0), const Color(0xFF140A14), Colors.white),
      AppIconChoice.coral => (const Color(0xFFD9675E), const Color(0xFF140A14), const Color(0xFF5A1A16)),
    };
    return Container(
      width: 58,
      height: 58,
      decoration: BoxDecoration(color: ground, borderRadius: BorderRadius.circular(14)),
      alignment: Alignment.center,
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: 'c',
              style: TextStyle(color: mark),
            ),
            TextSpan(
              text: '.',
              style: TextStyle(color: dot),
            ),
          ],
        ),
        style: const TextStyle(fontFamily: displayFont, fontSize: 26, fontWeight: FontWeight.w700, height: 1),
      ),
    );
  }
}
