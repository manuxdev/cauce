import 'package:flutter/material.dart';

import '../../../core/app_prefs.dart';
import '../../../core/app_scope.dart';
import '../../../core/icons.dart';
import '../../../core/l10n.dart';
import '../../../core/theme.dart';
import '../../../core/tint_scope.dart';
import '../../../core/widgets.dart';
import '../../player/player_design.dart';
import '../../player/views/design_motion.dart';
import '../../player/views/player_parts.dart';
import '../../player/views/seek_bars.dart';
import 'settings_widgets.dart';

/// The bars the list offers, in its order; the ring last, as only the vinyl draws it.
const _bars = [
  SeekStyle.line,
  SeekStyle.wave,
  SeekStyle.ripple,
  SeekStyle.capsule,
  SeekStyle.dots,
  SeekStyle.tape,
  SeekStyle.ring,
];

/// Appearance › Design and bar: how the full player and its lyrics look, which bar and buttons
/// they draw, and how they move, with a preview at the top.
class PlayerDesignScreen extends StatelessWidget {
  const PlayerDesignScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: appPrefs,
      builder: (context, _) {
        final design = appPrefs.playerDesign;
        final ownBar = seekStyleFor(design, SeekStyle.auto);
        return SettingsPage(
          title: context.t('design.title'),
          back: context.t('settings.appearance'),
          children: [
            // Not const: it reads the prefs itself, and a const child is never rebuilt.
            _Preview(),
            const SizedBox(height: 22),
            Overline(context.t('design.designs'), padding: const EdgeInsets.fromLTRB(16, 4, 16, 8)),
            SizedBox(
              height: 214,
              child: ListView(
                scrollDirection: Axis.horizontal,
                clipBehavior: Clip.none,
                children: [
                  for (final option in PlayerDesign.values)
                    Padding(
                      padding: const EdgeInsets.only(right: 12),
                      child: _DesignChoice(
                        design: option,
                        selected: option == design,
                        onTap: () {
                          tick();
                          appPrefs.update((prefs) {
                            prefs.playerDesign = option;
                            // The ring only goes round the vinyl.
                            if (option != PlayerDesign.vinyl && prefs.seekStyle == SeekStyle.ring) {
                              prefs.seekStyle = SeekStyle.auto;
                            }
                          });
                        },
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 22),
              child: Text(context.t('design.designs.footer'), style: CauceText.caption),
            ),
            SettingsGroup(
              title: context.t('design.bar'),
              footer: context.t('design.bar.footer'),
              children: [
                _BarRow(
                  style: SeekStyle.auto,
                  title: context.t('seek.auto'),
                  subtitle: context.t('seek.auto.detail', {'bar': context.t('seek.${ownBar.name}')}),
                  preview: ownBar,
                ),
                for (final bar in _bars)
                  _BarRow(
                    style: bar,
                    title: context.t('seek.${bar.name}'),
                    subtitle: context.t('seek.${bar.name}.detail'),
                    preview: bar,
                    enabled: bar != SeekStyle.ring || design == PlayerDesign.vinyl,
                  ),
                SettingsSwitch(
                  title: context.t('design.bar.mini'),
                  subtitle: context.t('design.bar.mini.detail'),
                  value: appPrefs.miniSeekStyle,
                  onChanged: (on) => appPrefs.update((prefs) => prefs.miniSeekStyle = on),
                ),
              ],
            ),
            Overline(context.t('design.buttons'), padding: const EdgeInsets.fromLTRB(16, 4, 16, 8)),
            Row(
              children: [
                for (final (index, look) in ButtonLook.values.skip(1).indexed) ...[
                  if (index > 0) const SizedBox(width: 10),
                  Expanded(
                    child: _ButtonChoice(look: look, selected: look == buttonLookFor(design, appPrefs.buttonLook)),
                  ),
                ],
              ],
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 22),
              child: Text(context.t('design.buttons.footer'), style: CauceText.caption),
            ),
            SettingsGroup(
              title: context.t('design.motion'),
              footer: context.t('design.motion.footer'),
              children: [
                SettingsSwitch(
                  title: context.t('design.spin'),
                  subtitle: context.t('design.spin.detail'),
                  value: appPrefs.spinVinyl,
                  onChanged: (on) => appPrefs.update((prefs) => prefs.spinVinyl = on),
                ),
                SettingsSwitch(
                  title: context.t('appearance.moving'),
                  subtitle: context.t('design.moving.detail'),
                  value: appPrefs.movingBackground,
                  onChanged: (on) => appPrefs.update((prefs) => prefs.movingBackground = on),
                ),
                SettingsSwitch(
                  title: context.t('design.reactive'),
                  subtitle: context.t('design.reactive.detail'),
                  value: appPrefs.reactive,
                  onChanged: (on) => appPrefs.update((prefs) => prefs.reactive = on),
                ),
                SettingsRow(
                  title: context.t('design.trackChange'),
                  value: context.t('trackChange.${appPrefs.trackChange.name}'),
                  onTap: () async {
                    final picked = await pickSetting(
                      context,
                      context.t('design.trackChange'),
                      TrackChange.values,
                      appPrefs.trackChange,
                      (change) => context.t('trackChange.${change.name}'),
                    );
                    if (picked != null) appPrefs.update((prefs) => prefs.trackChange = picked);
                  },
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(context.t('design.intensity'), style: const TextStyle(fontSize: 16.5)),
                      const SizedBox(height: 10),
                      SettingsSegmented(
                        options: [for (final level in MotionIntensity.values) context.t('intensity.${level.name}')],
                        selected: appPrefs.intensity.index,
                        onSelected: (index) {
                          tick();
                          appPrefs.update((prefs) => prefs.intensity = MotionIntensity.values[index]);
                        },
                      ),
                    ],
                  ),
                ),
              ],
            ),
            SettingsGroup(
              children: [
                SettingsRow(
                  title: context.t('design.reset'),
                  titleColor: CauceColors.accent,
                  onTap: () {
                    tick();
                    appPrefs.update((prefs) => prefs.resetPlayerDesign());
                  },
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}

/// The player in miniature as it is set: its design, bar and buttons, on the cover's colour. A
/// new design fades in over the last.
class _Preview extends StatelessWidget {
  const _Preview();

  @override
  Widget build(BuildContext context) {
    final tint = TintScope.of(context).vivid;
    final design = appPrefs.playerDesign;
    final look = buttonLookFor(design, appPrefs.buttonLook);
    final bar = seekStyleFor(design, appPrefs.seekStyle);
    return Container(
      height: 236,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [tint.player, tint.shade(0.24, 0.07)],
        ),
      ),
      // The badge comes last so it sits over the player, as the design draws it.
      child: Stack(
        children: [
          Positioned.fill(
            child: Column(
              children: [
                const SizedBox(height: 20),
                SizedBox(
                  height: 150,
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 280),
                    child: _Hero(key: ValueKey((design, bar)), design: design, bar: bar),
                  ),
                ),
                const Spacer(),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    ButtonFace(
                      look: look,
                      size: 30,
                      down: false,
                      child: const CauceIcon(CauceGlyph.prev, size: 13, color: Colors.white),
                    ),
                    const SizedBox(width: 12),
                    ButtonFace(
                      look: look,
                      size: 40,
                      down: false,
                      primary: true,
                      child: CauceIcon(
                        CauceGlyph.pause,
                        size: 16,
                        color: look == ButtonLook.circle ? tint.ink : Colors.white,
                      ),
                    ),
                    const SizedBox(width: 12),
                    ButtonFace(
                      look: look,
                      size: 30,
                      down: false,
                      child: const CauceIcon(CauceGlyph.next, size: 13, color: Colors.white),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
              ],
            ),
          ),
          Positioned(
            top: 14,
            left: 14,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
              decoration: BoxDecoration(color: const Color(0x4D000000), borderRadius: BorderRadius.circular(8)),
              child: Text(
                context.t('design.preview'),
                style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: Color(0xE0FFFFFF)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// What leads the preview: Vinyl's record at full size, ringed when its bar is the ring; for the
/// others their thumbnail beside the bar they use.
class _Hero extends StatelessWidget {
  const _Hero({super.key, required this.design, required this.bar});

  final PlayerDesign design;
  final SeekStyle bar;

  @override
  Widget build(BuildContext context) {
    final player = AppScope.of(context).player;
    if (design == PlayerDesign.vinyl) {
      final disc = VinylDisc(
        url: player.track?.cover,
        size: bar == SeekStyle.ring ? 122 : 110,
        playing: player.playing,
      );
      if (bar == SeekStyle.ring) {
        return Center(
          child: SizedBox.square(
            dimension: 150,
            child: CustomPaint(
              foregroundPainter: _RingSketch(inset: 5),
              child: Center(child: disc),
            ),
          ),
        );
      }
      return Column(
        children: [
          disc,
          const SizedBox(height: 12),
          SeekPreview(style: bar, width: 140),
        ],
      );
    }
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(12),
          // Drawn at the card's size and scaled down, so the thumbnail lays out as it does there.
          child: SizedBox(
            width: 84,
            height: 150,
            child: FittedBox(
              child: SizedBox(
                width: 100,
                height: 178,
                child: _Thumb(design: design, bar: bar),
              ),
            ),
          ),
        ),
        const SizedBox(width: 18),
        SeekPreview(style: bar, width: 120),
      ],
    );
  }
}

/// A design's thumbnail with its name; the picked one ringed in the accent with a check.
class _DesignChoice extends StatelessWidget {
  const _DesignChoice({required this.design, required this.selected, required this.onTap});

  final PlayerDesign design;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final accent = CauceColors.accent;
    return Semantics(
      button: true,
      selected: selected,
      label: context.t('design.${design.name}'),
      child: GestureDetector(
        onTap: onTap,
        child: Column(
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              width: 100,
              height: 178,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                boxShadow: selected
                    ? [
                        BoxShadow(color: CauceColors.settingsBackground, spreadRadius: 2.5),
                        BoxShadow(color: accent, spreadRadius: 4.5),
                      ]
                    : null,
              ),
              // Expanded, so each thumbnail fills its card rather than shrinking to what it draws.
              child: Stack(
                fit: StackFit.expand,
                children: [
                  _Thumb(design: design, bar: seekStyleFor(design, SeekStyle.auto)),
                  if (selected)
                    Positioned(
                      top: 6,
                      right: 6,
                      child: Container(
                        width: 22,
                        height: 22,
                        decoration: BoxDecoration(color: accent, shape: BoxShape.circle),
                        child: Center(
                          child: CauceIcon(CauceGlyph.check, size: 13, color: CauceColors.onAccent, weight: 3),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            Text(
              context.t('design.${design.name}'),
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                color: selected ? accent : null,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A design drawn small: where its cover, names and controls sit.
class _Thumb extends StatelessWidget {
  const _Thumb({required this.design, required this.bar});

  final PlayerDesign design;
  final SeekStyle bar;

  @override
  Widget build(BuildContext context) {
    final tint = TintScope.of(context).vivid;
    final cover = BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [tint.shade(0.62, 0.14), tint.shade(0.4, 0.12)],
      ),
    );
    Widget line(double width, [double alpha = 0.8, double height = 5]) => Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: alpha),
        borderRadius: BorderRadius.circular(height),
      ),
    );
    final names = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [line(44), const SizedBox(height: 4), line(28, 0.5)],
    );
    final body = switch (design) {
      PlayerDesign.classic => Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 8),
            AspectRatio(
              aspectRatio: 1,
              child: DecoratedBox(decoration: cover.copyWith(borderRadius: BorderRadius.circular(6))),
            ),
            const Spacer(),
            names,
            const SizedBox(height: 8),
            line(double.infinity, 0.9, 2),
            const SizedBox(height: 10),
            Center(
              child: Container(
                width: 18,
                height: 18,
                decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
              ),
            ),
            const SizedBox(height: 4),
          ],
        ),
      ),
      PlayerDesign.vinyl => Column(
        children: [
          const SizedBox(height: 22),
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: const Color(0xFF17131A),
              border: Border.all(color: Colors.white, width: 2),
            ),
            alignment: Alignment.center,
            child: Container(width: 26, height: 26, decoration: cover.copyWith(shape: BoxShape.circle)),
          ),
          const Spacer(),
          names,
          const SizedBox(height: 14),
          Container(
            width: 24,
            height: 24,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 1.5),
            ),
          ),
          const SizedBox(height: 14),
        ],
      ),
      PlayerDesign.poster => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(height: 80, decoration: cover),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 6, 10, 0),
            child: Text(
              'Aa',
              style: TextStyle(
                fontFamily: displayFont,
                fontSize: 30,
                height: 0.9,
                fontWeight: FontWeight.w700,
                color: Colors.white,
                letterSpacing: -1.5,
              ),
            ),
          ),
          const Spacer(),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: SeekPreview(style: SeekStyle.wave, width: 80),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 12),
            child: Container(
              height: 16,
              decoration: BoxDecoration(color: CauceColors.dark.accent, borderRadius: BorderRadius.circular(6)),
            ),
          ),
        ],
      ),
      PlayerDesign.tape => Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          children: [
            Container(
              height: 76,
              decoration: BoxDecoration(color: tint.shade(0.2, 0.035), borderRadius: BorderRadius.circular(10)),
              alignment: Alignment.center,
              child: const Text(
                '01:24',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ),
            const SizedBox(height: 8),
            SeekPreview(style: SeekStyle.tape, width: 80),
            const Spacer(),
            Row(
              children: [
                for (var key = 0; key < 4; key++) ...[
                  if (key > 0) const SizedBox(width: 3),
                  Expanded(
                    child: Container(
                      height: 18,
                      decoration: BoxDecoration(
                        color: tint.shade(0.3, 0.02),
                        borderRadius: BorderRadius.circular(4),
                        boxShadow: [BoxShadow(color: tint.shade(0.1, 0.01), offset: const Offset(0, 2))],
                      ),
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 6),
          ],
        ),
      ),
      PlayerDesign.immersive => Stack(
        children: [
          Positioned.fill(child: DecoratedBox(decoration: cover)),
          Positioned(
            left: 6,
            right: 6,
            bottom: 6,
            child: Container(
              height: 58,
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: const Color(0x4D280A06),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: const Color(0x47FFFFFF), width: 0.5),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [names, const Spacer(), line(double.infinity, 0.9, 2)],
              ),
            ),
          ),
        ],
      ),
    };
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: design == PlayerDesign.tape
                ? [tint.shade(0.14, 0.012), tint.shade(0.14, 0.012)]
                : [tint.player, tint.shade(0.22, 0.06)],
          ),
        ),
        child: body,
      ),
    );
  }
}

