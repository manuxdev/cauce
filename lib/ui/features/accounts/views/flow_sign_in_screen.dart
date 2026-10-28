import 'dart:async';

import 'package:flutter/material.dart';

import '../../../../src/rust/api/player.dart' as core;
import '../../../core/icons.dart';
import '../../../core/error_text.dart';
import '../../../core/l10n.dart';
import '../../../core/theme.dart';
import '../../../core/toast.dart';
import '../../settings/views/settings_widgets.dart';
import '../view_models/accounts_view_model.dart';
import '../view_models/quick_connect.dart';

/// The text key of the help under the sign-in fields of `slug`.
String signInHelp(String slug) => switch (slug) {
  'jellyfin' => 'signIn.jellyfin.help',
  'emby' => 'signIn.emby.help',
  _ => 'signIn.server.help',
};

/// Signs in to a service with a server, username and password, as Subsonic, Jellyfin and Emby do, or to Jellyfin
/// with a Quick Connect code when the server offers it. Pops with the account's name once signed in.
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

  /// Whether the server typed in offers Quick Connect, asked a moment after the address stops changing.
  bool _quickConnect = false;
  Timer? _probe;

  /// The code on screen. Its secret lives only here, until it is traded for the account.
  core.QuickConnectCode? _code;
  bool _expired = false;

  /// Bumped to stop the Quick Connect attempt under way.
  int _attempt = 0;

  @override
  void dispose() {
    _probe?.cancel();
    _server.dispose();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  void _serverChanged() {
    setState(() {});
    if (widget.service.slug != 'jellyfin') return;
    _probe?.cancel();
    _quickConnect = false;
    final server = _server.text.trim();
    if (server.isEmpty) return;
    _probe = Timer(const Duration(milliseconds: 600), () async {
      final enabled = await core.quickConnectEnabled(server: server).catchError((_) => false);
      if (mounted && _server.text.trim() == server) setState(() => _quickConnect = enabled);
    });
  }

  Future<void> _startQuickConnect() async {
    final attempt = ++_attempt;
    final server = _server.text.trim();
    bool stopped() => !mounted || attempt != _attempt;
    setState(() {
      _waiting = true;
      _expired = false;
    });
    try {
      final code = await core.quickConnectStart(server: server);
      if (stopped()) return;
      setState(() => _code = code);
      final end = await waitForQuickConnect(
        check: () => core.quickConnectCheck(server: server, secret: code.secret),
        cancelled: stopped,
      );
      switch (end) {
        case QuickConnectEnd.cancelled:
          return;
        case QuickConnectEnd.expired:
          setState(() {
            _code = null;
            _expired = true;
            _waiting = false;
          });
        case QuickConnectEnd.authorized:
          final name = await core.quickConnectSignIn(slug: widget.service.slug, server: server, secret: code.secret);
          if (mounted) Navigator.of(context).pop(name);
      }
    } catch (error) {
      if (stopped()) return;
      _cancelQuickConnect();
      _failed(error);
    }
  }

  void _cancelQuickConnect() => setState(() {
    _attempt++;
    _code = null;
    _expired = false;
    _waiting = false;
  });

  void _failed(Object error) => showToast(
    Toast(
      title: translate('connect.failed'),
      detail: explainError(error),
      tone: ToastTone.error,
      glyph: CauceGlyph.close,
    ),
  );

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
      _failed(error);
    }
  }

  Widget _field(
    TextEditingController controller,
    String hint, {
    bool secret = false,
    TextInputType? type,
    VoidCallback? onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: TextField(
        controller: controller,
        autocorrect: false,
        enableSuggestions: false,
        obscureText: secret,
        keyboardType: type,
        onChanged: (_) => onChanged != null ? onChanged() : setState(() {}),
        decoration: InputDecoration.collapsed(hintText: hint),
      ),
    );
  }

  /// The code, large and spaced to read across the room, with what to do with it.
  List<Widget> _quickConnectView(BuildContext context) {
    final code = _code?.code;
    return [
      SettingsGroup(
        footer: context.t(code == null ? 'signIn.quickConnect.expired' : 'signIn.quickConnect.help'),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
            child: Center(
              child: code == null
                  ? Text(context.t('signIn.quickConnect.expiredTitle'), style: CauceText.section)
                  : Column(
                      children: [
                        Semantics(
                          label: code.split('').join(' '),
                          excludeSemantics: true,
                          child: Text(
                            code,
                            style: CauceText.largeTitle.copyWith(
                              fontSize: 44,
                              letterSpacing: 8,
                              fontFeatures: const [FontFeature.tabularFigures()],
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                            const SizedBox(width: 8),
                            Text(context.t('signIn.quickConnect.waiting'), style: CauceText.caption),
                          ],
                        ),
                      ],
                    ),
            ),
          ),
        ],
      ),
      if (code == null)
        FilledButton(onPressed: _startQuickConnect, child: Text(context.t('signIn.quickConnect.retry'))),
      TextButton(onPressed: _cancelQuickConnect, child: Text(context.t('search.cancel'))),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return SettingsPage(
      title: widget.service.name,
      back: context.t('search.cancel'),
      children: _code != null || _expired
          ? _quickConnectView(context)
          : [
              SettingsGroup(
                footer: context.t(signInHelp(widget.service.slug)),
                children: [
                  _field(_server, context.t('signIn.server'), type: TextInputType.url, onChanged: _serverChanged),
                  _field(_username, context.t('signIn.username')),
                  _field(_password, context.t('signIn.password'), secret: true),
                ],
              ),
              FilledButton(
                onPressed: !_waiting && _server.text.trim().isNotEmpty && _username.text.trim().isNotEmpty
                    ? _start
                    : null,
                child: Text(context.t('integrations.connect')),
              ),
              if (_quickConnect)
                TextButton(
                  onPressed: _waiting ? null : _startQuickConnect,
                  child: Text(context.t('signIn.quickConnect')),
                ),
            ],
    );
  }
}
