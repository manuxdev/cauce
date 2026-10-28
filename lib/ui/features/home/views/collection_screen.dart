import 'package:flutter/material.dart';

import '../../../../src/rust/api/player.dart' as core;
import '../../../core/app_scope.dart';
import '../../../core/artwork.dart';
import '../../../core/detail_page.dart';
import '../../../core/icons.dart';
import '../../../core/l10n.dart';
import '../../../core/motion.dart';
import '../../../core/skeleton.dart';
import '../../../core/theme.dart';
import '../../../core/tint_scope.dart';
import '../../../core/track_tile.dart';
import '../../../core/widgets.dart';
import '../../downloads/downloads_view_model.dart';
import '../../track/track_options.dart';
import '../../accounts/view_models/accounts_view_model.dart' show streamingServices;
import '../../player/view_models/player_view_model.dart';
import 'playlist_editing.dart';
import '../../../core/notifications.dart';
import '../../../core/toast.dart';
import '../../../core/error_text.dart';

/// An album or playlist: its cover, name and who made it, play and download, and its tracks,
/// on a page tinted with its cover.
class CollectionScreen extends StatefulWidget {
  const CollectionScreen({super.key, required this.slug, required this.card, required this.player, this.heroTag});

  final String slug;
  final core.MediaCard card;
  final PlayerViewModel player;

  /// The tag the opening card's cover flies under, so it lands on this page's cover.
  final Object? heroTag;

  @override
  State<CollectionScreen> createState() => _CollectionScreenState();
}

class _CollectionScreenState extends State<CollectionScreen> {
  late Future<List<core.TrackItem>> _tracks = _load();

  Future<List<core.TrackItem>> _load() async {
    final card = widget.card;
    final tracks = await core.collectionTracks(slug: widget.slug, kind: card.kind, id: card.id);
    // A kept one downloads what it gained since.
    if (downloads.keeps(widget.slug, card.kind, card.id)) {
      downloads
          .keep(widget.slug, card.kind, card.id, tracks, name: _name ?? card.title, cover: card.cover)
          .catchError((Object _) {});
    }
    return tracks;
  }

  static const _cover = 240.0;

  /// The name after a rename here.
  String? _name;

  /// Whether the playlist is the listener's own, which can be edited.
  late final Future<bool> _mine = widget.card.kind == core.CardKind.playlist
      ? core
            .ownPlaylists(slug: widget.slug)
            .then((playlists) => playlists.any((playlist) => playlist.id == widget.card.id))
            .catchError((Object _) => false)
      : Future.value(false);

  void _say(String message) => showToast(Toast(title: message, tone: ToastTone.error));

  /// The tracks after a removal here, shown until the playlist loads again.
  List<core.TrackItem>? _edited;
  int _removing = 0;

  /// Takes the row at `index` out of the playlist at once, then loads it again. A kept playlist
  /// keeps the track's download; freeing space takes it once nothing holds it.
  Future<void> _remove(List<core.TrackItem> tracks, int index) async {
    final track = tracks[index];
    final removed = context.t('playlist.removed');
    final failed = context.t('playlist.failed', {'error': '{error}'});
    setState(() {
      _edited = [...tracks]..removeAt(index);
      _removing++;
    });
    try {
      await core.removeFromPlaylist(
        slug: widget.slug,
        playlistId: widget.card.id,
        trackId: track.id,
        copy: copyOf(tracks, index),
      );
      showToast(Toast(title: removed, detail: '${track.title} · ${track.artists}', cover: track.cover, badge: true));
    } catch (error) {
      _say(failed.replaceAll('{error}', explainError(error)));
    }
    if (!mounted) return;
    final reload = _load();
    setState(() => _tracks = reload);
    await reload.then((_) {}, onError: (Object _) {});
    if (mounted && --_removing == 0) setState(() => _edited = null);
  }

