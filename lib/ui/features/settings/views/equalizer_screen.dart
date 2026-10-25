import 'package:flutter/material.dart';

import '../../../core/l10n.dart';
import '../../../core/theme.dart';
import '../../../core/widgets.dart';
import '../view_models/playback_settings_view_model.dart';
import 'settings_widgets.dart';

/// Upstream's ten graphic bands, in Hz.
const _frequencies = [31.25, 62.5, 125, 250, 500, 1000, 2000, 4000, 8000, 16000];

/// How far a band moves either way, in dB. Upstream allows ±24; every preset stays within ±6.
const _range = 12.0;

/// The graphic equalizer: on or off, the ten bands on one graph, heard as they move, and the
/// presets.
class EqualizerScreen extends StatelessWidget {
  const EqualizerScreen({super.key, required this.playback});

  final PlaybackSettingsViewModel playback;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: playback,
      builder: (context, _) {
        final settings = playback.settings;
        if (settings == null) return const SizedBox.shrink();
        final current = playback.preset;
        return SettingsPage(
          title: context.t('equalizer.title'),
          back: context.t('common.back'),
          action: GestureDetector(
            onTap: () => playback.update(bands: List.filled(_frequencies.length, 0)),
            child: Text(context.t('equalizer.reset'), style: TextStyle(fontSize: 17, color: CauceColors.accent)),
          ),
          children: [
            SettingsGroup(
              children: [
                SettingsSwitch(
                  title: context.t('equalizer.enabled'),
                  value: settings.equalizer,
                  onChanged: (on) => playback.update(equalizer: on),
                ),
              ],
            ),
            AnimatedOpacity(
              opacity: settings.equalizer ? 1 : 0.4,
              duration: const Duration(milliseconds: 200),
              child: IgnorePointer(
                ignoring: !settings.equalizer,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SettingsGroup(
                      children: [_Graph(bands: settings.bands, playback: playback)],
                    ),
                    Overline(context.t('equalizer.presets'), padding: const EdgeInsets.fromLTRB(16, 0, 16, 10)),
                    Wrap(
                      spacing: 8,
                      runSpacing: 10,
                      children: [
                        for (final preset in playback.presets)
                          _Chip(
                            label: context.t('preset.${preset.id}'),
                            selected: preset.id == current?.id,
                            onTap: () => playback.update(bands: preset.bands),
                          ),
                        _Chip(label: context.t('equalizer.custom'), selected: false, outlined: current == null),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// The bands on one graph: the scale down the side, the zero line across, and each band a rail
/// filled in the accent from zero to its knob. A band follows the finger anywhere on its rail.
class _Graph extends StatelessWidget {
  const _Graph({required this.bands, required this.playback});

  final List<double> bands;
  final PlaybackSettingsViewModel playback;

  static const _height = 190.0;
  static const _knob = 22.0;
  static TextStyle get _muted => TextStyle(fontSize: 11, color: CauceColors.mutedForeground);

  /// The height on the rail of `gain`, from the top.
  static double _y(double gain) =>
      (_range - gain.clamp(-_range, _range)) / (2 * _range) * (_height - _knob) + _knob / 2;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 18, 12, 12),
      child: Column(
        children: [
          SizedBox(
            height: _height,
            child: Row(
              children: [
                SizedBox(
                  width: 30,
                  child: Stack(
                    children: [
                      for (final (gain, label) in const [(_range, '+12'), (0.0, '0'), (-_range, '−12')])
                        Positioned(
                          top: _y(gain) - 7,
                          right: 6,
                          child: Text(label, style: _muted),
                        ),
                    ],
                  ),
                ),
                Expanded(
                  child: Stack(
                    children: [
                      Positioned(
                        left: 0,
                        right: 0,
                        top: _y(0),
                        child: SizedBox(
                          height: 1,
                          child: ColoredBox(color: CauceColors.foreground.withValues(alpha: 0.15)),
                        ),
                      ),
                      Row(
                        children: [
                          for (var band = 0; band < _frequencies.length; band++)
                            Expanded(
                              child: _Rail(gain: bands[band], onChanged: (gain) => playback.setBand(band, gain)),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              const SizedBox(width: 30),
              for (final frequency in _frequencies)
                Expanded(
                  child: Text(
                    frequency >= 1000 ? '${(frequency / 1000).round()}k' : '${frequency.round()}',
                    textAlign: TextAlign.center,
                    style: _muted,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Rail extends StatelessWidget {
  const _Rail({required this.gain, required this.onChanged});

  final double gain;
  final ValueChanged<double> onChanged;

  void _to(double y) {
    const travel = _Graph._height - _Graph._knob;
    final gain = _range - ((y - _Graph._knob / 2) / travel).clamp(0.0, 1.0) * 2 * _range;
    // Quarter-dB steps, as the engine stores them.
    onChanged((gain * 4).round() / 4);
  }

  @override
  Widget build(BuildContext context) {
    final at = _Graph._y(gain);
    final zero = _Graph._y(0);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (details) => _to(details.localPosition.dy),
      onVerticalDragUpdate: (details) => _to(details.localPosition.dy),
      child: Stack(
        alignment: Alignment.topCenter,
        children: [
          Positioned(
            top: _Graph._knob / 2,
            bottom: _Graph._knob / 2,
            child: Container(
              width: 4,
              decoration: BoxDecoration(
                color: CauceColors.foreground.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          Positioned(
            top: at < zero ? at : zero,
            height: (at - zero).abs(),
            child: Container(width: 4, color: CauceColors.accent),
          ),
          Positioned(
            top: at - _Graph._knob / 2,
            child: Container(
              width: _Graph._knob,
              height: _Graph._knob,
              decoration: const BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
                boxShadow: [BoxShadow(color: Color(0x59000000), blurRadius: 6, offset: Offset(0, 2))],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A preset: accent when picked, on the group colour otherwise; the custom curve only outlined.
class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.selected, this.onTap, this.outlined = false});

  final String label;
  final bool selected;
  final bool outlined;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        height: 36,
        padding: const EdgeInsets.symmetric(horizontal: 15),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? CauceColors.accent : (outlined ? Colors.transparent : CauceColors.group),
          borderRadius: BorderRadius.circular(18),
          border: outlined ? Border.all(color: CauceColors.foreground.withValues(alpha: 0.25)) : null,
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            color: selected ? CauceColors.onAccent : (outlined ? CauceColors.mutedForeground : CauceColors.foreground),
          ),
        ),
      ),
    );
  }
}
