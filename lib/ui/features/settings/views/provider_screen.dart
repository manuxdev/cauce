import 'package:flutter/material.dart';

import '../../../core/across_providers.dart';
import '../../../core/app_prefs.dart';
import '../../../core/icons.dart';
import '../../../core/l10n.dart';
import '../../../core/selected_service.dart';
import '../../../core/theme.dart';
import '../../../core/widgets.dart';
import '../../accounts/view_models/accounts_view_model.dart';
import 'settings_widgets.dart';

/// One connected provider: who is signed in, making it the active one, and signing out.
class ProviderScreen extends StatelessWidget {
  const ProviderScreen({super.key, required this.service, required this.accounts});

  final StreamingService service;
  final AccountsViewModel accounts;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([accounts, selectedService]),
      builder: (context, _) {
        final connected = [for (final service in accounts.connected) service.slug];
        final active = selectedService.among(connected) == service.slug;
        final others = connected.where((slug) => slug != service.slug).toList();
        final account = accounts.account(service.slug);
        return SettingsPage(
          title: service.name,
          backLabel: false,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(0, 12, 0, 22),
              child: Column(
                children: [
                  BrandBadge(slug: service.slug, size: 64),
                  const SizedBox(height: 12),
                  Text(
                    service.name,
                    style: const TextStyle(fontFamily: displayFont, fontSize: 24, fontWeight: FontWeight.w700),
                  ),
                  if (account != null) ...[
                    const SizedBox(height: 6),
                    Text(
                      context.t('providers.signedInAs', {'account': account}),
                      style: TextStyle(fontSize: 14, color: CauceColors.mutedForeground),
                    ),
                  ],
                ],
              ),
            ),
            SettingsGroup(
              children: [
                SettingsSwitch(
                  title: context.t('providers.makeActive'),
                  value: active,
                  // Off hands the tabs to the next connected one; with none, it stays.
                  onChanged: (on) => on
                      ? selectedService.select(service.slug)
                      : others.isEmpty
                      ? null
                      : selectedService.select(others.first),
                ),
              ],
            ),
            if (_plans(service.slug) case final plans when plans.isNotEmpty)
              SettingsGroup(
                title: context.t('plans.title'),
                children: [
                  for (final (label, text) in plans)
                    SettingsRow(title: context.t(label), subtitle: context.t(text), trailing: const SizedBox.shrink()),
                ],
              ),
            SettingsGroup(
              footer: context.t('providers.keepsDownloadsOf', {'service': service.name}),
              children: [
                SettingsRow(
                  title: context.t('providers.signOut'),
                  titleColor: CauceColors.error,
                  trailing: const SizedBox.shrink(),
                  onTap: () {
                    accounts.signOut(service.slug);
                    Navigator.of(context).pop();
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

/// What each plan of `slug` gets in Cauce, as label and text keys, with the lines about this
/// platform alone. Only what Cauce itself does is said; a plan's own terms are the service's.
List<(String, String)> _plans(String slug) => switch (slug) {
  'subsonic' => [('plans.server', 'plans.subsonic')],
  'jellyfin' => [('plans.server', 'plans.jellyfin')],
  'emby' => [('plans.server', 'plans.emby')],
  'plex' => [('plans.server', 'plans.plex')],
  _ => const [],
};

/// The order combined results take turns in, dragged by the grips.
class ProviderOrderScreen extends StatelessWidget {
  const ProviderOrderScreen({super.key, required this.accounts});

  final AccountsViewModel accounts;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: appPrefs,
      builder: (context, _) {
        final slugs = ordered([for (final service in accounts.connected) service.slug], appPrefs.providerOrder);
        return SettingsPage(
          title: context.t('providers.order'),
          backLabel: false,
          children: [
            SettingsGroup(
              footer: context.t('providers.order.detail'),
              children: [
                ReorderableListView(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  buildDefaultDragHandles: false,
                  onReorder: (from, to) {
                    final order = [...slugs];
                    order.insert(to > from ? to - 1 : to, order.removeAt(from));
                    appPrefs.update((prefs) => prefs.providerOrder = order);
                  },
                  children: [
                    for (final (index, slug) in slugs.indexed)
                      Material(
                        key: ValueKey(slug),
                        type: MaterialType.transparency,
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
                          child: Row(
                            children: [
                              BrandBadge(slug: slug, size: 30),
                              const SizedBox(width: 13),
                              Expanded(
                                child: Text(
                                  streamingServices.firstWhere((service) => service.slug == slug).name,
                                  style: const TextStyle(fontSize: 16.5),
                                ),
                              ),
                              ReorderableDragStartListener(
                                index: index,
                                child: Padding(
                                  padding: EdgeInsets.all(8),
                                  child: CauceIcon(CauceGlyph.grip, size: 18, color: CauceColors.mutedForeground),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}
