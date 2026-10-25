import 'package:flutter/material.dart';

import '../../../core/across_providers.dart';
import '../../../core/app_prefs.dart';
import '../../../core/icons.dart';
import '../../../core/l10n.dart';
import '../../../core/motion.dart';
import '../../../core/selected_service.dart';
import '../../../core/theme.dart';
import '../../../core/widgets.dart';
import '../../accounts/sign_in.dart';
import '../../accounts/view_models/accounts_view_model.dart';
import 'provider_screen.dart';
import 'settings_widgets.dart';

/// The amber of a session that needs signing in again.
const _warning = Color(0xFFF0B04A);

/// Which provider the tabs open with, the connected ones with their accounts, the ones still to
/// connect, and how they work together.
class ProvidersScreen extends StatelessWidget {
  const ProvidersScreen({super.key, required this.accounts});

  final AccountsViewModel accounts;

  Future<void> _pickActive(BuildContext context, List<StreamingService> connected, String? active) async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      useRootNavigator: true,
      sheetAnimationStyle: sheetAnimation,
      builder: (sheet) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
          child: SettingsGroup(
            title: context.t('providers.active'),
            children: [
              for (final service in connected)
                SettingsRow(
                  title: service.name,
                  trailing: service.slug == active ? pickedMark : null,
                  onTap: () => Navigator.of(sheet).pop(service.slug),
                ),
            ],
          ),
        ),
      ),
    );
    if (picked != null) selectedService.select(picked);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([accounts, selectedService, appPrefs]),
      builder: (context, _) {
        final connected = accounts.connected;
        final active = selectedService.among([for (final service in connected) service.slug]);
        final activeName = connected.where((service) => service.slug == active).firstOrNull?.name;
        // Signed in, signing in, or with a session to renew: everything that is not new.
        bool known(StreamingService service) =>
            accounts.account(service.slug) != null ||
            accounts.restoring(service.slug) ||
            accounts.error(service.slug) != null;
        final mine = streamingServices.where(known).toList();
        final others = streamingServices.where((service) => !known(service)).toList();
        return SettingsPage(
          title: context.t('settings.providers'),
          children: [
            SettingsGroup(
              footer: context.t('providers.active.detail'),
              children: [
                SettingsRow(
                  title: context.t('providers.active'),
                  value: activeName ?? context.t('providers.noneShort'),
                  onTap: connected.length > 1 ? () => _pickActive(context, connected, active) : null,
                ),
              ],
            ),
            if (mine.isNotEmpty)
              SettingsGroup(
                title: context.t('providers.connected', {'count': mine.length}),
                children: [
                  for (final service in mine)
                    _Connected(service: service, accounts: accounts, active: service.slug == active),
                ],
              ),
            if (others.isNotEmpty)
              SettingsGroup(
                title: context.t('providers.available'),
                children: [
                  for (final service in others)
                    _Row(
                      service: service,
                      subtitle: context.t('providers.notSignedIn'),
                      trailing: _ConnectButton(onTap: () => signIn(context, service, accounts)),
                    ),
                ],
              ),
            SettingsGroup(
              title: context.t('providers.across'),
              footer: context.t('providers.keepsDownloads'),
              children: [
                SettingsSwitch(
                  title: context.t('providers.searchAll'),
                  subtitle: context.t('providers.searchAll.detail'),
                  value: appPrefs.searchAll,
                  onChanged: (on) => appPrefs.update((prefs) => prefs.searchAll = on),
                ),
                SettingsRow(
                  title: context.t('providers.order'),
                  value: [
                    for (final slug in ordered([for (final service in connected) service.slug], appPrefs.providerOrder))
                      brandOf(slug).letters,
                  ].join(' · '),
                  onTap: connected.length > 1
                      ? () => Navigator.of(
                          context,
                        ).push(MaterialPageRoute<void>(builder: (_) => ProviderOrderScreen(accounts: accounts)))
                      : null,
                ),
                SettingsSwitch(
                  title: context.t('providers.substitute'),
                  subtitle: context.t('providers.substitute.detail'),
                  value: appPrefs.substitute,
                  onChanged: (on) => appPrefs.update((prefs) => prefs.substitute = on),
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}

/// A connected provider: its account, a tag when active, a warning when its session lapsed.
/// A tap opens its page, or signs in again.
class _Connected extends StatelessWidget {
  const _Connected({required this.service, required this.accounts, required this.active});

  final StreamingService service;
  final AccountsViewModel accounts;
  final bool active;

  void _open(BuildContext context) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => ProviderScreen(service: service, accounts: accounts),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final account = accounts.account(service.slug);
    final restoring = accounts.restoring(service.slug);
    final lapsed = account == null && !restoring;
    return _Row(
      service: service,
      subtitle: restoring
          ? context.t('providers.connecting')
          : account == null
          ? context.t('providers.expired')
          : accounts.browsesOnly(service.slug)
          ? context.t(service.slug == 'tidal' ? 'providers.unsubscribedTag' : 'providers.freeTag', {'account': account})
          : account,
      subtitleColor: lapsed ? _warning : null,
      onTap: lapsed ? () => signIn(context, service, accounts) : (restoring ? null : () => _open(context)),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (restoring)
            const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
          else if (lapsed)
            const CauceIcon(CauceGlyph.alert, size: 18, color: _warning, weight: 2.2)
          else if (active)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: CauceColors.accent.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                context.t('providers.activeTag'),
                style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: CauceColors.accent),
              ),
            ),
          const SizedBox(width: 8),
          CauceIcon(CauceGlyph.chevronRight, size: 16, color: CauceColors.faintForeground, weight: 2.2),
        ],
      ),
    );
  }
}

/// A provider's badge, name and one line under it.
class _Row extends StatelessWidget {
  const _Row({required this.service, required this.subtitle, this.subtitleColor, this.trailing, this.onTap});

  final StreamingService service;
  final String subtitle;
  final Color? subtitleColor;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 12, 10),
        child: Row(
          children: [
            BrandBadge(slug: service.slug),
            const SizedBox(width: 13),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(service.name, style: const TextStyle(fontSize: 16.5)),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 13, color: subtitleColor ?? CauceColors.mutedForeground),
                  ),
                ],
              ),
            ),
            ?trailing,
          ],
        ),
      ),
    );
  }
}

class _ConnectButton extends StatelessWidget {
  const _ConnectButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Pressable(
      scale: 0.9,
      onTap: onTap,
      child: Container(
        height: 32,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: CauceColors.foreground.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(
          context.t('providers.connect'),
          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: CauceColors.accent),
        ),
      ),
    );
  }
}
