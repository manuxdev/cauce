import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/app_prefs.dart';
import '../../../core/app_scope.dart';
import '../../../core/l10n.dart';
import '../../../core/strings.dart';
import '../../../core/theme.dart';
import '../../search/recent_searches.dart';
import 'settings_widgets.dart';
import '../../../core/icons.dart';
import '../../../core/toast.dart';

/// The app's version and build, kept in step with `pubspec.yaml`.
const _version = '1.0.0 (1)';
const _source = 'https://github.com/manuxdev/cause';
const _license = 'https://www.gnu.org/licenses/gpl-3.0.html';

/// The language, where the app opens, touch, history and about.
class GeneralScreen extends StatelessWidget {
  const GeneralScreen({super.key});

  String _languageName(BuildContext context, AppLanguage option) => switch (option) {
    AppLanguage.system => context.t('general.language.system'),
    AppLanguage.english => 'English',
    AppLanguage.spanish => 'Español',
  };

  String _startName(BuildContext context, StartTab tab) => switch (tab) {
    StartTab.last => context.t('start.last'),
    StartTab.home => context.t('tab.home'),
    StartTab.search => context.t('tab.search'),
    StartTab.library => context.t('tab.library'),
  };

  void _copy(BuildContext context, String url) {
    Clipboard.setData(ClipboardData(text: url));
    showToast(Toast(title: context.t('toast.copied'), detail: url, glyph: CauceGlyph.external, tone: ToastTone.info));
  }

  @override
  Widget build(BuildContext context) {
    final playback = AppScope.of(context).playbackSettings;
    return ListenableBuilder(
      listenable: Listenable.merge([appPrefs, playback, language]),
      builder: (context, _) {
        final chosen = language.chosen;
        // The system choice also says what it resolves to.
        final spoken = language.table == spanish ? 'Español' : 'English';
        return SettingsPage(
          title: context.t('settings.general'),
          children: [
            SettingsGroup(
              title: context.t('general.language'),
              children: [
                SettingsRow(
                  title: context.t('general.language'),
                  value: chosen == AppLanguage.system
                      ? '${context.t('general.language.system')} · $spoken'
                      : _languageName(context, chosen),
                  onTap: () async {
                    final picked = await pickSetting(
                      context,
                      context.t('general.language'),
                      AppLanguage.values,
                      chosen,
                      (option) => _languageName(context, option),
                    );
                    if (picked != null) language.choose(picked);
                  },
                ),
              ],
            ),
            SettingsGroup(
              title: context.t('general.onOpen'),
              children: [
                SettingsRow(
                  title: context.t('general.startTab'),
                  value: _startName(context, appPrefs.startTab),
                  onTap: () async {
                    final picked = await pickSetting(
                      context,
                      context.t('general.startTab'),
                      StartTab.values,
                      appPrefs.startTab,
                      (tab) => _startName(context, tab),
                    );
                    if (picked != null) appPrefs.update((prefs) => prefs.startTab = picked);
                  },
                ),
                if (playback.settings case final settings?)
                  SettingsSwitch(
                    title: context.t('general.resume'),
                    subtitle: context.t('general.resume.detail'),
                    value: settings.resumeLast,
                    onChanged: (on) => playback.update(resumeLast: on),
                  ),
              ],
            ),
            SettingsGroup(
              title: context.t('general.interaction'),
              children: [
                SettingsSwitch(
                  title: context.t('general.haptics'),
                  value: appPrefs.haptics,
                  onChanged: (on) => appPrefs.update((prefs) => prefs.haptics = on),
                ),
                SettingsSwitch(
                  title: context.t('general.hold'),
                  value: appPrefs.holdForOptions,
                  onChanged: (on) => appPrefs.update((prefs) => prefs.holdForOptions = on),
                ),
              ],
            ),
            SettingsGroup(
              title: context.t('general.history'),
              children: [
                SettingsSwitch(
                  title: context.t('general.saveSearches'),
                  value: appPrefs.saveSearches,
                  onChanged: (on) => appPrefs.update((prefs) => prefs.saveSearches = on),
                ),
                SettingsRow(
                  title: context.t('general.clearSearches'),
                  titleColor: CauceColors.accent,
                  onTap: () {
                    recentSearches.clear();
                    showToast(
                      Toast(title: context.t('general.cleared'), glyph: CauceGlyph.trash, tone: ToastTone.info),
                    );
                  },
                  trailing: const SizedBox.shrink(),
                ),
              ],
            ),
            SettingsGroup(
              title: context.t('general.about'),
              footer: context.t('about.disclaimer'),
              children: [
                SettingsRow(title: context.t('about.versionRow'), value: _version),
                SettingsRow(title: context.t('about.source'), value: 'GitHub', onTap: () => _copy(context, _source)),
                SettingsRow(title: context.t('about.license'), value: 'GPL-3.0', onTap: () => _copy(context, _license)),
                SettingsRow(
                  title: context.t('about.thanks'),
                  onTap: () =>
                      showLicensePage(context: context, applicationName: 'Cauce', applicationVersion: _version),
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}
