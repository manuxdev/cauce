import 'package:flutter/material.dart';

import '../../../src/rust/api/player.dart' as core;
import '../../core/app_scope.dart';
import '../../core/artwork.dart';
import '../../core/dropdown.dart';
import '../../core/icons.dart';
import '../../core/l10n.dart';
import '../../core/motion.dart';
import '../../core/skeleton.dart';
import '../../core/tab_navigators.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../accounts/view_models/accounts_view_model.dart';
import '../artist/views/artist_screen.dart';
import '../downloads/downloads_view_model.dart';
import '../home/views/collection_screen.dart';
import '../../core/toast.dart';
import '../../core/error_text.dart';

/// Opens the album `track` is on.
void openAlbum(BuildContext context, core.TrackItem track) {
  final album = track.albumId;
  if (album == null) return;
  Navigator.of(context).push(
    CoverRoute<void>(
      builder: (context) => CollectionScreen(
        slug: track.source,
        player: AppScope.of(context).player,
        card: core.MediaCard(
          kind: core.CardKind.album,
          id: album,
          title: track.album,
          subtitle: track.artists,
          cover: track.coverLarge ?? track.cover,
        ),
      ),
    ),
  );
}

void openArtist(BuildContext context, String slug, core.ArtistLink artist) {
  Navigator.of(context).push(
    CoverRoute<void>(
      builder: (context) => ArtistScreen(slug: slug, artist: artist, player: AppScope.of(context).player),
    ),
  );
}

/// The "Go to album" and "Go to artist" entries `track` has links for. `leave` runs before
/// navigating, for a screen that should get out of the way first.
List<_Option> _goTo(BuildContext context, core.TrackItem track, VoidCallback? leave) {
  // Pages open in the tab on screen, under the mini player, even from the full player that
  // `leave` closes first.
  final host = tabNavigators.current?.context ?? Navigator.of(context).context;
  void go(void Function(BuildContext) to) {
    leave?.call();
    to(host);
  }

  return [
    if (track.albumId != null)
      _Option(CauceGlyph.album, context.t('track.goToAlbum'), () => go((context) => openAlbum(context, track))),
    for (final artist in track.artistLinks)
      _Option(
        CauceGlyph.user,
        track.artistLinks.length == 1
            ? context.t('track.goToArtist')
            : context.t('track.goToArtistNamed', {'name': artist.name}),
        () => go((context) => openArtist(context, track.source, artist)),
      ),
  ];
}

/// Every option for `track` in a sheet under its cover and names: download it, heart it, add it
/// to a playlist, then go to its album or artists. A file only has the ways to its album and
/// artists.
Future<void> showTrackOptions(BuildContext context, core.TrackItem track, {VoidCallback? leave}) {
  final streamed = track.source != 'local';
  final goTo = _goTo(context, track, leave);
  return behindSheet(
    showModalBottomSheet<void>(
      sheetAnimationStyle: sheetAnimation,
      context: context,
      useRootNavigator: true,
      barrierColor: Colors.black.withValues(alpha: 0.5),
      builder: (sheet) {
        void run(VoidCallback action) {
          Navigator.of(sheet).pop();
          action();
        }

        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SheetHandle(),
              Padding(
                padding: const EdgeInsets.fromLTRB(22, 6, 22, 14),
                child: Row(
                  children: [
                    Artwork(url: track.cover, size: 52, radius: 10),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            track.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            [track.artists, track.album].where((part) => part.isNotEmpty).join(' · '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 13.5, color: CauceColors.mutedForeground),
                          ),
                        ],
                      ),
                    ),
                    if (streamed) ...[const SizedBox(width: 10), ProviderTag(slug: track.source)],
                  ],
                ),
              ),
              Divider(height: 1, color: CauceColors.border),
              const SizedBox(height: 6),
              if (streamed) ...[
                _DownloadRow(track: track),
                _FavoriteRow(track: track),
                OptionRow(
                  glyph: CauceGlyph.plus,
                  label: context.t('track.addToPlaylist'),
                  onTap: () => run(() => showAddToPlaylist(context, track)),
                ),
                if (goTo.isNotEmpty)
                  Padding(
                    padding: EdgeInsets.symmetric(horizontal: 22, vertical: 6),
                    child: Divider(height: 1, color: CauceColors.border),
                  ),
              ],
              for (final option in goTo)
                OptionRow(glyph: option.glyph, label: option.label, onTap: () => run(option.run)),
              if (!streamed && goTo.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(context.t('track.noOptions'), style: TextStyle(color: CauceColors.mutedForeground)),
                ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    ),
  );
}

