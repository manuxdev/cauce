import 'package:flutter/material.dart';

import '../features/accounts/view_models/accounts_view_model.dart';
import 'icons.dart';
import 'l10n.dart';
import 'motion.dart';
import 'theme.dart';
import 'tint.dart';

/// Whether the phone reaches the network, as the platform reports it.
final online = ValueNotifier<bool>(true);

/// What is still wrong, under a tab's header until it is put right: a service to sign in to again
/// (amber, it needs the listener) or no network (neutral, only informing). It pushes the page
/// down rather than covering it.
class StatusBands extends StatelessWidget {
  const StatusBands({super.key, required this.accounts, required this.onAccounts, this.onDownloads});

  final AccountsViewModel accounts;
  final VoidCallback onAccounts;

  /// Shows the downloads, which still play offline.
  final VoidCallback? onDownloads;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([accounts, online]),
      builder: (context, _) {
        final bands = [
          if (!online.value)
            _Band(
              key: const ValueKey('offline'),
              glyph: CauceGlyph.offline,
              strong: context.t('band.offline'),
              text: context.t('band.offline.detail'),
              action: onDownloads == null ? null : context.t('band.view'),
              onAction: onDownloads,
            )
          else
            for (final service in streamingServices)
              if (accounts.stored(service.slug) &&
                  !accounts.signedIn(service.slug) &&
                  !accounts.restoring(service.slug) &&
                  accounts.error(service.slug) != null)
                _Band(
                  key: ValueKey(service.slug),
                  glyph: CauceGlyph.alert,
                  strong: service.name,
                  text: context.t('band.expired'),
                  action: context.t('band.signIn'),
                  onAction: onAccounts,
                  amber: true,
                ),
        ];
        return AnimatedSize(
          duration: const Duration(milliseconds: 260),
          curve: CauceCurves.standard,
          alignment: Alignment.topCenter,
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 220),
            child: bands.isEmpty
                ? const SizedBox(width: double.infinity)
                : Padding(
                    key: ValueKey(bands.map((band) => band.key).join()),
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
                    child: Column(
                      children: [
                        for (final (index, band) in bands.indexed)
                          Padding(
                            padding: EdgeInsets.only(top: index == 0 ? 0 : 8),
                            child: band,
                          ),
                      ],
                    ),
                  ),
          ),
        );
      },
    );
  }
}

class _Band extends StatelessWidget {
  const _Band({
    super.key,
    required this.glyph,
    required this.strong,
    required this.text,
    this.action,
    this.onAction,
    this.amber = false,
  });

  final CauceGlyph glyph;

  /// What it is about, in bold before the rest.
  final String strong;
  final String text;
  final String? action;
  final VoidCallback? onAction;
  final bool amber;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minHeight: 48),
      padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
      decoration: BoxDecoration(
        color: amber ? oklch(0.36, 0.09, 70) : oklch(0.3, 0.015, 320),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          CauceIcon(glyph, size: 20, color: Colors.white, weight: 2.2),
          const SizedBox(width: 10),
          Expanded(
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: strong,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  TextSpan(text: ' · $text'),
                ],
              ),
              style: const TextStyle(fontSize: 14, height: 1.3, color: Colors.white),
            ),
          ),
          if (action case final action?)
            Pressable(
              scale: 0.94,
              onTap: onAction,
              child: Container(
                height: 36,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: amber
                    ? BoxDecoration(color: const Color(0x2EFFFFFF), borderRadius: BorderRadius.circular(11))
                    : null,
                alignment: Alignment.center,
                child: Text(
                  action,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: amber ? Colors.white : CauceColors.dark.accent,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