  Future<void> _edit(List<core.TrackItem> tracks) async {
    final name = _name ?? widget.card.title;
    final failed = context.t('playlist.failed', {'error': '{error}'});
    final edit = await showPlaylistOptions(context);
    if (!mounted) return;
    try {
      switch (edit) {
        case PlaylistEdit.playNext || PlaylistEdit.addToQueue:
          await queueTracks(context, tracks, next: edit == PlaylistEdit.playNext, name: name, cover: widget.card.cover);
        case PlaylistEdit.add:
          await Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => AddSongsScreen(
                slug: widget.slug,
                playlistId: widget.card.id,
                name: name,
                has: {for (final track in tracks) track.id},
              ),
            ),
          );
          if (mounted) setState(() => _tracks = _load());
        case PlaylistEdit.rename:
          final renamed = await askPlaylistName(context, name);
          if (renamed == null) return;
          await core.renamePlaylist(slug: widget.slug, playlistId: widget.card.id, name: renamed);
          if (mounted) setState(() => _name = renamed);
        case PlaylistEdit.delete:
          final service = streamingServices.where((service) => service.slug == widget.slug).firstOrNull?.name;
          if (!await confirmPlaylistDelete(context, name, service ?? widget.slug)) return;
          await core.deletePlaylist(slug: widget.slug, playlistId: widget.card.id);
          if (mounted) Navigator.of(context).pop();
        case null:
      }
    } catch (error) {
      if (mounted) _say(failed.replaceAll('{error}', explainError(error)));
    }
  }

  /// The tile of the track playing, which the page scrolls to once on opening.
  final _playingTile = GlobalKey();
  bool _scrolled = false;

  void _scrollToPlaying() {
    if (_scrolled) return;
    _scrolled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final tile = _playingTile.currentContext;
      if (tile == null || !tile.mounted) return;
      Scrollable.ensureVisible(
        tile,
        alignment: 0.4,
        duration: const Duration(milliseconds: 450),
        curve: CauceCurves.soft,
      );
    });
  }

  /// The album's artist, as the tracks link it: the one named in the subtitle, or the first
  /// track's first.
  core.ArtistLink? _artist(List<core.TrackItem> tracks) {
    final links = [for (final track in tracks) ...track.artistLinks];
    if (links.isEmpty) return null;
    return links.firstWhere((link) => widget.card.subtitle.contains(link.name), orElse: () => links.first);
  }

  @override
  Widget build(BuildContext context) {
    final card = widget.card;
    final album = card.kind == core.CardKind.album;
    final top = MediaQuery.paddingOf(context).top;
    return FutureBuilder(
      future: _tracks,
      builder: (context, snapshot) {
        final tracks = _edited ?? snapshot.data ?? const <core.TrackItem>[];
        final play = tracks.isEmpty ? null : () => widget.player.playQueue(tracks, 0);
        final minutes = tracks.fold(0, (sum, track) => sum + track.durationMs.toInt()) ~/ 60000;
        return DetailPage(
          cover: card.cover,
          title: _name ?? card.title,
          titleAt: top + 50 + _cover + 40,
          compactAction: album ? RoundPlayButton(onPressed: play) : _PlayPill(onTap: play),
          barEdge: _DownloadLine(tracks: tracks),
          header: (context, offset) {
            // The cover sinks at 60 % of the scroll, shrinking to 70 % and fading as it goes.
            final gone = (offset / (_cover + 50)).clamp(0.0, 1.0);
            final cover = DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                boxShadow: const [BoxShadow(color: Color(0x73000000), blurRadius: 40, offset: Offset(0, 18))],
              ),
              child: Artwork(url: card.cover, size: _cover, radius: 16),
            );
            return Positioned(
              top: top + 50 - offset.clamp(0.0, double.infinity) * 0.6,
              left: 0,
              right: 0,
              child: Center(
                child: Opacity(
                  opacity: 1 - gone,
                  child: Transform.scale(
                    scale: 1 - 0.3 * gone,
                    child: switch (widget.heroTag) {
                      final tag? => Hero(tag: tag, transitionOnUserGestures: true, child: cover),
                      null => cover,
                    },
                  ),
                ),
              ),
            );
          },
          children: [
            SizedBox(height: top + 50 + _cover),
            const SizedBox(height: 24),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: CauceMetrics.gutter),
              child: Column(
                children: [
                  Text(_name ?? card.title, textAlign: TextAlign.center, style: CauceText.headline),
                  if (card.subtitle.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    GestureDetector(
                      onTap: switch (album ? _artist(tracks) : null) {
                        final artist? => () => openArtist(context, widget.slug, artist),
                        null => null,
                      },
                      child: Text(
                        card.subtitle,
                        textAlign: TextAlign.center,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 17, color: CauceColors.accent),
                      ),
                    ),
                  ],
                  if (tracks.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(
                      [
                        context.t(album ? 'collection.album' : 'collection.playlist'),
                        context.t('playlist.count', {'count': tracks.length}),
                        context.t('collection.minutes', {'count': minutes}),
                      ].join(' · '),
                      style: TextStyle(fontSize: 13.5, color: CauceColors.mutedForeground),
                    ),
                  ],
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(CauceMetrics.gutter, 20, CauceMetrics.gutter, 12),
              child: Row(
                children: [
                  Expanded(
                    child: _BigButton(
                      accent: true,
                      onTap: play,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          CauceIcon(CauceGlyph.play, size: 16, color: CauceColors.onAccent),
                          const SizedBox(width: 8),
                          Text(context.t('common.play')),
                        ],
                      ),
                    ),
                  ),
                  if (canDownload(widget.slug)) ...[
                    const SizedBox(width: 10),
                    Expanded(
                      child: _DownloadAll(
                        slug: widget.slug,
                        card: widget.card,
                        tracks: tracks,
                        name: _name ?? widget.card.title,
                      ),
                    ),
                  ],
                  FutureBuilder(
                    future: _mine,
                    builder: (context, mine) => mine.data ?? false
                        ? Padding(
                            padding: const EdgeInsets.only(left: 10),
                            child: SizedBox(
                              width: 48,
                              child: _BigButton(
                                onTap: () => _edit(tracks),
                                child: const CauceIcon(CauceGlyph.more, size: 22),
                              ),
                            ),
                          )
                        : const SizedBox.shrink(),
                  ),
                ],
              ),
            ),
            if (snapshot.hasError && _edited == null)
              Padding(
                padding: const EdgeInsets.only(top: 40),
                child: EmptyState(
                  glyph: CauceGlyph.offline,
                  badge: true,
                  title: context.t('home.offline'),
                  actions: [
                    FilledButton(
                      onPressed: () => setState(() => _tracks = _load()),
                      child: Text(context.t('common.retry')),
                    ),
                  ],
                ),
              )
            else
              LoadSwitch(
                loading: _edited == null && snapshot.connectionState != ConnectionState.done,
                skeleton: const TrackListSkeleton(),
                child: ListenableBuilder(
                  listenable: widget.player,
                  builder: (context, _) {
                    final current = widget.player.track;
                    if (tracks.any((track) => current?.id == track.id && current?.source == track.source)) {
                      _scrollToPlaying();
                    }
                    return FutureBuilder(
                      future: _mine,
                      builder: (context, mine) {
                        final own = mine.data ?? false;
                        return Column(
                          children: [
                            for (final (index, track) in tracks.indexed)
                              _removable(
                                own: own,
                                // Each row is its own instance, so a copy left behind keeps its swipe state.
                                key: ObjectKey(track),
                                onRemove: () => _remove(tracks, index),
                                child: TrackTile(
                                  key: current?.id == track.id && current?.source == track.source ? _playingTile : null,
                                  track: track,
                                  number: album ? index + 1 : null,
                                  showAlbum: !album,
                                  playing: current?.id == track.id && current?.source == track.source,
                                  onTap: () => widget.player.playQueue(tracks, index),
                                  onRemove: own ? () => _remove(tracks, index) : null,
                                ),
                              ),
                          ],
                        );
                      },
                    );
                  },
                ),
              ),
          ],
        );
      },
    );
  }
}

