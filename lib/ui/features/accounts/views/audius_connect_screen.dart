import 'package:flutter/material.dart';

import '../../../../src/rust/api/player.dart' as core;
import '../../../core/error_text.dart';
import '../../../core/icons.dart';
import '../../../core/l10n.dart';
import '../../../core/theme.dart';
import '../../../core/toast.dart';
import '../../../core/web_page.dart';
import '../../settings/views/settings_widgets.dart';
import '../view_models/accounts_view_model.dart';

/// The pages Audius's API terms have the app hand its listeners, and the license its music
/// plays under, as text key and address.
const audiusDocuments = [
  ('audius.apiTerms', 'https://audius.co/legal/api-terms'),
  ('audius.privacy', 'https://audius.co/legal/privacy-policy'),
  ('audius.license', 'https://openaudiofoundation.org/open-music-license.pdf'),
];

/// Who Audius's music belongs to, with its terms, privacy policy and music license a tap away.
class AudiusTerms extends StatelessWidget {
  const AudiusTerms({super.key});

  @override
  Widget build(BuildContext context) {
    return SettingsGroup(
      title: context.t('audius.terms'),
      footer: context.t('audius.attribution'),
      children: [
        for (final (label, url) in audiusDocuments)
          SettingsRow(
            title: context.t(label),
            trailing: CauceIcon(CauceGlyph.external, size: 16, color: CauceColors.mutedForeground),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => WebPage(title: context.t(label), url: url),
              ),
            ),
          ),
      ],
    );
  }
}

/// Connects Audius, which asks for no account, once the listener has seen its terms. Pops with
/// the name the provider goes by.
class AudiusConnectScreen extends StatefulWidget {
  const AudiusConnectScreen({super.key, required this.service});

  final StreamingService service;

  @override
  State<AudiusConnectScreen> createState() => _AudiusConnectScreenState();
}

class _AudiusConnectScreenState extends State<AudiusConnectScreen> {
  bool _waiting = false;

  Future<void> _connect() async {
    setState(() => _waiting = true);
    try {
      final name = await core.signIn(slug: widget.service.slug, server: '', username: '', password: '');
      if (mounted) Navigator.of(context).pop(name);
    } catch (error) {
      if (!mounted) return;
      setState(() => _waiting = false);
      showToast(
        Toast(
          title: translate('connect.failed'),
          detail: explainError(error),
          tone: ToastTone.error,
          glyph: CauceGlyph.close,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return SettingsPage(
      title: widget.service.name,
      back: context.t('search.cancel'),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 4, 4, 18),
          child: Text(context.t('audius.connect.detail'), style: CauceText.caption),
        ),
        const AudiusTerms(),
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 12),
          child: Text(context.t('audius.connect.agree'), style: CauceText.caption),
        ),
        FilledButton(onPressed: _waiting ? null : _connect, child: Text(context.t('integrations.connect'))),
      ],
    );
  }
}
