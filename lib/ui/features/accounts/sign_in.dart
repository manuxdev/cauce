import 'package:flutter/material.dart';

import '../../../src/rust/api/player.dart' as core;
import '../../core/selected_service.dart';
import 'view_models/accounts_view_model.dart';
import 'views/flow_sign_in_screen.dart';
import 'views/plex_sign_in_screen.dart';
import 'views/web_sign_in_screen.dart';

/// Signs in to `service` through its web page, or its own flow when it has none, and makes it
/// the service on screen.
Future<void> signIn(BuildContext context, StreamingService service, AccountsViewModel accounts) async {
  final login = service.slug == 'plex' ? null : await core.webSignIn(slug: service.slug);
  if (!context.mounted) return;
  final name = await Navigator.of(context, rootNavigator: true).push<String>(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => service.slug == 'plex'
          ? PlexSignInScreen(service: service)
          : login == null
          ? FlowSignInScreen(service: service)
          : WebSignInScreen(slug: service.slug, title: service.name, login: login),
    ),
  );
  if (name == null) return;
  accounts.signedInAs(service.slug, name);
  selectedService.select(service.slug);
}
