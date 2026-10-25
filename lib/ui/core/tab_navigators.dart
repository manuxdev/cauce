import 'package:flutter/widgets.dart';

/// One navigator per tab, so pages a tab opens stay under the mini player and the tab bar.
class TabNavigators {
  TabNavigators(int count) : keys = List.generate(count, (_) => GlobalKey<NavigatorState>());

  final List<GlobalKey<NavigatorState>> keys;
  int selected = 0;

  /// The navigator of the tab on screen.
  NavigatorState? get current => keys[selected].currentState;
}

final tabNavigators = TabNavigators(4);
