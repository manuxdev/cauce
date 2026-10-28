import 'package:flutter/material.dart';

import '../../../src/rust/api/player.dart' as core;
import '../../core/selected_service.dart';
import 'view_models/accounts_view_model.dart';
import 'views/audius_connect_screen.dart';
import 'views/flow_sign_in_screen.dart';
import 'views/plex_sign_in_screen.dart';
import 'views/web_sign_in_screen.dart';

/// Signs in to `service` through its web page, or its own flow when it has none, and makes it
/// the service on screen.
Future<void> signIn(BuildContext context, StreamingService service, AccountsViewModel accounts) async {
  // Plex and Audius have flows of their own, with no web page to sign in on.
  final login = const {'plex', 'audius'}.contains(service.slug) ? null : await core.webSignIn(slug: service.slug);
  if (!context.mounted) return;
  final name = await Navigator.of(context, rootNavigator: true).push<String>(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => switch (service.slug) {
        'plex' => PlexSignInScreen(service: service),
        'audius' => AudiusConnectScreen(service: service),
        _ when login != null => WebSignInScreen(slug: service.slug, title: service.name, login: login),
        _ => FlowSignInScreen(service: service),
      },
    ),
  );
  if (name == null) return;
  accounts.signedInAs(service.slug, name);
  selectedService.select(service.slug);
}
