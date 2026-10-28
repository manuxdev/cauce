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
import '../view_models/quick_connect.dart';

/// The text key of the help under the sign-in fields of `slug`.
String signInHelp(String slug) => switch (slug) {
  'jellyfin' => 'signIn.jellyfin.help',
  'emby' => 'signIn.emby.help',
  _ => 'signIn.server.help',
};

/// Signs in to a service through its own flow: a server and password for Subsonic, Jellyfin and
/// Emby, or a Quick Connect code for Jellyfin when the server offers it, a code to approve for
/// Tidal, an approval page for Spotify. Pops with the account's name once signed in.
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

  /// Whether the server typed in offers Quick Connect, asked a moment after the address stops changing.
  bool _quickConnect = false;
  Timer? _probe;

  /// The Quick Connect code on screen. Its secret lives only here, until it is traded for the account.
  core.QuickConnectCode? _quickCode;
  bool _expired = false;
  bool _quickWaiting = false;

  /// Bumped to stop the Quick Connect attempt under way.
  int _attempt = 0;

  bool get _asksServer => const {'subsonic', 'jellyfin', 'emby'}.contains(widget.service.slug);

  @override
  void initState() {
    super.initState();
    if (!_asksServer) _start();
  }

  @override
  void dispose() {
    if (!_done && _flow != null) core.signInCancel(slug: widget.service.slug).ignore();
    _flow?.cancel();
    _probe?.cancel();
    _server.dispose();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  void _start() {
    // Nothing may be waiting on it when the sign-in fails.
    _signedIn = Completer()..future.ignore();
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
        // Ended with no account and no error: still a failure, or the button stays disabled.
        .listen(_heard, onError: _failed, onDone: () => _flow != null && !_done ? _failed('sign-in ended') : null);
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
      _quickWaiting = true;
      _expired = false;
    });
    try {
      final code = await core.quickConnectStart(server: server);
      if (stopped()) return;
      setState(() => _quickCode = code);
      final end = await waitForQuickConnect(
        check: () => core.quickConnectCheck(server: server, secret: code.secret),
        cancelled: stopped,
      );
      switch (end) {
        case QuickConnectEnd.cancelled:
          return;
        case QuickConnectEnd.expired:
          setState(() {
            _quickCode = null;
            _expired = true;
            _quickWaiting = false;
          });
        case QuickConnectEnd.authorized:
          final name = await core.quickConnectSignIn(slug: widget.service.slug, server: server, secret: code.secret);
          _done = true;
          if (mounted) Navigator.of(context).pop(name);
      }
    } catch (error) {
      if (stopped()) return;
      _cancelQuickConnect();
      _toastFailure(error);
    }
  }

  void _cancelQuickConnect() => setState(() {
    _attempt++;
    _quickCode = null;
    _expired = false;
    _quickWaiting = false;
  });

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
    _toastFailure(error);
  }

  void _toastFailure(Object error) => showToast(
    Toast(
      title: translate('connect.failed'),
      detail: explainError(error),
      tone: ToastTone.error,
      glyph: CauceGlyph.close,
    ),
  );

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

  /// The Quick Connect code, large and spaced to read across the room, with what to do with it.
  List<Widget> _quickConnectView(BuildContext context) {
    final code = _quickCode?.code;
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
    final waiting = _flow != null || _quickWaiting;
    return SettingsPage(
      title: widget.service.name,
      back: context.t('search.cancel'),
      children: [
        if (_quickCode != null || _expired)
          ..._quickConnectView(context)
        else if (_asksServer) ...[
          SettingsGroup(
            footer: context.t(signInHelp(widget.service.slug)),
            children: [
              _field(_server, context.t('signIn.server'), type: TextInputType.url, onChanged: _serverChanged),
              _field(_username, context.t('signIn.username')),
              _field(_password, context.t('signIn.password'), secret: true),
            ],
          ),
          FilledButton(
            onPressed: !waiting && _server.text.trim().isNotEmpty && _username.text.trim().isNotEmpty ? _start : null,
            child: Text(context.t('integrations.connect')),
          ),
          if (_quickConnect)
            TextButton(onPressed: waiting ? null : _startQuickConnect, child: Text(context.t('signIn.quickConnect'))),
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
