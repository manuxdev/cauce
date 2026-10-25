import 'package:flutter/material.dart';

import '../../../../src/rust/api/player.dart' as core;
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
import '../../home/views/home_screen.dart';
import '../../player/view_models/player_view_model.dart';

/// An artist: their photo filling the top, moving at half the scroll's speed and darkening, the
/// name over it with a play button, then their popular songs and releases.
class ArtistScreen extends StatefulWidget {
  const ArtistScreen({super.key, required this.slug, required this.artist, required this.player});

  final String slug;
  final core.ArtistLink artist;
  final PlayerViewModel player;

  @override
  State<ArtistScreen> createState() => _ArtistScreenState();
}

class _ArtistScreenState extends State<ArtistScreen> {
  late Future<core.ArtistPage> _page = _load();

  Future<core.ArtistPage> _load() => core.artistPage(slug: widget.slug, id: widget.artist.id);

  static const _photo = 380.0;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder(
      future: _page,
      builder: (context, snapshot) {
        final page = snapshot.data;
        final name = page?.name ?? widget.artist.name;
        final tracks = page?.topTracks ?? const <core.TrackItem>[];
        final play = tracks.isEmpty ? null : () => widget.player.playQueue(tracks, 0);
        return DetailPage(
          cover: page?.cover,
          title: name,
          lightness: 0.17,
          chroma: 0.035,
          titleAt: _photo - 30,
          compactAction: RoundPlayButton(onPressed: play),
          header: (context, offset) => _Photo(cover: page?.cover, name: name, offset: offset, height: _photo),
          children: [
            SizedBox(
              height: _photo,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(CauceMetrics.gutter, 0, CauceMetrics.gutter, 12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                      child: Text(
                        name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontFamily: displayFont,
                          fontSize: 46,
                          height: 1,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -1.2,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    ScrollFade(
                      from: _photo - 160,
                      child: RoundPlayButton(onPressed: play, size: 56),
                    ),
                  ],
                ),
              ),
            ),
            if (snapshot.hasError)
              Padding(
                padding: const EdgeInsets.only(top: 40),
                child: EmptyState(
                  glyph: CauceGlyph.offline,
                  badge: true,
                  title: context.t('home.offline'),
                  actions: [
                    FilledButton(
                      onPressed: () => setState(() => _page = _load()),
                      child: Text(context.t('common.retry')),
                    ),
                  ],
                ),
              )
            else if (page == null)
              const TrackListSkeleton(count: 5)
            else ...[
              if (tracks.isNotEmpty) Arrive(child: SectionHeader(context.t('artist.topSongs'))),
              Arrive(
                child: ListenableBuilder(
                  listenable: widget.player,
                  builder: (context, _) {
                    final current = widget.player.track;
                    return Column(
                      children: [
                        for (final (index, track) in tracks.take(10).indexed)
                          TrackTile(
                            track: track,
                            showAlbum: true,
                            playing: current?.id == track.id && current?.source == track.source,
                            onTap: () => widget.player.playQueue(tracks, index),
                          ),
                      ],
                    );
                  },
                ),
              ),
              if (page.albums.isNotEmpty)
                Arrive(
                  delay: const Duration(milliseconds: 30),
                  child: ShelfView(
                    shelf: core.HomeShelf(title: context.t('artist.albums'), cards: page.albums),
                    slug: widget.slug,
                    player: widget.player,
                  ),
                ),
            ],
          ],
        );
      },
    );
  }
}

/// The photo behind the top of the page. Scrolling up moves it at half speed and darkens it to
/// 60 %; pulling down stretches it from the top. Without a photo, the initials stand in large.
class _Photo extends StatelessWidget {
  const _Photo({required this.cover, required this.name, required this.offset, required this.height});

  final String? cover;
  final String name;
  final double offset;
  final double height;

  @override
  Widget build(BuildContext context) {
    final page = TintScope.of(context).tone(0.17, 0.035);
    final stretch = offset < 0 ? -offset : 0.0;
    final shade = (offset / height).clamp(0.0, 1.0) * 0.6;
    final provider = artworkProvider(cover);
    final initials = name.split(' ').where((word) => word.isNotEmpty).take(2).map((word) => word[0]).join();
    return Positioned(
      left: 0,
      right: 0,
      top: offset > 0 ? -offset * 0.5 : 0,
      height: height + stretch,
      child: Stack(
        fit: StackFit.expand,
        children: [
          ColoredBox(color: TintScope.of(context).shade(0.5, 0.08)),
          if (provider == null)
            Center(
              child: Text(
                initials.toUpperCase(),
                style: TextStyle(
                  fontFamily: displayFont,
                  fontSize: 200,
                  fontWeight: FontWeight.w700,
                  color: Colors.white.withValues(alpha: 0.12),
                ),
              ),
            )
          else
            Image(image: provider, fit: BoxFit.cover, errorBuilder: (_, _, _) => const SizedBox.shrink()),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                stops: const [0.45, 1],
                colors: [page.withValues(alpha: 0), page],
              ),
            ),
          ),
          ColoredBox(color: Colors.black.withValues(alpha: shade)),
        ],
      ),
    );
  }
}
