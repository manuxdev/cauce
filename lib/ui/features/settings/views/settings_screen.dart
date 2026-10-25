import 'package:flutter/material.dart';

import '../../../core/icons.dart';
import '../../../core/l10n.dart';
import '../../accounts/view_models/accounts_view_model.dart';
import '../view_models/playback_settings_view_model.dart';
import 'appearance_screen.dart';
import 'general_screen.dart';
import 'integrations_screen.dart';
import 'lyrics_settings_screen.dart';
import 'playback_screen.dart';
import 'providers_screen.dart';
import 'settings_widgets.dart';
import 'storage_screen.dart';

/// The settings sections, as upstream groups them.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key, required this.accounts, required this.playback});

  final AccountsViewModel accounts;
  final PlaybackSettingsViewModel playback;

  void _open(BuildContext context, Widget page) =>
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([accounts, playback]),
      builder: (context, _) {
        final connected = streamingServices.where((service) => accounts.account(service.slug) != null).length;
        return SettingsPage(
          root: true,
          title: context.t('settings.title'),
          children: [
            SettingsGroup(
              children: [
                SettingsRow(
                  glyph: CauceGlyph.globe,
                  title: context.t('settings.general'),
                  onTap: () => _open(context, const GeneralScreen()),
                ),
                SettingsRow(
                  glyph: CauceGlyph.user,
                  color: const Color(0xFFC8483F),
                  title: context.t('settings.providers'),
                  value: connected == 0 ? null : context.t('settings.connected', {'count': connected}),
                  onTap: () => _open(context, ProvidersScreen(accounts: accounts)),
                ),
                SettingsRow(
                  glyph: CauceGlyph.equalizer,
                  color: const Color(0xFFB04FB8),
                  title: context.t('settings.playback'),
                  onTap: () => _open(context, PlaybackScreen(accounts: accounts, playback: playback)),
                ),
                SettingsRow(
                  glyph: CauceGlyph.download,
                  color: const Color(0xFF0F8A94),
                  title: context.t('settings.storage'),
                  value: switch (playback.usage) {
                    final usage? => formatBytes(usage.downloadBytes.toInt() + usage.cacheBytes.toInt()),
                    null => null,
                  },
                  onTap: () => _open(context, StorageScreen(playback: playback)),
                ),
              ],
            ),
            SettingsGroup(
              title: context.t('settings.personalisation'),
              children: [
                SettingsRow(
                  glyph: CauceGlyph.palette,
                  color: const Color(0xFF3E6FD8),
                  title: context.t('settings.appearance'),
                  onTap: () => _open(context, const AppearanceScreen()),
                ),
                SettingsRow(
                  glyph: CauceGlyph.lyrics,
                  color: const Color(0xFFC9761A),
                  title: context.t('settings.lyrics'),
                  onTap: () => _open(context, const LyricsSettingsScreen()),
                ),
                SettingsRow(
                  glyph: CauceGlyph.plug,
                  color: const Color(0xFF1F8A55),
                  title: context.t('settings.integrations'),
                  onTap: () => _open(context, const IntegrationsScreen()),
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}
