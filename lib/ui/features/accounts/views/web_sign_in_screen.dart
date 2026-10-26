import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../../../src/rust/api/player.dart' as core;
import '../../../core/icons.dart';
import '../../../core/l10n.dart';
import '../../../core/theme.dart';
import '../../../core/web_page.dart';
import '../../../core/widgets.dart';
import '../../../core/error_text.dart';

/// How often the cookie store is read while the user signs in. Single-page sign-ins finish
/// without a page load, so a load callback alone would miss them.
const _poll = Duration(seconds: 1);

/// Mobile Safari's agent rather than a provider's: a provider's is meant for desktop engines
/// (Deezer's is a Linux one), and one that does not match the iPhone's WebKit trips anti-bot checks.
const _agent = safariAgent;

/// Safari's own agent on a Mac, the one upstream's macOS window presents.
const _desktopAgent =
    'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15';

/// Asks Deezer's gateway for the session's `arl`. The web player on an iPhone's WebKit signs in
/// with its jwt cookies alone and never sets an `arl`, but the signed-in session hands one out.
/// Answers `{arl}` once it has one, or `{note}` saying where it stopped.
const _deezerArl = '''
try {
  const gateway = async (method, token) => {
    const query = new URLSearchParams({method, input: '3', api_version: '1.0', api_token: token});
    const response = await fetch('https://www.deezer.com/ajax/gw-light.php?' + query,
      {method: 'POST', credentials: 'include', body: '{}'});
    return await response.json();
  };
  const user = await gateway('deezer.getUserData', '');
  const id = user.results && user.results.USER && user.results.USER.USER_ID;
  if (!id) return {note: 'user ' + id + ' ' + JSON.stringify(user.error)};
  const arl = await gateway('user.getArl', user.results.checkForm);
  if (typeof arl.results === 'string' && arl.results) return {arl: arl.results};
  return {note: 'getArl ' + typeof arl.results + ' ' + JSON.stringify(arl.error)};
} catch (error) {
  return {note: 'threw ' + error};
}
''';

/// Runs a provider's cookie sign-in in a webview and pops with the account name once the core
/// accepts the cookies.
class WebSignInScreen extends StatefulWidget {
  const WebSignInScreen({super.key, required this.slug, required this.title, required this.login});

  final String slug;
  final String title;
  final core.WebLogin login;

  @override
  State<WebSignInScreen> createState() => _WebSignInScreenState();
}

class _WebSignInScreenState extends State<WebSignInScreen> {
  Timer? _timer;
  bool _checking = false;
  bool _retried = false;
  InAppWebViewController? _controller;
  String _status = '';

  /// The host the page is on, shown under the title so the user sees whose page it is.
  late String _host = Uri.tryParse(widget.login.url)?.host ?? '';

  /// Whether the provider signed the user in and Cauce is now connecting with that session,
  /// which can take a while with nothing changing on the page.
  bool _connecting = false;

  /// The core failed to connect after the page signed in; the user retries or leaves.
  bool _failed = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(_poll, (_) => _check());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  /// Loads the sign-in url again, once, when a page of the provider finishes without a session:
  /// a skipped hand-off leaves a blank page of the provider's that would never recover.
  Future<void> _retry(InAppWebViewController controller, WebUri? url) async {
    final host = url?.host ?? '';
    final login = widget.login;
    final ours = host == login.domain || host.endsWith('.${login.domain}');
    if (_retried || !ours || url.toString() == login.url) return;
    _retried = true;
    await controller.loadUrl(urlRequest: URLRequest(url: WebUri(login.url)));
  }

  /// The `arl` Deezer's gateway hands out, when the page is Deezer's, holds a session and no
  /// `arl` cookie came with it.
  Future<String?> _askDeezer(List<core.WebCookie> cookies) async {
    final controller = _controller;
    if (widget.slug != 'deezer' || controller == null) return null;
    if (cookies.any((cookie) => cookie.name == 'arl' && cookie.value.isNotEmpty)) return null;
    if (!cookies.any((cookie) => cookie.name == 'jwt')) return null;
    final url = await controller.getUrl();
    final result = await controller.callAsyncJavaScript(functionBody: _deezerArl);
    final value = result?.value;
    final arl = value is Map ? value['arl'] : null;
    final note = value is Map ? value['note'] : result?.error;
    // Never the arl itself: it is a credential.
    if (mounted) setState(() => _status = '${url?.host}${url?.path} · ${arl is String ? 'arl found' : note}');
    return arl is String && arl.isNotEmpty ? arl : null;
  }

