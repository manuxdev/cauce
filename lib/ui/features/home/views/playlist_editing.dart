import 'dart:async';

import 'package:flutter/material.dart';

import '../../../../src/rust/api/player.dart' as core;
import '../../../core/app_prefs.dart';
import '../../../core/app_scope.dart';
import '../../../core/icons.dart';
import '../../../core/l10n.dart';
import '../../../core/motion.dart';
import '../../../core/service_picker.dart';
import '../../../core/skeleton.dart';
import '../../../core/theme.dart';
import '../../../core/track_tile.dart';
import '../../../core/widgets.dart';
import '../../track/track_options.dart';
import '../../../core/toast.dart';
import '../../../core/error_text.dart';

/// Which copy of its track, from 0, the row at `index` holds: how many rows before it hold the
/// same track. A playlist removes a row by it, so a track it has twice loses the right one.
int copyOf(List<core.TrackItem> tracks, int index) =>
    tracks.take(index).where((track) => track.id == tracks[index].id).length;

/// What can be done to one of the listener's own playlists.
enum PlaylistEdit { playNext, addToQueue, add, rename, delete }

Future<PlaylistEdit?> showPlaylistOptions(BuildContext context) {
  return behindSheet(
    showModalBottomSheet<PlaylistEdit>(
      sheetAnimationStyle: sheetAnimation,
      context: context,
      useRootNavigator: true,
      barrierColor: Colors.black.withValues(alpha: 0.5),
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SheetHandle(),
            OptionRow(
              glyph: CauceGlyph.next,
              label: context.t('track.playNext'),
              onTap: () => Navigator.of(sheet).pop(PlaylistEdit.playNext),
            ),
            OptionRow(
              glyph: CauceGlyph.queue,
              label: context.t('track.addToQueue'),
              onTap: () => Navigator.of(sheet).pop(PlaylistEdit.addToQueue),
            ),
            OptionRow(
              glyph: CauceGlyph.plus,
              label: context.t('playlist.addSongs'),
              onTap: () => Navigator.of(sheet).pop(PlaylistEdit.add),
            ),
            OptionRow(
              glyph: CauceGlyph.document,
              label: context.t('playlist.rename'),
              onTap: () => Navigator.of(sheet).pop(PlaylistEdit.rename),
            ),
            OptionRow(
              glyph: CauceGlyph.trash,
              label: context.t('playlist.delete'),
              color: CauceColors.error,
              onTap: () => Navigator.of(sheet).pop(PlaylistEdit.delete),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    ),
  );
}

/// Asks for a new name, starting from `current`. Null when cancelled or left empty.
Future<String?> askPlaylistName(BuildContext context, String current) async {
  final field = TextEditingController(text: current);
  final name = await showDialog<String>(
    context: context,
    builder: (dialog) => AlertDialog(
      backgroundColor: CauceColors.sheet,
      title: Text(context.t('playlist.rename')),
      content: TextField(
        controller: field,
        autofocus: true,
        textCapitalization: TextCapitalization.sentences,
        decoration: InputDecoration(hintText: context.t('playlist.name')),
        onSubmitted: (text) => Navigator.of(dialog).pop(text),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(dialog).pop(), child: Text(context.t('search.cancel'))),
        TextButton(onPressed: () => Navigator.of(dialog).pop(field.text), child: Text(context.t('playlist.save'))),
      ],
    ),
  );
  field.dispose();
  final trimmed = name?.trim();
  return trimmed == null || trimmed.isEmpty || trimmed == current ? null : trimmed;
}

