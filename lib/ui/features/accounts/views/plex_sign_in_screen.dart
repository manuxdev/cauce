import 'package:flutter/material.dart';

import '../../../../src/rust/api/player.dart' as core;
import '../../../core/error_text.dart';
import '../../../core/icons.dart';
import '../../../core/l10n.dart';
import '../../../core/theme.dart';
import '../../../core/toast.dart';
import '../../../core/web_page.dart';
import '../../settings/views/settings_widgets.dart';
import '../view_models/accounts_view_model.dart';
import '../view_models/plex_sign_in.dart';
import '../view_models/quick_connect.dart';

/// Signs in to Plex through plex.tv: Plex's own page approves the sign-in, then the listener picks one of the
/// account's servers if it has several. Pops with the account's name once signed in. The plex.tv token never reaches
/// this screen: the core holds it until a server is picked.
class PlexSignInScreen extends StatefulWidget {
  const PlexSignInScreen({super.key, required this.service});

  final StreamingService service;

  @override
  State<PlexSignInScreen> createState() => _PlexSignInScreenState();
}

class _PlexSignInScreenState extends State<PlexSignInScreen> {
  bool _busy = false;

  /// The account's servers to pick from, once approved with more than one.
  List<core.PlexServer>? _servers;
  bool _done = false;

  @override
  void dispose() {
    if (!_done) core.plexCancel();
    super.dispose();
  }

  void _failed(String detail) => showToast(
    Toast(title: translate('connect.failed'), detail: detail, tone: ToastTone.error, glyph: CauceGlyph.close),
  );

  Future<void> _start() async {
    setState(() => _busy = true);
    try {
      final page = await core.plexStart();
      if (!mounted) return;
      var open = true;
      final end = waitForPlexPin(check: core.plexCheck, cancelled: () => !open || !mounted);
      final approved = await Navigator.of(context).push<bool>(
        MaterialPageRoute(
          builder: (_) => WebPage(
            title: context.t('signIn.title', {'service': widget.service.name}),
            url: page,
            waiting: end.then((end) {
              if (end != QuickConnectEnd.authorized) throw StateError('not approved');
            }),
          ),
        ),
      );
      open = false;
      if (approved != true) {
        if (await end == QuickConnectEnd.expired) _failed(translate('signIn.plex.expired'));
        return;
      }
      final servers = await core.plexServers();
      if (servers.isEmpty) return _failed(translate('signIn.plex.noServers'));
      final only = serverToPick(servers);
      if (only != null) return await _signIn(only);
      if (mounted) setState(() => _servers = servers);
    } catch (error) {
      if (mounted) _failed(explainError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _signIn(core.PlexServer server) async {
    setState(() => _busy = true);
    try {
      final name = await core.plexSignIn(serverId: server.id);
      _done = true;
      if (mounted) Navigator.of(context).pop(name);
    } catch (error) {
      if (mounted) _failed(explainError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final servers = _servers;
    return SettingsPage(
      title: widget.service.name,
      back: context.t('search.cancel'),
      children: servers == null
          ? [
              SettingsGroup(
                footer: context.t('signIn.plex.help'),
                children: [
                  SettingsRow(
                    title: context.t('signIn.plex'),
                    titleColor: CauceColors.accent,
                    enabled: !_busy,
                    onTap: _busy ? null : _start,
                  ),
                ],
              ),
            ]
          : [
              SettingsGroup(
                title: context.t('signIn.plex.servers'),
                footer: context.t('signIn.plex.serversHelp'),
                children: [
                  for (final server in servers)
                    SettingsRow(
                      title: server.name,
                      subtitle: server.owned ? null : context.t('signIn.plex.shared'),
                      enabled: !_busy,
                      onTap: _busy ? null : () => _signIn(server),
                    ),
                ],
              ),
            ],
    );
  }
}