  /// The webview's cookies. Android's store cannot list them all and names no domain, so there the
  /// provider's own domain is asked by url and stamped on each, which is all the core keeps anyway.
  Future<List<core.WebCookie>> _cookies() async {
    final store = CookieManager.instance();
    if (defaultTargetPlatform != TargetPlatform.android) {
      return [
        for (final cookie in await store.getAllCookies())
          if (cookie.domain != null)
            core.WebCookie(name: cookie.name, value: '${cookie.value ?? ''}', domain: cookie.domain!),
      ];
    }
    final domain = widget.login.domain;
    final found = <String, core.WebCookie>{};
    for (final url in ['https://$domain', 'https://www.$domain', 'https://music.$domain']) {
      for (final cookie in await store.getCookies(url: WebUri(url))) {
        found[cookie.name] = core.WebCookie(name: cookie.name, value: '${cookie.value ?? ''}', domain: '.$domain');
      }
    }
    return found.values.toList();
  }

  /// Whether the core signed in with the cookies so far.
  Future<bool> _check() async {
    if (_checking) return false;
    _checking = true;
    try {
      final cookies = await _cookies();
      final arl = await _askDeezer(cookies);
      if (arl != null) cookies.add(core.WebCookie(name: 'arl', value: arl, domain: '.deezer.com'));
      if (arl != null || cookies.any((cookie) => cookie.name == 'arl' && cookie.value.isNotEmpty)) {
        if (mounted) setState(() => _connecting = true);
      }
      final name = await core.signInWithCookies(slug: widget.slug, cookies: cookies);
      if (name != null && mounted) {
        _timer?.cancel();
        Navigator.of(context).pop(name);
      }
      return name != null;
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = explainError(error);
          _failed = _failed || _connecting;
        });
      }
    } finally {
      if (mounted && _connecting) setState(() => _connecting = false);
      _checking = false;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final page = Scaffold(
      backgroundColor: CauceColors.sheet,
      body: Column(
        children: [
          SafeArea(
            bottom: false,
            child: SizedBox(
              height: 56,
              child: NavigationToolbar(
                leading: TextButton(
                  onPressed: () => Navigator.of(context).maybePop(),
                  child: Text(context.t('search.cancel'), style: const TextStyle(fontSize: 16)),
                ),
                middle: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(widget.title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        CauceIcon(CauceGlyph.lock, size: 11, color: CauceColors.mutedForeground, weight: 2.2),
                        const SizedBox(width: 3),
                        Text(_host, style: TextStyle(fontSize: 12, color: CauceColors.mutedForeground)),
                      ],
                    ),
                  ],
                ),
                trailing: IconButton(
                  onPressed: () => _controller?.reload(),
                  icon: CauceIcon(CauceGlyph.retry, size: 20, color: CauceColors.accent, weight: 2.2),
                ),
              ),
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ),
          if (_status.isNotEmpty)
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text(_status, style: Theme.of(context).textTheme.bodySmall),
            ),
          if (_connecting)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                  const SizedBox(width: 12),
                  Expanded(child: Text(context.t('signIn.connecting'))),
                ],
              ),
            ),
          Expanded(
            child: InAppWebView(
              initialUrlRequest: URLRequest(url: WebUri(widget.login.url)),
              initialSettings: widget.slug == 'deezer'
                  // Signed in as a phone, Deezer hands off to its app, which a webview cannot
                  // open; as a Mac it lands on the web player that sets the arl.
                  ? InAppWebViewSettings(
                      userAgent: _desktopAgent,
                      preferredContentMode: UserPreferredContentMode.DESKTOP,
                      useShouldOverrideUrlLoading: true,
                      supportMultipleWindows: true,
                      javaScriptCanOpenWindowsAutomatically: true,
                    )
                  : InAppWebViewSettings(
                      userAgent: _agent,
                      useShouldOverrideUrlLoading: true,
                      supportMultipleWindows: true,
                      javaScriptCanOpenWindowsAutomatically: true,
                    ),
              // "Continue with Google" and the like sign in through a popup that answers its
              // opener, so it needs a real second window rather than a dropped request.
              onCreateWindow: (_, action) async {
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    fullscreenDialog: true,
                    builder: (context) => Scaffold(
                      backgroundColor: CauceColors.sheet,
                      appBar: AppBar(title: Text(widget.title), backgroundColor: CauceColors.sheet),
                      body: InAppWebView(
                        windowId: action.windowId,
                        initialSettings: InAppWebViewSettings(
                          userAgent: widget.slug == 'deezer' ? _desktopAgent : _agent,
                        ),
                        onCloseWindow: (_) => Navigator.of(context).maybePop(),
                      ),
                    ),
                  ),
                );
                return true;
              },
              shouldOverrideUrlLoading: (_, action) async {
                final url = action.request.url;
                if (url != null && url.scheme != 'https' && url.scheme != 'http' && url.scheme != 'about') {
                  if (mounted) {
                    final target = '${url.scheme}://${url.host}';
                    setState(() => _status = context.t('signIn.blockedHandOff', {'target': target}));
                  }
                  return NavigationActionPolicy.CANCEL;
                }
                return NavigationActionPolicy.ALLOW;
              },
              onWebViewCreated: (controller) => _controller = controller,
              onUpdateVisitedHistory: (_, url, _) {
                if (url != null && url.host.isNotEmpty && url.host != _host) setState(() => _host = url.host);
              },
              onLoadStop: (controller, url) async {
                if (!await _check()) await _retry(controller, url);
              },
            ),
          ),
          SafeArea(
            top: false,
            child: Container(
              margin: const EdgeInsets.fromLTRB(16, 10, 16, 6),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(color: CauceColors.muted, borderRadius: BorderRadius.circular(14)),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  CauceIcon(CauceGlyph.lock, size: 15, color: CauceColors.mutedForeground, weight: 2.1),
                  const SizedBox(width: 10),
                  Expanded(child: Text(context.t('signIn.private'), style: CauceText.caption)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
    return Stack(
      children: [
        page,
        Positioned.fill(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 260),
            child: _connecting || _failed
                ? _Connecting(
                    key: ValueKey(_failed),
                    service: widget.title,
                    failed: _failed,
                    onRetry: () {
                      setState(() => _failed = false);
                      _check();
                    },
                    onLeave: () => Navigator.of(context).pop(),
                  )
                : const SizedBox.shrink(),
          ),
        ),
      ],
    );
  }
}

