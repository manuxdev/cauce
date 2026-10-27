import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:cauce/ui/core/app_prefs.dart';
import 'package:cauce/ui/core/status_band.dart';

void main() {
  test('the app is online only when the phone is and offline mode is off', () {
    for (final (device, offlineMode, expected) in [
      (true, false, true),
      (true, true, false),
      (false, false, false),
      (false, true, false),
    ]) {
      final online = EffectiveOnline(ValueNotifier(device), AppPrefs()..offlineMode = offlineMode);
      expect(online.value, expected, reason: 'device $device, offline mode $offlineMode');
    }
  });

  test('it follows the phone and the switch as they change, and says so', () {
    final device = ValueNotifier(true);
    final prefs = AppPrefs();
    final online = EffectiveOnline(device, prefs);
    final heard = <bool>[];
    online.addListener(() => heard.add(online.value));

    prefs.update((prefs) => prefs.offlineMode = true);
    device.value = false;
    prefs.update((prefs) => prefs.offlineMode = false);
    device.value = true;

    expect(heard, [false, true]);
  });
}