/// The little bar at the top of a sheet that says it can be dragged.
class SheetHandle extends StatelessWidget {
  const SheetHandle({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 36,
      height: 5,
      margin: const EdgeInsets.only(top: 8, bottom: 12),
      decoration: BoxDecoration(
        color: CauceColors.foreground.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(3),
      ),
    );
  }
}

/// The provider's two letters, quietly, for lists that mix sources.
class ProviderTag extends StatelessWidget {
  const ProviderTag({super.key, required this.slug});

  final String slug;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: CauceColors.foreground.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(
        brandOf(slug).letters,
        style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.4),
      ),
    );
  }
}

/// One row of the options sheet: an icon and what it does.
class OptionRow extends StatelessWidget {
  const OptionRow({super.key, required this.glyph, required this.label, required this.onTap, this.icon, this.color});

  final CauceGlyph glyph;
  final String label;
  final VoidCallback? onTap;

  /// Replaces the glyph, such as a progress ring.
  final Widget? icon;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: SizedBox(
        height: 54,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 22),
          child: Row(
            children: [
              SizedBox.square(
                dimension: 24,
                child: Center(child: icon ?? CauceIcon(glyph, size: 22, color: color, weight: 1.9)),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Text(label, style: TextStyle(fontSize: 17, color: color)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Downloads `track`, shows how far it has got, and takes the download away once it is there.
class _DownloadRow extends StatelessWidget {
  const _DownloadRow({required this.track});

  final core.TrackItem track;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: downloads,
      builder: (context, _) {
        final download = downloads.of(track);
        return switch (download?.state) {
          null => OptionRow(
            glyph: CauceGlyph.download,
            label: context.t('track.download'),
            onTap: () => downloads.download([track]),
          ),
          core.DownloadState.failed => OptionRow(
            glyph: CauceGlyph.retry,
            label: context.t('track.retry'),
            color: CauceColors.error,
            onTap: () => downloads.download([track]),
          ),
          core.DownloadState.queued || core.DownloadState.running => OptionRow(
            glyph: CauceGlyph.download,
            icon: SizedBox.square(
              dimension: 20,
              child: CircularProgressIndicator(
                strokeWidth: 2.2,
                value: download?.progress,
                backgroundColor: Colors.white.withValues(alpha: 0.18),
              ),
            ),
            label: download?.progress == null
                ? context.t('track.downloading')
                : '${context.t('track.downloading')} ${((download!.progress!) * 100).round()} %',
            onTap: () => downloads.remove(track),
          ),
          core.DownloadState.done => OptionRow(
            glyph: CauceGlyph.downloaded,
            label: context.t('track.downloaded'),
            color: CauceColors.accent,
            onTap: () => downloads.remove(track),
          ),
        };
      },
    );
  }
}

class _FavoriteRow extends StatelessWidget {
  const _FavoriteRow({required this.track});

  final core.TrackItem track;

  @override
  Widget build(BuildContext context) {
    final favorites = AppScope.of(context).favorites;
    return ListenableBuilder(
      listenable: favorites,
      builder: (context, _) {
        final saved = favorites.saved(track);
        return OptionRow(
          glyph: saved ? CauceGlyph.heartFilled : CauceGlyph.heart,
          label: context.t(saved ? 'track.liked' : 'track.like'),
          color: saved ? CauceColors.accent : null,
          onTap: () => favorites.toggle(track),
        );
      },
    );
  }
}

/// The account's playlists to put `track` into, with a way to make a new one for it.
Future<void> showAddToPlaylist(BuildContext context, core.TrackItem track) {
  return behindSheet(
    showModalBottomSheet<void>(
      sheetAnimationStyle: sheetAnimation,
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      barrierColor: Colors.black.withValues(alpha: 0.5),
      builder: (sheet) => _PlaylistPicker(track: track),
    ),
  );
}

/// A sheet's top bar: a way out at the start, its title, and an action at the end.
class _SheetBar extends StatelessWidget {
  const _SheetBar({required this.title, required this.leading, this.action});

  final String title;
  final Widget leading;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 56,
      child: NavigationToolbar(
        leading: leading,
        middle: Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
        ),
        trailing: action,
        middleSpacing: 8,
      ),
    );
  }
}