/// `child`, swiped left to take it out of the listener's `own` playlist, as in the queue.
Widget _removable({required bool own, required Key key, required VoidCallback onRemove, required Widget child}) {
  if (!own) return child;
  return Dismissible(
    key: key,
    direction: DismissDirection.endToStart,
    onDismissed: (_) => onRemove(),
    background: Container(
      color: CauceColors.error,
      alignment: Alignment.centerRight,
      padding: const EdgeInsets.only(right: 24),
      child: const CauceIcon(CauceGlyph.trash, size: 22, color: Colors.white, weight: 2.2),
    ),
    child: child,
  );
}

/// A wide rounded button: accent, or on the page's tinted surface.
class _BigButton extends StatelessWidget {
  const _BigButton({required this.child, required this.onTap, this.accent = false});

  final Widget child;
  final VoidCallback? onTap;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 48,
        decoration: BoxDecoration(
          color: accent ? CauceColors.accent : TintScope.of(context).surface,
          borderRadius: BorderRadius.circular(14),
        ),
        alignment: Alignment.center,
        child: DefaultTextStyle.merge(
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: accent ? CauceColors.onAccent : CauceColors.foreground,
          ),
          child: child,
        ),
      ),
    );
  }
}

/// The small accent Play pill a playlist's bar takes once its own button has scrolled away.
class _PlayPill extends StatelessWidget {
  const _PlayPill({required this.onTap});

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Pressable(
      scale: 0.9,
      onTap: onTap,
      child: Container(
        height: 30,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(color: CauceColors.accent, borderRadius: BorderRadius.circular(15)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            CauceIcon(CauceGlyph.play, size: 12, color: CauceColors.onAccent),
            const SizedBox(width: 5),
            Text(
              context.t('common.play'),
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: CauceColors.onAccent),
            ),
          ],
        ),
      ),
    );
  }
}

