import 'dart:async';

import 'package:flutter/material.dart';

import '../accounts/view_models/accounts_view_model.dart';
import 'connect_screen.dart';
import 'splash_screen.dart';

/// The splash for a moment, then the app, or the connect screen when no account is stored.
class AppGate extends StatefulWidget {
  const AppGate({super.key, required this.accounts, required this.app});

  final AccountsViewModel accounts;
  final Widget app;

  @override
  State<AppGate> createState() => _AppGateState();
}

class _AppGateState extends State<AppGate> {
  /// Long enough for the splash to be seen rather than flash by.
  static const _shortest = Duration(milliseconds: 1300);

  bool _shown = false;
  bool _skipped = false;
  late final Timer _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer(_shortest, () => setState(() => _shown = true));
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.accounts,
      builder: (context, _) {
        final accounts = widget.accounts;
        final connected = accounts.connected.isNotEmpty;
        final Widget page;
        // A stored account opens the app at once: reaching it can take long, or never happen
        // without a network, and the downloads play anyway.
        if (!_shown || !(connected || accounts.settled || accounts.anyStored)) {
          page = const SplashScreen(key: ValueKey('splash'));
        } else if (!connected && !accounts.anyStored && !_skipped) {
          page = ConnectScreen(
            key: const ValueKey('connect'),
            accounts: accounts,
            onSkip: () => setState(() => _skipped = true),
          );
        } else {
          page = KeyedSubtree(key: const ValueKey('app'), child: widget.app);
        }
        return AnimatedSwitcher(duration: const Duration(milliseconds: 450), child: page);
      },
    );
  }
}
