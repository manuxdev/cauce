import 'package:flutter/material.dart';

import '../../../../src/rust/api/player.dart' as core;
import '../../../core/artwork.dart';
import '../../../core/icons.dart';
import '../../../core/l10n.dart';
import '../../../core/motion.dart';
import '../../../core/service_picker.dart';
import '../../../core/skeleton.dart';
import '../../../core/theme.dart';
import '../../../core/tint.dart';
import '../../../core/tint_scope.dart';
import '../../../core/widgets.dart';
import '../../home/views/home_screen.dart';
import '../../player/view_models/player_view_model.dart';

/// A style's page: a band of its colour with its name, then the service's shelves for it, the way
/// the home feed draws its own. The page takes the style's hue.
class GenreScreen extends StatefulWidget {
  const GenreScreen({super.key, required this.slug, required this.genre, required this.hue, required this.player});

  final String slug;
  final core.GenreCard genre;
  final double hue;
  final PlayerViewModel player;

  @override
  State<GenreScreen> createState() => _GenreScreenState();
}

class _GenreScreenState extends State<GenreScreen> {
  late Future<List<core.HomeShelf>> _shelves = _load();

  Future<List<core.HomeShelf>> _load() => core.genrePage(
    slug: widget.slug,
    id: widget.genre.id,
    titles: core.GenreTitles(
      tracks: context.t('search.songs'),
      albums: context.t('search.albums'),
      artists: context.t('search.artists'),
      playlists: context.t('search.playlists'),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.paddingOf(context).top;
    final picture = artworkProvider(widget.genre.cover);
    return AnimatedTint(
      tint: Tint(widget.hue),
      child: Builder(
        builder: (context) => ColoredBox(
          color: TintScope.of(context).page,
          child: Scaffold(
            body: FutureBuilder(
              future: _shelves,
              builder: (context, snapshot) => ListView(
                padding: const EdgeInsets.only(bottom: bottomChromeInset),
                children: [
                  Container(
                    height: top + 196,
                    decoration: BoxDecoration(
                      color: oklch(0.5, 0.12, widget.hue),
                      image: picture == null
                          ? null
                          : DecorationImage(
                              image: picture,
                              fit: BoxFit.cover,
                              colorFilter: const ColorFilter.mode(Color(0x66000000), BlendMode.darken),
                            ),
                    ),
                    padding: EdgeInsets.fromLTRB(CauceMetrics.gutter, top, CauceMetrics.gutter, 24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Transform.translate(
                          offset: const Offset(-12, 0),
                          child: IconButton(
                            onPressed: () => Navigator.of(context).maybePop(),
                            icon: const CauceIcon(CauceGlyph.chevronLeft, size: 24, weight: 2.4),
                          ),
                        ),
                        const Spacer(),
                        Text(
                          widget.genre.name,
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
                      ],
                    ),
                  ),
                  if (snapshot.connectionState != ConnectionState.done)
                    const ShelvesSkeleton()
                  else if (snapshot.hasError)
                    Padding(
                      padding: const EdgeInsets.only(top: 80),
                      child: EmptyState(
                        glyph: CauceGlyph.offline,
                        badge: true,
                        title: context.t('home.offline'),
                        actions: [
                          FilledButton(
                            onPressed: () => setState(() => _shelves = _load()),
                            child: Text(context.t('common.retry')),
                          ),
                        ],
                      ),
                    )
                  else if (snapshot.data!.isEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 80),
                      child: EmptyState(glyph: CauceGlyph.album, title: context.t('home.empty')),
                    )
                  else
                    for (final (index, shelf) in snapshot.data!.indexed)
                      Arrive(
                        delay: Duration(milliseconds: 30 * index.clamp(0, 6)),
                        child: ShelfView(shelf: shelf, slug: widget.slug, player: widget.player),
                      ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