/// A thin accent line along the bar while the page's tracks download, as far as they have got.
class _DownloadLine extends StatelessWidget {
  const _DownloadLine({required this.tracks});

  final List<core.TrackItem> tracks;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: downloads,
      builder: (context, _) {
        final items = [for (final track in tracks) ?downloads.of(track)];
        final running = items.any(
          (item) => item.state == core.DownloadState.queued || item.state == core.DownloadState.running,
        );
        final done = items.fold(
          0.0,
          (sum, item) => sum + (item.state == core.DownloadState.done ? 1 : (item.progress ?? 0)),
        );
        return AnimatedOpacity(
          opacity: running ? 1 : 0,
          duration: const Duration(milliseconds: 220),
          child: Align(
            alignment: Alignment.centerLeft,
            child: TweenAnimationBuilder<double>(
              tween: Tween(end: items.isEmpty ? 0 : done / items.length),
              duration: const Duration(milliseconds: 200),
              builder: (context, fraction, _) => FractionallySizedBox(
                widthFactor: fraction,
                child: SizedBox(height: 2, child: ColoredBox(color: CauceColors.accent)),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Downloads every track not downloaded yet and keeps the album or playlist downloaded, showing
/// how many are done while they come in. Once kept, it offers to remove the download.
class _DownloadAll extends StatelessWidget {
  const _DownloadAll({required this.slug, required this.card, required this.tracks, required this.name});

  final String slug;
  final core.MediaCard card;
  final List<core.TrackItem> tracks;

  /// What the toast calls it.
  final String name;

  Future<void> _remove(BuildContext context) async {
    final sure = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        backgroundColor: CauceColors.sheet,
        title: Text(context.t('downloads.remove')),
        content: Text(context.t('downloads.remove.confirm', {'name': name})),
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
    if (!(sure ?? false) || !context.mounted) return;
    await downloads.removeCollection(slug, card.kind, card.id, liked: AppScope.of(context).favorites.tracks(slug));
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: downloads,
      builder: (context, _) {
        final playable = [
          for (final track in tracks)
            if (track.playable && track.source != 'local') track,
        ];
        final states = [for (final track in playable) downloads.of(track)?.state];
        final done = states.where((state) => state == core.DownloadState.done).length;
        final running = states.any(
          (state) => state == core.DownloadState.queued || state == core.DownloadState.running,
        );
        final missing = [
          for (final (index, track) in playable.indexed)
            if (states[index] != core.DownloadState.done) track,
        ];
        if (running) {
          return _BigButton(
            onTap: null,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    context.t('downloads.progress', {'done': done, 'total': playable.length}),
                    style: const TextStyle(fontSize: 14),
                  ),
                  const SizedBox(height: 6),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: LinearProgressIndicator(
                      value: playable.isEmpty ? 0 : done / playable.length,
                      minHeight: 3,
                      backgroundColor: Colors.white.withValues(alpha: 0.15),
                    ),
                  ),
                ],
              ),
            ),
          );
        }
        if (downloads.keeps(slug, card.kind, card.id)) {
          return _BigButton(
            onTap: () => _remove(context),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                CauceIcon(CauceGlyph.downloaded, size: 17, weight: 2.1, color: CauceColors.accent),
                const SizedBox(width: 8),
                Flexible(child: Text(context.t('track.downloaded'), maxLines: 1, overflow: TextOverflow.ellipsis)),
              ],
            ),
          );
        }
        final all = playable.isNotEmpty && missing.isEmpty;
        return _BigButton(
          onTap: playable.isEmpty
              ? null
              : () async {
                  final started = context.t('downloads.downloading', {'name': name});
                  final count = context.t('downloads.batch', {'count': missing.length});
                  if (missing.isNotEmpty) {
                    askToNotify();
                    final batch = await downloads.download(missing, name: name, cover: card.cover);
                    if (batch != null) {
                      showToast(Toast(title: started, detail: count, cover: batch.cover, progress: batch.progress));
                    }
                  }
                  await downloads.keep(slug, card.kind, card.id, tracks, name: name, cover: card.cover);
                },
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              CauceIcon(all ? CauceGlyph.check : CauceGlyph.download, size: 17, weight: 2.1),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  context.t(all ? 'track.downloaded' : 'downloads.all'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
