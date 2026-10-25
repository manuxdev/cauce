import 'package:flutter/services.dart';

/// iOS notifications, for downloads that finish while the app is not on screen.
const _channel = MethodChannel('cauce/notifications');

/// Asks once whether the app may notify; iOS remembers the answer.
Future<void> askToNotify() => _channel.invokeMethod('ask').catchError((Object _) => null);

/// Shows a notification now, if the listener allowed them.
Future<void> notify(String title, String body) =>
    _channel.invokeMethod('post', {'title': title, 'body': body}).catchError((Object _) => null);