/// Over the page once it has signed in: the core connecting, or why it could not, with a way to
/// try again or leave.
class _Connecting extends StatelessWidget {
  const _Connecting({
    super.key,
    required this.service,
    required this.failed,
    required this.onRetry,
    required this.onLeave,
  });

  final String service;
  final bool failed;
  final VoidCallback onRetry;
  final VoidCallback onLeave;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: CauceColors.background,
      child: DefaultTextStyle(
        style: TextStyle(color: CauceColors.foreground, decoration: TextDecoration.none),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 36),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (failed)
                  Container(
                    width: 52,
                    height: 52,
                    decoration: BoxDecoration(color: CauceColors.error.withValues(alpha: 0.18), shape: BoxShape.circle),
                    alignment: Alignment.center,
                    child: CauceIcon(CauceGlyph.alert, size: 22, color: CauceColors.error, weight: 2.2),
                  )
                else
                  SizedBox.square(
                    dimension: 34,
                    child: CircularProgressIndicator(strokeWidth: 3, color: CauceColors.accent),
                  ),
                const SizedBox(height: 22),
                Text(
                  context.t(failed ? 'signIn.failed' : 'signIn.connectingTo', {'service': service}),
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontFamily: displayFont, fontSize: 22, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 10),
                Text(
                  failed ? context.t('signIn.failed.detail', {'service': service}) : context.t('signIn.importing'),
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 15, height: 1.4, color: CauceColors.mutedForeground),
                ),
                if (failed) ...[
                  const SizedBox(height: 22),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      FilledButton(onPressed: onRetry, child: Text(context.t('common.retry'))),
                      const SizedBox(width: 10),
                      SoftButton(label: context.t('signIn.notNow'), onPressed: onLeave),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
