import 'package:flutter/material.dart';

import '../../../../src/rust/api/player.dart' as core;
import '../../../core/cards.dart';
import '../../../core/icons.dart';
import '../../../core/motion.dart';
import '../../../core/l10n.dart';
import '../../../core/selected_service.dart';
import '../../../core/service_picker.dart';
import '../../../core/skeleton.dart';
import '../../../core/track_tile.dart';
import '../../../core/widgets.dart';
import '../../accounts/view_models/accounts_view_model.dart';
import '../../artist/views/artist_screen.dart';
import '../../player/view_models/player_view_model.dart';
import 'collection_screen.dart';
import '../../../core/status_band.dart';

/// What the chosen service recommends, as shelves under the tab's big title.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.accounts, required this.player, required this.onAccounts});

  final AccountsViewModel accounts;
  final PlayerViewModel player;
  final VoidCallback onAccounts;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final Map<String, Future<List<core.HomeShelf>>> _feeds = {};

  /// How far the shelves have scrolled, which the title above them follows.
  final _offset = ValueNotifier<double>(0);

  @override
  void dispose() {
    _offset.dispose();
    super.dispose();
  }

  Future<List<core.HomeShelf>> _feed(String slug, {bool fresh = false}) {
    if (fresh) _feeds.remove(slug);
    return _feeds.putIfAbsent(slug, () => core.home(slug: slug));
  }

  @override
  Widget build(BuildContext context) {
    final title = context.t('tab.home');
    return ListenableBuilder(
      listenable: Listenable.merge([widget.accounts, selectedService]),
      builder: (context, _) {
        final connected = widget.accounts.connected;
        if (connected.isEmpty) {
          return Scaffold(
            body: SafeArea(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  PageTitle(title),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: bottomChromeInset / 2),
                      child: switch (widget.accounts) {
                        final accounts when accounts.restoringAny => const ShelvesSkeleton(),
                        final accounts when accounts.unreachable => EmptyState(
                          glyph: CauceGlyph.offline,
                          badge: true,
                          title: context.t('home.offline'),
                          message: context.t('home.offline.downloads'),
                          actions: [
                            FilledButton(onPressed: accounts.restoreAll, child: Text(context.t('common.retry'))),
                          ],
                        ),
                        _ => NothingConnected(
                          message: context.t('home.nothingConnected'),
                          onAccounts: widget.onAccounts,
                        ),
                      },
                    ),
                  ),
                ],
              ),
            ),
          );
        }
        final slug = selectedService.among([for (final service in connected) service.slug])!;
        final service = connected.firstWhere((service) => service.slug == slug);
        return Scaffold(
          body: FutureBuilder(
            future: _feed(slug),
            builder: (context, snapshot) {
              final loading = snapshot.connectionState != ConnectionState.done;
              final heading = PageTitle(
                title,
                trailing: ProviderAvatar(services: connected, selected: slug, onSelected: selectedService.select),
              );
              final shelves = FoldsDock(
                child: PullToRefresh(
                  onRefresh: () async {
                    setState(() => _feed(slug, fresh: true));
                    await _feeds[slug];
                  },
                  busy: loading && snapshot.hasData,
                  builder: (context, header) => NotificationListener<ScrollUpdateNotification>(
                    onNotification: (notification) {
                      if (notification.depth == 0) _offset.value = notification.metrics.pixels;
                      return false;
                    },
                    child: CustomScrollView(
                      physics: const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
                      slivers: [
                        SliverPadding(padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top)),
                        // Room for the title, which sits above the shelves rather than in them.
                        SliverToBoxAdapter(
                          child: IgnorePointer(child: Opacity(opacity: 0, child: heading)),
                        ),
                        SliverToBoxAdapter(
                          child: StatusBands(accounts: widget.accounts, onAccounts: widget.onAccounts),
                        ),
                        SliverToBoxAdapter(child: header),
                        SliverPadding(
                          padding: const EdgeInsets.only(bottom: bottomChromeInset),
                          sliver: SliverList.list(
                            children: [
                              if (loading && !snapshot.hasData)
                                const ShelvesSkeleton()
                              else if (snapshot.hasError)
                                Padding(
                                  padding: const EdgeInsets.only(top: 120),
                                  child: EmptyState(
                                    glyph: CauceGlyph.offline,
                                    badge: true,
                                    title: context.t('home.offline'),
                                    message: context.t('home.offline.detail', {'service': service.name}),
                                    actions: [
                                      FilledButton(
                                        onPressed: () => setState(() => _feed(slug, fresh: true)),
                                        child: Text(context.t('common.retry')),
                                      ),
                                    ],
                                  ),
                                )
                              else if (snapshot.data!.isEmpty)
                                Padding(
                                  padding: const EdgeInsets.only(top: 120),
                                  child: EmptyState(glyph: CauceGlyph.album, title: context.t('home.empty')),
                                )
                              else
                                for (final (index, shelf) in snapshot.data!.indexed)
                                  Arrive(
                                    delay: Duration(milliseconds: 30 * index.clamp(0, 6)),
                                    child: ShelfView(shelf: shelf, slug: slug, player: widget.player),
                                  ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
              // The title and the provider avatar stay put rather than scroll: they fade up and away
              // as the shelves leave the top, and come back only once they are at the top again.
              // Pulled past the top, they come down with the shelves.
              return Stack(
                children: [
                  shelves,
                  Positioned(
                    top: MediaQuery.paddingOf(context).top,
                    left: 0,
                    right: 0,
                    child: ValueListenableBuilder(
                      valueListenable: _offset,
                      child: heading,
                      builder: (context, offset, heading) {
                        final shown = offset <= 2;
                        return Transform.translate(
                          offset: Offset(0, offset < 0 ? -offset : 0),
                          child: IgnorePointer(
                            ignoring: !shown,
                            child: AnimatedSlide(
                              offset: shown ? Offset.zero : const Offset(0, -0.3),
                              duration: const Duration(milliseconds: 260),
                              curve: CauceCurves.exit,
                              child: AnimatedOpacity(
                                opacity: shown ? 1 : 0,
                                duration: const Duration(milliseconds: 200),
                                curve: CauceCurves.exit,
                                child: heading,
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              );
            },
          ),
        );
      },
    );
  }
}

/// One shelf. Songs are a short list with a play action; artists a row of circles; anything
/// else a row of cards that open.
class ShelfView extends StatelessWidget {
  const ShelfView({super.key, required this.shelf, required this.slug, required this.player});

  final core.HomeShelf shelf;
  final String slug;
  final PlayerViewModel player;

  void _open(BuildContext context, core.MediaCard card, [Object? heroTag]) {
    final track = card.track;
    if (track != null) {
      final tracks = [for (final card in shelf.cards) ?card.track];
      player.playQueue(tracks, tracks.indexWhere((queued) => queued.id == track.id));
      return;
    }
    Navigator.of(context).push(
      CoverRoute<void>(
        builder: (_) => card.kind == core.CardKind.artist
            ? ArtistScreen(
                slug: slug,
                artist: core.ArtistLink(id: card.id, name: card.title),
                player: player,
              )
            : CollectionScreen(slug: slug, card: card, player: player, heroTag: heroTag),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cards = shelf.cards;
    final tracks = [for (final card in cards) ?card.track];
    if (tracks.length == cards.length && tracks.isNotEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionHeader(shelf.title, action: context.t('common.play'), onAction: () => player.playQueue(tracks, 0)),
          ListenableBuilder(
            listenable: player,
            builder: (context, _) => Column(
              children: [
                for (final (index, track) in tracks.take(4).indexed)
                  TrackTile(
                    track: track,
                    playing: player.track?.id == track.id && player.track?.source == track.source,
                    onTap: () => player.playQueue(tracks, index),
                  ),
              ],
            ),
          ),
        ],
      );
    }
    final artists = cards.every((card) => card.kind == core.CardKind.artist);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(shelf.title),
        Shelf(
          height: artists ? 150 : 200,
          children: [
            for (final card in cards)
              card.kind == core.CardKind.artist
                  ? ArtistCircle(cover: card.cover, name: card.title, onTap: () => _open(context, card))
                  : ReleaseCard(
                      cover: card.cover,
                      title: card.title,
                      subtitle: card.subtitle,
                      heroTag: coverTag(shelf.title, card.id),
                      onTap: () => _open(context, card, coverTag(shelf.title, card.id)),
                    ),
          ],
        ),
      ],
    );
  }
}