class _PlaylistPicker extends StatefulWidget {
  const _PlaylistPicker({required this.track});

  final core.TrackItem track;

  @override
  State<_PlaylistPicker> createState() => _PlaylistPickerState();
}

class _PlaylistPickerState extends State<_PlaylistPicker> {
  late final Future<List<core.PlaylistItem>> _playlists = core.ownPlaylists(slug: widget.track.source);
  bool _busy = false;

  Future<void> _add(String id, String name) async {
    setState(() => _busy = true);
    final track = widget.track;
    final added = context.t('playlist.added', {'name': name});
    final failed = context.t('playlist.addFailed', {'name': name});
    final retry = context.t('toast.retry');
    try {
      await core.addToPlaylist(slug: track.source, playlistId: id, trackId: track.id);
      showToast(Toast(title: added, detail: '${track.title} · ${track.artists}', cover: track.cover, badge: true));
      if (mounted) Navigator.of(context).pop();
    } catch (error) {
      showToast(
        Toast(
          title: failed,
          detail: explainError(error),
          cover: track.cover,
          badge: true,
          tone: ToastTone.error,
          action: retry,
          onAction: () => core.addToPlaylist(slug: track.source, playlistId: id, trackId: track.id).ignore(),
        ),
      );
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _create() async {
    final name = await showModalBottomSheet<String>(
      sheetAnimationStyle: sheetAnimation,
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      barrierColor: Colors.transparent,
      builder: (_) => _NewPlaylist(track: widget.track),
    );
    if (name == null || !mounted) return;
    setState(() => _busy = true);
    try {
      final id = await core.createPlaylist(slug: widget.track.source, name: name);
      await _add(id, name);
    } catch (error) {
      if (!mounted) return;
      showToast(Toast(title: context.t('playlist.createFailed'), detail: explainError(error), tone: ToastTone.error));
      setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final service = streamingServices
        .firstWhere(
          (service) => service.slug == widget.track.source,
          orElse: () => StreamingService(widget.track.source, widget.track.source),
        )
        .name;
    return SafeArea(
      // As tall as its playlists, up to most of the screen.
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.88),
        // Grows to the playlists once they load rather than jumping.
        child: AnimatedSize(
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _SheetBar(
                title: context.t('track.addToPlaylist'),
                leading: TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(context.t('search.cancel')),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(CauceMetrics.gutter, 0, CauceMetrics.gutter, 12),
                child: Text(
                  [widget.track.title, widget.track.artists].where((part) => part.isNotEmpty).join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 14, color: CauceColors.mutedForeground),
                ),
              ),
              _PlaylistRow(
                art: Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(color: CauceColors.raised, borderRadius: BorderRadius.circular(8)),
                  alignment: Alignment.center,
                  child: CauceIcon(CauceGlyph.plus, size: 24, color: CauceColors.accent, weight: 2.2),
                ),
                title: context.t('playlist.create'),
                accent: true,
                onTap: _busy ? null : _create,
              ),
              if (_busy) const LinearProgressIndicator(minHeight: 2),
              Overline(context.t('playlist.yours', {'service': service})),
              Flexible(
                child: FutureBuilder(
                  future: _playlists,
                  builder: (context, snapshot) {
                    if (snapshot.connectionState != ConnectionState.done) return const TrackListSkeleton(count: 3);
                    if (snapshot.hasError) {
                      return Padding(
                        padding: const EdgeInsets.all(CauceMetrics.gutter),
                        child: Text(explainError(snapshot.error!), style: TextStyle(color: CauceColors.error)),
                      );
                    }
                    final playlists = snapshot.data!;
                    if (playlists.isEmpty) {
                      return Padding(
                        padding: const EdgeInsets.all(CauceMetrics.gutter),
                        child: Text(context.t('playlist.none'), style: TextStyle(color: CauceColors.mutedForeground)),
                      );
                    }
                    return ListView(
                      shrinkWrap: true,
                      children: [
                        for (final playlist in playlists)
                          _PlaylistRow(
                            art: Artwork(url: playlist.cover, size: 56, radius: 8),
                            title: playlist.name,
                            subtitle: playlist.trackCount == 0
                                ? null
                                : context.t('playlist.count', {'count': playlist.trackCount}),
                            onTap: _busy ? null : () => _add(playlist.id, playlist.name),
                          ),
                      ],
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PlaylistRow extends StatelessWidget {
  const _PlaylistRow({required this.art, required this.title, this.subtitle, this.onTap, this.accent = false});

  final Widget art;
  final String title;
  final String? subtitle;
  final VoidCallback? onTap;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: CauceMetrics.gutter, vertical: 8),
        child: Row(
          children: [
            art,
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: accent ? FontWeight.w600 : FontWeight.w400,
                      color: accent ? CauceColors.accent : null,
                    ),
                  ),
                  if (subtitle != null)
                    Text(subtitle!, style: TextStyle(fontSize: 13.5, color: CauceColors.mutedForeground)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Asks for a new playlist's name over the picker, showing the cover it starts with, and
/// answers it.
class _NewPlaylist extends StatefulWidget {
  const _NewPlaylist({required this.track});

  final core.TrackItem track;

  @override
  State<_NewPlaylist> createState() => _NewPlaylistState();
}

class _NewPlaylistState extends State<_NewPlaylist> {
  final _name = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _done() {
    final name = _name.text.trim();
    if (name.isNotEmpty) Navigator.of(context).pop(name);
  }

  @override
  Widget build(BuildContext context) {
    final service = streamingServices
        .firstWhere(
          (service) => service.slug == widget.track.source,
          orElse: () => StreamingService(widget.track.source, widget.track.source),
        )
        .name;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * 0.88 - MediaQuery.viewInsetsOf(context).bottom,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ListenableBuilder(
                  listenable: _name,
                  builder: (context, _) => _SheetBar(
                    title: context.t('playlist.create'),
                    leading: IconButton(
                      onPressed: () => Navigator.of(context).pop(),
                      icon: CauceIcon(CauceGlyph.chevronLeft, color: CauceColors.accent, weight: 2.4),
                    ),
                    action: TextButton(
                      onPressed: _name.text.trim().isEmpty ? null : _done,
                      child: Text(
                        context.t('playlist.createShort'),
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Center(child: Artwork(url: widget.track.coverLarge ?? widget.track.cover, size: 160, radius: 16)),
                const SizedBox(height: 20),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: CauceMetrics.gutter),
                  child: TextField(
                    controller: _name,
                    autofocus: true,
                    textCapitalization: TextCapitalization.sentences,
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => _done(),
                    style: const TextStyle(fontFamily: displayFont, fontSize: 20, fontWeight: FontWeight.w700),
                    decoration: InputDecoration(
                      hintText: context.t('playlist.name'),
                      fillColor: CauceColors.raised,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 15),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(CauceMetrics.gutter, 14, CauceMetrics.gutter, 0),
                  child: Text(
                    context.t('playlist.createdIn', {'service': service, 'track': widget.track.title}),
                    style: CauceText.caption,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The menu a tap on the artist name opens, under the name: go to the album or an artist.
Future<void> showArtistMenu(BuildContext context, core.TrackItem track, {VoidCallback? leave}) async {
  final options = _goTo(context, track, leave);
  if (options.isEmpty) return;
  final chosen = await showDropdown<_Option>(
    context,
    items: [
      for (final option in options)
        DropdownItem(value: option, leading: CauceIcon(option.glyph, size: 20), title: option.label),
    ],
  );
  chosen?.run();
}

class _Option {
  const _Option(this.glyph, this.label, this.run);

  final CauceGlyph glyph;
  final String label;
  final VoidCallback run;
}
