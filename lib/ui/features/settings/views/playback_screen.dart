import 'package:flutter/material.dart';

import '../../../core/motion.dart';
import '../../../../src/rust/api/player.dart' as core;
import '../../../core/app_scope.dart';
import '../../../core/l10n.dart';
import '../../../core/selected_service.dart';
import '../../accounts/view_models/accounts_view_model.dart';
import '../../player/view_models/player_view_model.dart';
import '../view_models/playback_settings_view_model.dart';
import 'equalizer_screen.dart';
import 'settings_widgets.dart';

/// How tracks follow each other, the sound, the stream quality on each network, the queue,
/// headphones and the sleep timer.
class PlaybackScreen extends StatelessWidget {
  const PlaybackScreen({super.key, required this.accounts, required this.playback});

  final AccountsViewModel accounts;
  final PlaybackSettingsViewModel playback;

  @override
  Widget build(BuildContext context) {
    final player = AppScope.of(context).player;
    return ListenableBuilder(
      listenable: Listenable.merge([playback, accounts, selectedService, player, player.sleep]),
      builder: (context, _) {
        final settings = playback.settings;
        if (settings == null) return SettingsPage(title: context.t('settings.playback'), children: const []);
        return SettingsPage(
          title: context.t('settings.playback'),
          children: [
            SettingsGroup(
              title: context.t('playback.transitions'),
              footer: context.t('playback.transitions.detail'),
              children: [
                SettingsSwitch(
                  title: context.t('playback.gapless'),
                  value: settings.gapless,
                  onChanged: (on) => playback.update(gapless: on),
                ),
                SettingsSwitch(
                  title: context.t('playback.normalisation'),
                  value: settings.normalisation,
                  onChanged: (on) => playback.update(normalisation: on),
                ),
              ],
            ),
            SettingsGroup(
              title: context.t('playback.sound'),
              children: [
                SettingsRow(
                  title: context.t('playback.equalizer'),
                  value: settings.equalizer
                      ? switch (playback.preset) {
                          final preset? => context.t('preset.${preset.id}'),
                          null => context.t('equalizer.custom'),
                        }
                      : context.t('common.off'),
                  onTap: () => Navigator.of(
                    context,
                  ).push(MaterialPageRoute<void>(builder: (_) => EqualizerScreen(playback: playback))),
                ),
              ],
            ),
            SettingsGroup(
              title: context.t('playback.quality'),
              children: [
                _QualityRow(
                  title: context.t('playback.quality.wifi'),
                  quality: settings.quality,
                  accounts: accounts,
                  onPick: (id) => playback.update(quality: id),
                ),
                _QualityRow(
                  title: context.t('playback.quality.cellular'),
                  quality: settings.qualityCellular,
                  accounts: accounts,
                  onPick: (id) => playback.update(qualityCellular: id),
                ),
                SettingsSwitch(
                  title: context.t('playback.dataSaver'),
                  subtitle: context.t('playback.dataSaver.detail'),
                  value: settings.dataSaver,
                  onChanged: (on) => playback.update(dataSaver: on),
                ),
              ],
            ),
            SettingsGroup(
              title: context.t('player.queue'),
              children: [
                SettingsSwitch(
                  title: context.t('playback.similar'),
                  subtitle: context.t('playback.similar.detail'),
                  value: settings.continueSimilar,
                  onChanged: (on) => playback.update(continueSimilar: on),
                ),
                SettingsSwitch(
                  title: context.t('playback.rememberRepeat'),
                  value: settings.rememberRepeat,
                  onChanged: (on) => playback.update(rememberRepeat: on),
                ),
              ],
            ),
            SettingsGroup(
              title: context.t('playback.headphones'),
              children: [
                SettingsSwitch(
                  title: context.t('playback.resumeOnConnect'),
                  value: settings.resumeOnConnect,
                  onChanged: (on) => playback.update(resumeOnConnect: on),
                ),
              ],
            ),
            SettingsGroup(
              title: context.t('playback.sleep'),
              children: [
                SettingsRow(
                  title: context.t('playback.sleep.stop'),
                  value: _sleepValue(context, player),
                  onTap: () => showSleepTimer(context, player),
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}

/// What the sleep timer is set to, as its row shows it.
String _sleepValue(BuildContext context, PlayerViewModel player) {
  if (player.stopsAfterCurrent) return context.t('sleep.endOfTrack');
  if (!player.sleep.active) return context.t('common.off');
  final left = player.sleep.left;
  return left.inMinutes >= 1
      ? context.t('sleep.minutesLeft', {'count': left.inMinutes + 1})
      : context.t('sleep.secondsLeft', {'count': left.inSeconds});
}

/// The sleep timer's choices in a sheet: off, a time, or the end of the track.
Future<void> showSleepTimer(BuildContext context, PlayerViewModel player) {
  const minutes = [5, 10, 15, 30, 45, 60, 90];
  return showModalBottomSheet<void>(
    sheetAnimationStyle: sheetAnimation,
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    builder: (sheet) {
      void pick(VoidCallback choose) {
        choose();
        Navigator.of(sheet).pop();
      }

      final off = !player.sleep.active && !player.stopsAfterCurrent;
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
          child: SettingsGroup(
            title: context.t('playback.sleep.stop'),
            children: [
              SettingsRow(
                title: context.t('common.off'),
                trailing: off ? pickedMark : null,
                onTap: () => pick(() {
                  player.sleep.cancel();
                  player.stopAfterCurrent(false);
                }),
              ),
              for (final count in minutes)
                SettingsRow(
                  title: context.t('sleep.minutes', {'count': count}),
                  onTap: () => pick(() {
                    player.stopAfterCurrent(false);
                    player.sleep.start(Duration(minutes: count));
                  }),
                ),
              SettingsRow(
                title: context.t('sleep.endOfTrack'),
                trailing: player.stopsAfterCurrent ? pickedMark : null,
                onTap: () => pick(() {
                  player.sleep.cancel();
                  player.stopAfterCurrent(true);
                }),
              ),
            ],
          ),
        ),
      );
    },
  );
}

/// A network's stream quality, opening the levels the provider in use serves.
class _QualityRow extends StatelessWidget {
  const _QualityRow({required this.title, required this.quality, required this.accounts, required this.onPick});

  final String title;
  final String quality;
  final AccountsViewModel accounts;
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    final connected = accounts.connected;
    final slug = selectedService.among([for (final service in connected) service.slug]);
    final service = connected.where((service) => service.slug == slug).firstOrNull;
    return SettingsRow(
      title: title,
      value: context.t('quality.$quality'),
      onTap: service == null
          ? null
          : () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => _QualityScreen(title: title, service: service, quality: quality, onPick: onPick),
              ),
            ),
    );
  }
}

/// The levels a service serves, the stored one checked as that service plays it.
class _QualityScreen extends StatefulWidget {
  const _QualityScreen({required this.title, required this.service, required this.quality, required this.onPick});

  final String title;
  final StreamingService service;
  final String quality;
  final ValueChanged<String> onPick;

  @override
  State<_QualityScreen> createState() => _QualityScreenState();
}

class _QualityScreenState extends State<_QualityScreen> {
  late final _offers = core.qualities(slug: widget.service.slug);
  late String _quality = widget.quality;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder(
      future: _offers,
      builder: (context, snapshot) {
        final offers = snapshot.data ?? const <core.QualityOption>[];
        // The stored level as this service plays it: the best offered at or below it.
        const order = ['low', 'normal', 'high', 'lossless', 'hi-res'];
        final wanted = order.indexOf(_quality);
        final playing =
            offers.where((offer) => order.indexOf(offer.id) <= wanted).firstOrNull?.id ?? offers.lastOrNull?.id;
        return SettingsPage(
          title: widget.title,
          back: context.t('settings.playback'),
          children: [
            SettingsGroup(
              footer: context.t('playback.quality.detail', {'service': widget.service.name}),
              children: [
                for (final offer in offers)
                  SettingsRow(
                    title: context.t('quality.${offer.id}'),
                    subtitle: offer.upTo ? context.t('quality.upTo', {'encoding': offer.encoding}) : offer.encoding,
                    trailing: offer.id == playing ? pickedMark : null,
                    onTap: () {
                      setState(() => _quality = offer.id);
                      widget.onPick(offer.id);
                    },
                  ),
              ],
            ),
          ],
        );
      },
    );
  }
}