/// A bar in the list, drawn as it looks, ticked when it is the one in use.
class _BarRow extends StatelessWidget {
  const _BarRow({
    required this.style,
    required this.title,
    required this.subtitle,
    required this.preview,
    this.enabled = true,
  });

  final SeekStyle style;
  final String title;
  final String subtitle;
  final SeekStyle preview;

  /// Off for the ring unless the vinyl is picked.
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final selected = appPrefs.seekStyle == style;
    final tint = TintScope.of(context).vivid;
    return Semantics(
      selected: selected,
      child: SettingsRow(
        title: title,
        subtitle: subtitle,
        enabled: enabled,
        onTap: () {
          tick();
          appPrefs.update((prefs) => prefs.seekStyle = style);
        },
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              decoration: BoxDecoration(color: tint.player, borderRadius: BorderRadius.circular(8)),
              child: preview == SeekStyle.ring
                  ? const SizedBox(width: 34, height: 34, child: _RingPreview())
                  : SeekPreview(style: preview, width: 102),
            ),
            SizedBox(
              width: 30,
              child: selected ? CauceIcon(CauceGlyph.check, size: 18, color: CauceColors.accent, weight: 2.6) : null,
            ),
          ],
        ),
      ),
    );
  }
}

/// The ring, small, a little over a third of the way round.
class _RingPreview extends StatelessWidget {
  const _RingPreview();

