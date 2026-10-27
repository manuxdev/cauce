import 'package:flutter/material.dart';

import '../../../../src/rust/api/player.dart' as core;
import '../../../core/icons.dart';
import '../../../core/error_text.dart';
import '../../../core/l10n.dart';
import '../../../core/toast.dart';
import '../../settings/views/settings_widgets.dart';
import '../view_models/accounts_view_model.dart';

/// The text key of the help under the sign-in fields of `slug`.
String signInHelp(String slug) => switch (slug) {
  'jellyfin' => 'signIn.jellyfin.help',
  _ => 'signIn.server.help',
};

/// Signs in to a service with a server, username and password, as Subsonic and Jellyfin do. Pops with the
/// account's name once signed in.
class FlowSignInScreen extends StatefulWidget {
  const FlowSignInScreen({super.key, required this.service});

  final StreamingService service;

  @override
  State<FlowSignInScreen> createState() => _FlowSignInScreenState();
}

class _FlowSignInScreenState extends State<FlowSignInScreen> {
  final _server = TextEditingController();
  final _username = TextEditingController();
  final _password = TextEditingController();
  bool _waiting = false;

  @override
  void dispose() {
    _server.dispose();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    setState(() => _waiting = true);
    try {
      final name = await core.signIn(
        slug: widget.service.slug,
        server: _server.text.trim(),
        username: _username.text.trim(),
        password: _password.text,
      );
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

  Widget _field(TextEditingController controller, String hint, {bool secret = false, TextInputType? type}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: TextField(
        controller: controller,
        autocorrect: false,
        enableSuggestions: false,
        obscureText: secret,
        keyboardType: type,
        onChanged: (_) => setState(() {}),
        decoration: InputDecoration.collapsed(hintText: hint),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SettingsPage(
      title: widget.service.name,
      back: context.t('search.cancel'),
      children: [
        SettingsGroup(
          footer: context.t(signInHelp(widget.service.slug)),
          children: [
            _field(_server, context.t('signIn.server'), type: TextInputType.url),
            _field(_username, context.t('signIn.username')),
            _field(_password, context.t('signIn.password'), secret: true),
          ],
        ),
        FilledButton(
          onPressed: !_waiting && _server.text.trim().isNotEmpty && _username.text.trim().isNotEmpty ? _start : null,
          child: Text(context.t('integrations.connect')),
        ),
      ],
    );
  }
}
