import 'package:flutter/material.dart';

import '../../../../src/rust/api/player.dart' as core;
import '../../../core/app_scope.dart';
import '../../../core/artwork.dart';
import '../../../core/icons.dart';
import '../../../core/l10n.dart';
import '../../../core/theme.dart';
import '../../../core/toast.dart';
import '../../../core/track_tile.dart';
import '../../../core/widgets.dart';
import '../../downloads/downloads_view_model.dart';
import '../view_models/playback_settings_view_model.dart';
import 'settings_widgets.dart';

/// What is downloaded, by kept album or playlist and then the rest, largest first, with what each
/// takes on disk. A group opens to its tracks; a kept one can be removed whole, and a track by a
/// swipe.
class ManageDownloadsScreen extends StatefulWidget {
  const ManageDownloadsScreen({super.key, required this.playback});

  final PlaybackSettingsViewModel playback;

  @override
  State<ManageDownloadsScreen> createState() => _ManageDownloadsScreenState();
}

class _ManageDownloadsScreenState extends State<ManageDownloadsScreen> {
  (List<core.DownloadGroup>, BigInt)? _groups;

  /// The groups open, by [_groupKey].
  final Set<String> _open = {};

  /// Tracks swiped away, kept out of the list until it loads again.
  final Set<String> _gone = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final groups = await core.downloadGroups();
    if (!mounted) return;
    setState(() {
      _groups = groups;
      _gone.clear();
    });
  }

  /// After a delete: the list, the storage bar and the downloads everywhere else.
  Future<void> _changed() => Future.wait([_load(), widget.playback.refreshUsage()]);

  static String _groupKey(core.DownloadGroup group) => switch (group.collection) {
    final kept? => '${kept.slug}/${kept.kind.name}/${kept.id}',
    null => '',
  };

  static String _trackKey(core.TrackItem track) => '${track.source}/${track.id}';

  String _name(core.DownloadGroup group) => group.collection == null
      ? context.t('storage.others')
      : group.name.isEmpty
      ? context.t('collection.playlist')
      : group.name;

  Future<void> _removeGroup(core.DownloadGroup group, core.KeptCollection kept) async {
    final sure = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        backgroundColor: CauceColors.sheet,
        title: Text(context.t('downloads.remove')),
        content: Text(context.t('downloads.remove.confirm', {'name': _name(group)})),
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
    if (!(sure ?? false) || !mounted) return;
    await downloads.removeCollection(
      kept.slug,
      kept.kind,
      kept.id,
      liked: AppScope.of(context).favorites.tracks(kept.slug),
    );
    await _changed();
  }

  Future<void> _removeTrack(core.TrackItem track) async {
    setState(() => _gone.add(_trackKey(track)));
    showToast(
      Toast(
        title: context.t('downloads.deleted'),
        detail: '${track.title} · ${track.artists}',
        cover: track.cover,
        glyph: CauceGlyph.trash,
        tone: ToastTone.info,
      ),
    );
    await downloads.remove(track);
    await _changed();
  }

  @override
  Widget build(BuildContext context) {
    final title = context.t('storage.manage');
    final loaded = _groups;
    if (loaded == null) return SettingsPage(title: title, back: context.t('settings.storage'), children: const []);
    final (groups, total) = loaded;
    return SettingsPage(
      title: title,
      back: context.t('settings.storage'),
      children: [
        if (groups.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 100),
            child: EmptyState(
              glyph: CauceGlyph.download,
              title: context.t('downloads.none'),
              message: context.t('downloads.empty'),
            ),
          )
        else ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 14),
            child: Text(formatBytes(total.toInt()), style: CauceText.caption),
          ),
          for (final group in groups) _group(group),
        ],
      ],
    );
  }

  Widget _group(core.DownloadGroup group) {
    final key = _groupKey(group);
    final open = _open.contains(key);
    final tracks = [
      for (final downloaded in group.tracks)
        if (!_gone.contains(_trackKey(downloaded.track))) downloaded,
    ];
    final kept = group.collection;
    final player = AppScope.of(context).player;
    final queue = [for (final downloaded in tracks) downloaded.track];
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(CauceMetrics.groupRadius),
        child: Material(
          color: CauceColors.group,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              InkWell(
                onTap: () => setState(() => open ? _open.remove(key) : _open.add(key)),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
                  child: Row(
                    children: [
                      Artwork(url: group.cover, size: 48),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _name(group),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 16.5, fontWeight: FontWeight.w600),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              '${context.t('playlist.count', {'count': tracks.length})} · '
                              '${formatBytes(group.bytes.toInt())}',
                              style: CauceText.caption,
                            ),
                          ],
                        ),
                      ),
                      if (kept != null)
                        IconButton(
                          tooltip: context.t('downloads.remove'),
                          onPressed: () => _removeGroup(group, kept),
                          icon: CauceIcon(CauceGlyph.trash, size: 20, color: CauceColors.error, weight: 2),
                        ),
                      Padding(
                        padding: const EdgeInsets.all(8),
                        child: AnimatedRotation(
                          turns: open ? 0.5 : 0,
                          duration: const Duration(milliseconds: 200),
                          child: CauceIcon(CauceGlyph.chevronDown, size: 18, color: CauceColors.mutedForeground),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (open)
                for (final (index, downloaded) in tracks.indexed)
                  Dismissible(
                    key: ValueKey('$key/${_trackKey(downloaded.track)}'),
                    direction: DismissDirection.endToStart,
                    onDismissed: (_) => _removeTrack(downloaded.track),
                    background: Container(
                      color: CauceColors.error,
                      alignment: Alignment.centerRight,
                      padding: const EdgeInsets.only(right: 24),
                      child: const CauceIcon(CauceGlyph.trash, size: 22, color: Colors.white, weight: 2.2),
                    ),
                    child: TrackTile(
                      track: downloaded.track,
                      mixed: true,
                      trailing: Padding(
                        padding: const EdgeInsets.only(right: 12),
                        child: Text(formatBytes(downloaded.bytes.toInt()), style: CauceText.caption),
                      ),
                      onTap: () => player.playQueue(queue, index),
                    ),
                  ),
            ],
          ),
        ),
      ),
    );
  }
}