  @override
  Widget build(BuildContext context) {
    return CustomPaint(painter: _RingSketch());
  }
}

class _RingSketch extends CustomPainter {
  _RingSketch({this.inset = 3});

  final double inset;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = (Offset.zero & size).deflate(inset);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    canvas.drawOval(rect, paint..color = const Color(0x29FFFFFF));
    canvas.drawArc(rect, -1.5708, 2.5, false, paint..color = Colors.white);
  }

  @override
  bool shouldRepaint(_RingSketch old) => false;
}

/// A button look as a play button on the player's colour; the one in use tinted and ringed.
class _ButtonChoice extends StatelessWidget {
  const _ButtonChoice({required this.look, required this.selected});

  final ButtonLook look;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final accent = CauceColors.accent;
    final tint = TintScope.of(context).vivid;
    return Semantics(
      button: true,
      selected: selected,
      child: GestureDetector(
        onTap: () {
          tick();
          appPrefs.update((prefs) => prefs.buttonLook = look);
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            color: selected ? accent.withValues(alpha: 0.14) : CauceColors.group,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: selected ? accent : Colors.transparent, width: 1.5),
          ),
          child: Column(
            children: [
              Container(
                width: 60,
                height: 60,
                decoration: BoxDecoration(color: tint.player, borderRadius: BorderRadius.circular(12)),
                alignment: Alignment.center,
                child: ButtonFace(
                  look: look,
                  size: 44,
                  down: false,
                  primary: true,
                  child: CauceIcon(
                    CauceGlyph.play,
                    size: 20,
                    color: look == ButtonLook.circle ? tint.ink : Colors.white,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                context.t('buttons.${look.name}'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: selected ? accent : null),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
