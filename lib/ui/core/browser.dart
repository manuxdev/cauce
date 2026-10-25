import 'package:flutter/services.dart';

/// Safari inside the app, through the native `cauce/browser` channel. Google signs in there
/// where it refuses a webview, and the app stays in front for a loopback redirect.
class Browser {
  static const _channel = MethodChannel('cauce/browser');
  static void Function()? _onClosed;

  /// Shows [url]; [onClosed] runs if the listener closes it by hand.
  static Future<void> open(String url, {required void Function() onClosed}) async {
    _onClosed = onClosed;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'closed') _onClosed?.call();
    });
    await _channel.invokeMethod('open', url);
  }

  static Future<void> close() async {
    _onClosed = null;
    await _channel.invokeMethod('close');
  }
}
