import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'theme.dart';

/// Mobile Safari's own user agent. Google refuses "Continue with Google" in a webview whose
/// agent lacks Safari's `Version/… Safari/…` tail.
const safariAgent =
    'Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Mobile/15E148 Safari/604.1';

/// A page of a service's site. With [waiting], it closes itself with whether that finished,
/// and hands the approval's loopback callback to the core's listener itself, since the webview
/// will not load plain http.
class WebPage extends StatefulWidget {
  const WebPage({super.key, required this.title, required this.url, this.waiting});

  final String title;
  final String url;
  final Future<void>? waiting;

  @override
  State<WebPage> createState() => _WebPageState();
}

class _WebPageState extends State<WebPage> {
  @override
  void initState() {
    super.initState();
    widget.waiting?.then(
      (_) => mounted ? Navigator.of(context).pop(true) : null,
      onError: (Object _) => mounted ? Navigator.of(context).pop(false) : null,
    );
  }

  Future<void> _deliver(Uri callback) async {
    final client = HttpClient();
    try {
      await (await client.getUrl(callback)).close();
    } on Object {
      // The listener gave up; the wait ends with its own error.
    } finally {
      client.close();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: CauceColors.settingsBackground,
      appBar: AppBar(title: Text(widget.title), backgroundColor: CauceColors.settingsBackground),
      body: InAppWebView(
        initialUrlRequest: URLRequest(url: WebUri(widget.url)),
        initialSettings: InAppWebViewSettings(
          userAgent: safariAgent,
          useShouldOverrideUrlLoading: widget.waiting != null,
          supportMultipleWindows: true,
          javaScriptCanOpenWindowsAutomatically: true,
        ),
        // "Continue with Google" signs in through a popup that answers its opener, so it needs a
        // real second window rather than a dropped request.
        onCreateWindow: (_, action) async {
          Navigator.of(context).push(
            MaterialPageRoute<void>(
              fullscreenDialog: true,
              builder: (popup) => Scaffold(
                backgroundColor: CauceColors.sheet,
                appBar: AppBar(title: Text(widget.title), backgroundColor: CauceColors.sheet),
                body: InAppWebView(
                  windowId: action.windowId,
                  initialSettings: InAppWebViewSettings(userAgent: safariAgent),
                  onCloseWindow: (_) => Navigator.of(popup).maybePop(),
                ),
              ),
            ),
          );
          return true;
        },
        shouldOverrideUrlLoading: (_, action) async {
          final url = action.request.url;
          if (url == null || url.host != '127.0.0.1') return NavigationActionPolicy.ALLOW;
          _deliver(url.uriValue);
          return NavigationActionPolicy.CANCEL;
        },
      ),
    );
  }
}
