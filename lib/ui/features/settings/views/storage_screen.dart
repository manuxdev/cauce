import 'package:flutter/material.dart';

import '../../../core/app_prefs.dart';
import '../../../core/l10n.dart';
import '../../../core/motion.dart';
import '../../../core/theme.dart';
import '../view_models/playback_settings_view_model.dart';
import 'settings_widgets.dart';
import '../../../core/icons.dart';
import '../../../core/toast.dart';

/// The colours of the storage bar's parts.
Color get _downloadsColor => CauceColors.accent;
const _cacheColor = Color(0xFF5B9BE6);

/// What the downloads and the cache take on the phone, how downloads behave, and the cache's
/// limit and clearing.
class StorageScreen extends StatefulWidget {
  const StorageScreen({super.key, required this.playback});

  final PlaybackSettingsViewModel playback;

  @override
  State<StorageScreen> createState() => _StorageScreenState();
}

class _StorageScreenState extends State<StorageScreen> {
  @override
  void initState() {
    super.initState();
    widget.playback.refreshUsage();
  }

  void _say(String message) => showToast(Toast(title: message, glyph: CauceGlyph.trash, tone: ToastTone.info));

  Future<void> _deleteDownloads() async {
    final sure = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        backgroundColor: CauceColors.sheet,
        title: Text(context.t('storage.downloads.clear')),
        content: Text(context.t('storage.downloads.confirm')),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialog).pop(false), child: Text(context.t('search.cancel'))),
          TextButton(
            onPressed: () => Navigator.of(dialog).pop(true),
            style: TextButton.styleFrom(foregroundColor: CauceColors.error),
            child: Text(context.t('downloads.delete')),
          ),
        ],
      ),
    );
    if (sure != true || !mounted) return;
    final done = context.t('storage.downloads.cleared');
    await widget.playback.clearDownloads();
    _say(done);
  }

  /// The levels downloads can be fetched at; a service without one gets its best below it.
  Future<void> _pickDownloadQuality(String current) async {
    const levels = ['hi-res', 'lossless', 'high', 'normal', 'low'];
    final picked = await showModalBottomSheet<String>(
      context: context,
      useRootNavigator: true,
      sheetAnimationStyle: sheetAnimation,
      builder: (sheet) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
          child: SettingsGroup(
            title: context.t('storage.quality'),
            children: [
              for (final level in levels)
                SettingsRow(
                  title: context.t('quality.$level'),
                  trailing: level == current ? pickedMark : null,
                  onTap: () => Navigator.of(sheet).pop(level),
                ),
            ],
          ),
        ),
      ),
    );
    if (picked != null) widget.playback.update(downloadQuality: picked);
  }

  Future<void> _pickCacheSize(int current) async {
    final (low, high) = widget.playback.cacheRange;
    final sizes = [
      for (final size in const [1, 2, 4, 8, 16, 32, 64])
        if (size >= low && size <= high) size,
    ];
    final picked = await showModalBottomSheet<int>(
      context: context,
      useRootNavigator: true,
      sheetAnimationStyle: sheetAnimation,
      builder: (sheet) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
          child: SettingsGroup(
            title: context.t('storage.size'),
            children: [
              for (final size in sizes)
                SettingsRow(
                  title: '$size GB',
                  trailing: size == current ? pickedMark : null,
                  onTap: () => Navigator.of(sheet).pop(size),
                ),
            ],
          ),
        ),
      ),
    );
    if (picked != null) widget.playback.update(cacheGb: picked);
  }

  @override
  Widget build(BuildContext context) {
    final playback = widget.playback;
    return ListenableBuilder(
      listenable: Listenable.merge([playback, appPrefs]),
      builder: (context, _) {
        final settings = playback.settings;
        if (settings == null) return SettingsPage(title: context.t('settings.storage'), children: const []);
        final usage = playback.usage;
        return SettingsPage(
          title: context.t('settings.storage'),
          children: [
            _Usage(downloads: usage?.downloadBytes.toInt() ?? 0, cache: usage?.cacheBytes.toInt() ?? 0),
            SettingsGroup(
              children: [
                SettingsSwitch(
                  title: context.t('storage.offlineMode'),
                  subtitle: context.t('storage.offlineMode.detail'),
                  value: appPrefs.offlineMode,
                  onChanged: (on) => appPrefs.update((prefs) => prefs.offlineMode = on),
                ),
              ],
            ),
            SettingsGroup(
              title: context.t('storage.downloads'),
              children: [
                SettingsSwitch(
                  title: context.t('storage.wifiOnly'),
                  value: settings.downloadsWifiOnly,
                  onChanged: (on) => playback.update(downloadsWifiOnly: on),
                ),
                SettingsRow(
                  title: context.t('storage.quality'),
                  value: context.t('quality.${settings.downloadQuality}'),
                  onTap: () => _pickDownloadQuality(settings.downloadQuality),
                ),
                SettingsSwitch(
                  title: context.t('storage.likes'),
                  subtitle: context.t('storage.likes.detail'),
                  value: settings.downloadLikes,
                  onChanged: (on) => playback.update(downloadLikes: on),
                ),
                SettingsSwitch(
                  title: context.t('storage.freeSpace'),
                  subtitle: context.t('storage.freeSpace.detail'),
                  value: settings.freeSpace,
                  onChanged: (on) => playback.update(freeSpace: on),
                ),
              ],
            ),
            SettingsGroup(
              title: context.t('storage.cache'),
              children: [
                SettingsSwitch(
                  title: context.t('storage.keep'),
                  value: settings.keepTracks,
                  onChanged: (on) => playback.update(keepTracks: on),
                ),
                if (settings.keepTracks)
                  SettingsRow(
                    title: context.t('storage.size'),
                    value: '${settings.cacheGb} GB',
                    onTap: () => _pickCacheSize(settings.cacheGb),
                  ),
                _ActionRow(
                  label: context.t('storage.clear'),
                  color: CauceColors.accent,
                  onTap: () async {
                    final done = context.t('storage.cleared');
                    await playback.clearCache();
                    _say(done);
                  },
                ),
              ],
            ),
            SettingsGroup(
              children: [
                _ActionRow(
                  label: context.t('storage.downloads.clear'),
                  color: CauceColors.error,
                  onTap: _deleteDownloads,
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}

/// The total over a bar split into downloads and cache, with a legend.
class _Usage extends StatelessWidget {
  const _Usage({required this.downloads, required this.cache});

  final int downloads;
  final int cache;

  @override
  Widget build(BuildContext context) {
    final total = downloads + cache;
    Widget legend(Color color, String label, int bytes) => Row(
      children: [
        Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2)),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(label, style: TextStyle(fontSize: 13.5, color: CauceColors.mutedForeground)),
        ),
        Text(formatBytes(bytes), style: TextStyle(fontSize: 13.5, color: CauceColors.mutedForeground)),
      ],
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 22),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(color: CauceColors.group, borderRadius: BorderRadius.circular(14)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              formatBytes(total),
              style: const TextStyle(fontFamily: displayFont, fontSize: 26, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: SizedBox(
                height: 8,
                child: total == 0
                    ? ColoredBox(color: CauceColors.foreground.withValues(alpha: 0.12))
                    : Row(
                        children: [
                          if (downloads > 0)
                            Expanded(
                              flex: downloads,
                              child: ColoredBox(color: _downloadsColor),
                            ),
                          if (downloads > 0 && cache > 0) const SizedBox(width: 2),
                          if (cache > 0)
                            Expanded(
                              flex: cache,
                              child: const ColoredBox(color: _cacheColor),
                            ),
                        ],
                      ),
              ),
            ),
            const SizedBox(height: 12),
            legend(_downloadsColor, context.t('storage.downloads'), downloads),
            const SizedBox(height: 6),
            legend(_cacheColor, context.t('storage.cache'), cache),
          ],
        ),
      ),
    );
  }
}

/// A row that is only an action, in its colour.
class _ActionRow extends StatelessWidget {
  const _ActionRow({required this.label, required this.color, required this.onTap});

  final String label;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(minHeight: 52),
        padding: const EdgeInsets.symmetric(horizontal: 16),
        alignment: Alignment.centerLeft,
        child: Text(label, style: TextStyle(fontSize: 16.5, color: color)),
      ),
    );
  }
}
