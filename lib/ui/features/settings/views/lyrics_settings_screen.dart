import 'package:flutter/material.dart';

import '../../../core/app_prefs.dart';
import '../../../core/icons.dart';
import '../../../core/l10n.dart';
import '../../../core/strings.dart';
import '../../../core/theme.dart';
import '../../../core/tint_scope.dart';
import 'settings_widgets.dart';

/// The offsets offered, in seconds: earlier is negative.
const _offsets = [-1.5, -1.0, -0.75, -0.5, -0.25, 0.0, 0.25, 0.5, 0.75, 1.0, 1.5];

/// How lyrics look, how they follow the music, where they come from and whether downloads keep
/// them.
class LyricsSettingsScreen extends StatelessWidget {
  const LyricsSettingsScreen({super.key});

  String _seconds(BuildContext context, Duration offset) {
    final text = '${(offset.inMilliseconds / 1000).toStringAsFixed(offset.inMilliseconds % 100 == 0 ? 1 : 2)} s';
    return language.table == spanish ? text.replaceAll('.', ',') : text;
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: appPrefs,
      builder: (context, _) => SettingsPage(
        title: context.t('settings.lyrics'),
        children: [
          // Not const: a const preview would be skipped when the preferences change.
          Padding(padding: const EdgeInsets.only(bottom: 22), child: _Preview()),
          SettingsGroup(
            title: context.t('lyrics.text'),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
                child: Row(
                  children: [
                    const Text('A', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
                    Expanded(
                      child: Slider(
                        value: appPrefs.lyricsScale,
                        min: minLyricsScale,
                        max: maxLyricsScale,
                        divisions: 10,
                        onChanged: (scale) => appPrefs.update((prefs) => prefs.lyricsScale = scale),
                      ),
                    ),
                    const Text('A', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
                  ],
                ),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(top: 0, bottom: 22),
            child: SettingsSegmented(
              options: [context.t('lyrics.left'), context.t('lyrics.center')],
              selected: appPrefs.lyricsCentered ? 1 : 0,
              onSelected: (index) {
                tick();
                appPrefs.update((prefs) => prefs.lyricsCentered = index == 1);
              },
            ),
          ),
          SettingsGroup(
            title: context.t('lyrics.sync'),
            children: [
              SettingsSwitch(
                title: context.t('lyrics.wordByWord'),
                subtitle: context.t('lyrics.wordByWord.detail'),
                value: appPrefs.wordByWord,
                onChanged: (on) => appPrefs.update((prefs) => prefs.wordByWord = on),
              ),
              SettingsRow(
                title: context.t('lyrics.offset'),
                value: _seconds(context, appPrefs.lyricsOffset),
                onTap: () async {
                  final picked = await pickSetting(
                    context,
                    context.t('lyrics.offset'),
                    _offsets,
                    appPrefs.lyricsOffset.inMilliseconds / 1000,
                    (seconds) {
                      final text = _seconds(context, Duration(milliseconds: (seconds * 1000).round()));
                      if (seconds == 0) return text;
                      return '${seconds > 0 ? '+' : ''}$text · ${context.t(seconds < 0 ? 'lyrics.earlier' : 'lyrics.later')}';
                    },
                  );
                  if (picked == null) return;
                  appPrefs.update((prefs) => prefs.lyricsOffset = Duration(milliseconds: (picked * 1000).round()));
                },
              ),
              SettingsSwitch(
                title: context.t('lyrics.open'),
                value: appPrefs.openLyrics,
                onChanged: (on) => appPrefs.update((prefs) => prefs.openLyrics = on),
              ),
            ],
          ),
          SettingsGroup(
            title: context.t('lyrics.sources'),
            footer: context.t('lyrics.sources.detail'),
            children: [_Sources(order: appPrefs.lyricsSources)],
          ),
          SettingsGroup(
            title: context.t('lyrics.offline'),
            children: [
              SettingsSwitch(
                title: context.t('lyrics.save'),
                value: appPrefs.saveLyrics,
                onChanged: (on) => appPrefs.update((prefs) => prefs.saveLyrics = on),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Three lines as the player draws them with the chosen size and alignment: one sung, one being
/// sung word by word, on the playing cover's colour.
class _Preview extends StatelessWidget {
  const _Preview();

  @override
  Widget build(BuildContext context) {
    final centered = appPrefs.lyricsCentered;
    final style = TextStyle(
      fontFamily: displayFont,
      fontSize: 19 * appPrefs.lyricsScale,
      fontWeight: FontWeight.w700,
      height: 1.25,
      letterSpacing: -0.3,
    );
    final ink = CauceColors.dark.foreground;
    final align = centered ? TextAlign.center : TextAlign.start;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 18),
      decoration: BoxDecoration(
        color: TintScope.of(context).vivid.player,
        borderRadius: BorderRadius.circular(CauceMetrics.groupRadius),
      ),
      child: Column(
        crossAxisAlignment: centered ? CrossAxisAlignment.center : CrossAxisAlignment.start,
        children: [
          Text(
            context.t('lyrics.sample.before'),
            textAlign: align,
            style: style.copyWith(color: ink.withValues(alpha: 0.38), fontSize: style.fontSize! * 0.85),
          ),
          const SizedBox(height: 8),
          Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: context.t('lyrics.sample.sung'),
                  style: TextStyle(color: ink),
                ),
                TextSpan(
                  text: context.t('lyrics.sample.coming'),
                  style: TextStyle(color: ink.withValues(alpha: appPrefs.wordByWord ? 0.38 : 1)),
                ),
              ],
            ),
            textAlign: align,
            style: style,
          ),
        ],
      ),
    );
  }
}

/// The lyrics sources, held by the grip and dragged into the order they are tried.
class _Sources extends StatelessWidget {
  const _Sources({required this.order});

  final List<String> order;

  @override
  Widget build(BuildContext context) {
    return ReorderableListView(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      buildDefaultDragHandles: false,
      proxyDecorator: (child, _, _) => Material(color: CauceColors.raised, child: child),
      onReorder: (from, to) {
        if (to > from) to--;
        tick();
        final next = [...order];
        next.insert(to, next.removeAt(from));
        appPrefs.update((prefs) => prefs.lyricsSources = next);
      },
      children: [
        for (final (index, source) in order.indexed)
          Column(
            key: ValueKey(source),
            mainAxisSize: MainAxisSize.min,
            children: [
              if (index > 0) Divider(height: 0.5, thickness: 0.5, indent: 16, color: CauceColors.border),
              SettingsRow(
                title: context.t('lyrics.source.$source'),
                subtitle: context.t('lyrics.source.$source.detail'),
                trailing: ReorderableDragStartListener(
                  index: index,
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: CauceIcon(CauceGlyph.grip, size: 20, color: CauceColors.mutedForeground),
                  ),
                ),
                leading: Container(
                  width: 24,
                  height: 24,
                  decoration: BoxDecoration(color: CauceColors.raised, shape: BoxShape.circle),
                  alignment: Alignment.center,
                  child: Text('${index + 1}', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                ),
              ),
            ],
          ),
      ],
    );
  }
}
