import 'package:flutter/material.dart';

import '../../../../src/rust/api/player.dart' as core;
import '../../../core/icons.dart';
import '../../../core/l10n.dart';
import '../../../core/theme.dart';
import '../../../core/toast.dart';
import '../../../core/web_page.dart';
import '../../../core/widgets.dart';
import 'settings_widgets.dart';

/// How each scrobbling service is named and badged.
const _services = {
  'lastfm': ('Last.fm', 'La', Color(0xFFD0262E)),
  'listenbrainz': ('ListenBrainz', 'Li', Color(0xFFB0620F)),
};

/// The scrobbling services: linking, switching each on and off, and whether local files count.
class IntegrationsScreen extends StatefulWidget {
  const IntegrationsScreen({super.key});

  @override
  State<IntegrationsScreen> createState() => _IntegrationsScreenState();
}

class _IntegrationsScreenState extends State<IntegrationsScreen> {
  List<core.ScrobbleRow> _rows = const [];
  bool _localFiles = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final (rows, localFiles) = await core.scrobbling();
    if (!mounted) return;
    setState(() {
      _rows = rows;
      _localFiles = localFiles;
    });
  }

  Future<void> _link(core.ScrobbleRow row) async {
    final linked = await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => _LinkScreen(row: row)));
    if (linked != true) return;
    showToast(Toast(title: translate('band.connected', {'name': _services[row.id]!.$1}), glyph: CauceGlyph.check));
    _load();
  }

  Future<void> _unlink(core.ScrobbleRow row) async {
    final name = _services[row.id]!.$1;
    final sure = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        backgroundColor: CauceColors.sheet,
        title: Text(context.t('integrations.disconnect.ask', {'name': name})),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialog).pop(false), child: Text(context.t('search.cancel'))),
          TextButton(
            onPressed: () => Navigator.of(dialog).pop(true),
            style: TextButton.styleFrom(foregroundColor: CauceColors.error),
            child: Text(context.t('integrations.disconnect')),
          ),
        ],
      ),
    );
    if (sure != true) return;
    await core.scrobbleDisconnect(service: row.id);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    return SettingsPage(
      title: context.t('settings.integrations'),
      children: [
        SettingsGroup(
          title: context.t('integrations.scrobbling'),
          footer: context.t('integrations.footer'),
          children: [
            for (final row in _rows)
              if (_services[row.id] case (final name, final letters, final color))
                SettingsRow(
                  leading: _Badge(letters: letters, color: color),
                  title: name,
                  subtitle: row.linked
                      ? context.t('integrations.connected', {'user': row.user})
                      : context.t('integrations.${row.id}.detail'),
                  onTap: row.linked ? () => _unlink(row) : null,
                  trailing: row.linked
                      ? Switch(
                          value: row.enabled,
                          onChanged: (on) async {
                            await core.scrobbleEnable(service: row.id, enabled: on);
                            _load();
                          },
                        )
                      : SoftButton(label: context.t('integrations.connect'), onPressed: () => _link(row)),
                ),
            SettingsSwitch(
              title: context.t('integrations.localFiles'),
              value: _localFiles,
              onChanged: (on) async {
                await core.scrobbleLocalFiles(on_: on);
                _load();
              },
            ),
          ],
        ),
      ],
    );
  }
}

/// The service's initials on its colour, where other rows have a glyph.
class _Badge extends StatelessWidget {
  const _Badge({required this.letters, required this.color});

  final String letters;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 30,
      height: 30,
      decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(8)),
      alignment: Alignment.center,
      child: Text(
        letters,
        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Colors.white),
      ),
    );
  }
}

/// Asks for what linking a service takes: an API key and secret, approved on the service's page,
/// or a pasted token. Pops `true` once the account is linked.
class _LinkScreen extends StatefulWidget {
  const _LinkScreen({required this.row});

  final core.ScrobbleRow row;

  @override
  State<_LinkScreen> createState() => _LinkScreenState();
}

class _LinkScreenState extends State<_LinkScreen> {
  final _key = TextEditingController();
  final _secret = TextEditingController();
  final _token = TextEditingController();
  bool _busy = false;

  bool get _keys => widget.row.link == 'keys';
  String get _name => _services[widget.row.id]!.$1;

  @override
  void dispose() {
    _key.dispose();
    _secret.dispose();
    _token.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    final typed = core.ScrobbleSecret(key: _key.text, secret: _secret.text, token: _token.text, server: '');
    final service = widget.row.id;
    setState(() => _busy = true);
    try {
      if (_keys) {
        final approval = await core.scrobbleApproval(service: service, link: widget.row.link, typed: typed);
        if (approval == null || !mounted) throw StateError('no approval page');
        // The core listens for the approval before the page can hand it back.
        final linking = core.scrobbleConnect(service: service, link: widget.row.link, typed: typed);
        final linked = await Navigator.of(context).push<bool>(
          MaterialPageRoute(
            builder: (_) =>
                WebPage(title: context.t('integrations.approve', {'name': _name}), url: approval, waiting: linking),
          ),
        );
        if (linked != true) {
          await core.scrobbleCancel();
          return;
        }
      } else {
        await core.scrobbleConnect(service: service, link: widget.row.link, typed: typed);
      }
      if (mounted) Navigator.of(context).pop(true);
    } on Object {
      showToast(
        Toast(title: translate('integrations.failed', {'name': _name}), tone: ToastTone.error, glyph: CauceGlyph.close),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _field(TextEditingController controller, String hint) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: TextField(
        controller: controller,
        autocorrect: false,
        enableSuggestions: false,
        onChanged: (_) => setState(() {}),
        decoration: InputDecoration.collapsed(hintText: hint),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ready = _keys ? _key.text.trim().isNotEmpty && _secret.text.trim().isNotEmpty : _token.text.trim().isNotEmpty;
    final signup = widget.row.signup;
    return SettingsPage(
      title: _name,
      back: context.t('settings.integrations'),
      children: [
        SettingsGroup(
          footer: context.t(_keys ? 'integrations.keys.help' : 'integrations.token.help'),
          children: [
            if (_keys) ...[
              _field(_key, context.t('integrations.apiKey')),
              _field(_secret, context.t('integrations.apiSecret')),
            ] else
              _field(_token, context.t('integrations.token')),
          ],
        ),
        if (signup != null)
          SettingsGroup(
            children: [
              SettingsRow(
                title: context.t(_keys ? 'integrations.getKeys' : 'integrations.getToken'),
                titleColor: CauceColors.accent,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => WebPage(title: _name, url: signup),
                  ),
                ),
              ),
            ],
          ),
        FilledButton(onPressed: ready && !_busy ? _connect : null, child: Text(context.t('integrations.connect'))),
      ],
    );
  }
}