/// Asks before deleting `name`, which cannot be undone.
Future<bool> confirmPlaylistDelete(BuildContext context, String name, String service) async {
  final sure = await showDialog<bool>(
    context: context,
    builder: (dialog) => AlertDialog(
      backgroundColor: CauceColors.sheet,
      title: Text(context.t('playlist.delete')),
      content: Text(context.t('playlist.deleteConfirm', {'name': name, 'service': service})),
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
  return sure ?? false;
}

/// Adds songs to a playlist, found by searching its provider or picked from the liked ones.
class AddSongsScreen extends StatefulWidget {
  const AddSongsScreen({
    super.key,
    required this.slug,
    required this.playlistId,
    required this.name,
    required this.has,
  });

  final String slug;
  final String playlistId;
  final String name;

  /// The ids already in it, shown as added.
  final Set<String> has;

  @override
  State<AddSongsScreen> createState() => _AddSongsScreenState();
}

class _AddSongsScreenState extends State<AddSongsScreen> {
  final _query = TextEditingController();
  late final Set<String> _added = {...widget.has};
  final Set<String> _adding = {};
  bool _liked = false;
  Timer? _pending;
  Future<List<core.TrackItem>>? _found;

  @override
  void dispose() {
    _pending?.cancel();
    _query.dispose();
    super.dispose();
  }

  void _typed(String text) {
    _pending?.cancel();
    final query = text.trim();
    _pending = Timer(const Duration(milliseconds: 350), () {
      if (mounted) setState(() => _found = query.isEmpty ? null : core.search(slug: widget.slug, query: query));
    });
  }

  Future<void> _add(core.TrackItem track) async {
    if (_added.contains(track.id) || _adding.contains(track.id)) return;
    tick();
    setState(() => _adding.add(track.id));
    try {
      await core.addToPlaylist(slug: widget.slug, playlistId: widget.playlistId, trackId: track.id);
      if (mounted) setState(() => _added.add(track.id));
    } catch (error) {
      if (mounted) {
        showToast(
          Toast(
            title: context.t('playlist.addFailed', {'name': widget.name}),
            detail: explainError(error),
            cover: track.cover,
            badge: true,
            tone: ToastTone.error,
          ),
        );
      }
    }
    if (mounted) setState(() => _adding.remove(track.id));
  }

  Widget _list(List<core.TrackItem> tracks) {
    return ListView(
      padding: const EdgeInsets.only(bottom: bottomChromeInset),
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      children: [
        for (final track in tracks)
          TrackTile(
            track: track,
            onTap: () => _add(track),
            trailing: SizedBox.square(
              dimension: 44,
              child: Center(
                child: _adding.contains(track.id)
                    ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : AnimatedSwitcher(
                        duration: const Duration(milliseconds: 200),
                        child: _added.contains(track.id)
                            ? CauceIcon(CauceGlyph.check, key: ValueKey(true), size: 20, color: CauceColors.accent)
                            : const CauceIcon(CauceGlyph.plus, key: ValueKey(false), size: 20),
                      ),
              ),
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final favorites = AppScope.of(context).favorites;
    return Scaffold(
      backgroundColor: CauceColors.background,
      body: SafeArea(
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              height: 52,
              child: Row(
                children: [
                  IconButton(
                    onPressed: () => Navigator.of(context).maybePop(),
                    icon: CauceIcon(CauceGlyph.chevronLeft, size: 22, color: CauceColors.accent, weight: 2.4),
                  ),
                  Expanded(
                    child: Text(
                      context.t('playlist.addSongs'),
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
                    ),
                  ),
                  const SizedBox(width: 48),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(CauceMetrics.gutter, 0, CauceMetrics.gutter, 0),
              child: Text(
                widget.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 14, color: CauceColors.mutedForeground),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(CauceMetrics.gutter, 10, CauceMetrics.gutter, 12),
              child: Row(
                children: [
                  Pill(
                    label: context.t('playlist.search'),
                    glyph: CauceGlyph.search,
                    selected: !_liked,
                    onTap: () => setState(() => _liked = false),
                  ),
                  const SizedBox(width: 8),
                  Pill(
                    label: context.t('playlist.liked'),
                    glyph: CauceGlyph.heart,
                    selected: _liked,
                    onTap: () {
                      FocusScope.of(context).unfocus();
                      setState(() => _liked = true);
                    },
                  ),
                ],
              ),
            ),
            if (!_liked)
              Padding(
                padding: const EdgeInsets.fromLTRB(CauceMetrics.gutter, 0, CauceMetrics.gutter, 8),
                child: SizedBox(
                  height: 42,
                  child: TextField(
                    controller: _query,
                    autofocus: true,
                    textInputAction: TextInputAction.search,
                    onChanged: _typed,
                    style: const TextStyle(fontSize: 17),
                    decoration: InputDecoration(
                      hintText: context.t('playlist.searchHint'),
                      prefixIcon: Padding(
                        padding: EdgeInsets.only(left: 12, right: 8),
                        child: CauceIcon(CauceGlyph.search, size: 19, color: CauceColors.mutedForeground),
                      ),
                      prefixIconConstraints: const BoxConstraints(minWidth: 0, minHeight: 0),
                    ),
                  ),
                ),
              ),
            Expanded(
              child: _liked
                  ? ListenableBuilder(
                      listenable: favorites,
                      builder: (context, _) => _list(favorites.tracks(widget.slug)),
                    )
                  : switch (_found) {
                      null => const SizedBox.shrink(),
                      final found => FutureBuilder(
                        future: found,
                        builder: (context, snapshot) => switch (snapshot) {
                          AsyncSnapshot(:final data?) => _list(data),
                          AsyncSnapshot(:final error?) => Padding(
                            padding: const EdgeInsets.all(CauceMetrics.gutter),
                            child: Text(explainError(error), style: TextStyle(color: CauceColors.error)),
                          ),
                          _ => const SingleChildScrollView(
                            physics: NeverScrollableScrollPhysics(),
                            child: TrackListSkeleton(count: 8),
                          ),
                        },
                      ),
                    },
            ),
          ],
        ),
      ),
    );
  }
}
