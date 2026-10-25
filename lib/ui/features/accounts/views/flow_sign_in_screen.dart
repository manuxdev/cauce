import 'dart:async';

import 'package:flutter/material.dart';

import '../../../../src/rust/api/player.dart' as core;
import '../../../core/icons.dart';
import '../../../core/browser.dart';
import '../../../core/error_text.dart';
import '../../../core/l10n.dart';
import '../../../core/theme.dart';
import '../../../core/toast.dart';
import '../../settings/views/settings_widgets.dart';
import '../view_models/accounts_view_model.dart';

/// Signs in to a service through its own flow: a server and password for Subsonic, a code to
/// approve for Tidal, an approval page for Spotify. Pops with the account's name once signed in.
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
  StreamSubscription<core.SignInEvent>? _flow;

  /// Completes when the account is in, so an open approval page closes itself.
  Completer<void> _signedIn = Completer();
  String? _code;
  String? _url;
  bool _done = false;

  /// Whether the approval page is open, which closes itself before this screen can.
  bool _paging = false;

  bool get _asksServer => widget.service.slug == 'subsonic';

  @override
  void initState() {
    super.initState();
    if (!_asksServer) _start();
  }

  @override
  void dispose() {
    if (!_done && _flow != null) core.signInCancel(slug: widget.service.slug).ignore();
    _flow?.cancel();
    _server.dispose();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  void _start() {
    _signedIn = Completer();
    setState(() {
      _code = _url = null;
    });
    _flow = core
        .signInFlow(
          slug: widget.service.slug,
          server: _server.text.trim(),
          username: _username.text.trim(),
          password: _password.text,
        )
        .listen(_heard, onError: _failed);
  }

  void _heard(core.SignInEvent event) {
    if (event.name case final name?) {
      _done = true;
      if (!_signedIn.isCompleted) _signedIn.complete();
      if (_paging) Browser.close().ignore();
      _paging = false;
      Navigator.of(context).pop(name);
      return;
    }
    setState(() {
      _code = event.code;
      _url = event.url;
    });
    _approve();
  }

  void _failed(Object error) {
    if (!_signedIn.isCompleted) _signedIn.completeError(StateError('sign-in failed'));
    if (_paging) Browser.close().ignore();
    _paging = false;
    _flow = null;
    if (!mounted) return;
    setState(() => _code = _url = null);
    showToast(
      Toast(
        title: translate('connect.failed'),
        detail: explainError(error),
        tone: ToastTone.error,
        glyph: CauceGlyph.close,
      ),
    );
  }

  /// The page to approve on: Tidal names its host and the code, Spotify the whole address.
  String? get _page => switch ((_code, _url)) {
    (final code?, final url?) => 'https://${url.replaceFirst(RegExp('^https?://'), '')}/$code',
    (null, final url?) => url,
    _ => null,
  };

  void _approve() {
    final page = _page;
    if (page == null || _paging) return;
    _paging = true;
    Browser.open(
      page,
      // Closed by hand before the account came in: the sign-in is given up.
      onClosed: () {
        _paging = false;
        if (!_done) core.signInCancel(slug: widget.service.slug).ignore();
      },
    ).ignore();
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
    final waiting = _flow != null;
    return SettingsPage(
      title: widget.service.name,
      back: context.t('search.cancel'),
      children: [
        if (_asksServer) ...[
          SettingsGroup(
            footer: context.t('signIn.server.help'),
            children: [
              _field(_server, context.t('signIn.server'), type: TextInputType.url),
              _field(_username, context.t('signIn.username')),
              _field(_password, context.t('signIn.password'), secret: true),
            ],
          ),
          FilledButton(
            onPressed: !waiting && _server.text.trim().isNotEmpty && _username.text.trim().isNotEmpty ? _start : null,
            child: Text(context.t('integrations.connect')),
          ),
        ] else if (_code case final code?) ...[
          Padding(
            padding: const EdgeInsets.only(top: 24, bottom: 8),
            child: Text(
              code,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 34, fontWeight: FontWeight.w700, letterSpacing: 4),
            ),
          ),
          Text(
            context.t('signIn.code.help', {'url': _url ?? ''}),
            textAlign: TextAlign.center,
            style: TextStyle(color: CauceColors.mutedForeground),
          ),
          const SizedBox(height: 20),
          FilledButton(onPressed: _approve, child: Text(context.t('signIn.open'))),
        ] else if (_url != null) ...[
          const SizedBox(height: 20),
          FilledButton(onPressed: _approve, child: Text(context.t('signIn.open'))),
        ] else if (waiting)
          const Padding(
            padding: EdgeInsets.all(32),
            child: Center(child: CircularProgressIndicator()),
          )
        else
          FilledButton(onPressed: _start, child: Text(context.t('toast.retry'))),
      ],
    );
  }
}
