import 'package:flutter/material.dart';

import '../../core/selected_service.dart';
import 'view_models/accounts_view_model.dart';
import 'views/audius_connect_screen.dart';
import 'views/flow_sign_in_screen.dart';
import 'views/plex_sign_in_screen.dart';

/// Signs in to `service` and makes it the service on screen.
Future<void> signIn(BuildContext context, StreamingService service, AccountsViewModel accounts) async {
  final name = await Navigator.of(context, rootNavigator: true).push<String>(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => switch (service.slug) {
        'plex' => PlexSignInScreen(service: service),
        'audius' => AudiusConnectScreen(service: service),
        _ => FlowSignInScreen(service: service),
      },
    ),
  );
  if (name == null) return;
  accounts.signedInAs(service.slug, name);
  selectedService.select(service.slug);
}
