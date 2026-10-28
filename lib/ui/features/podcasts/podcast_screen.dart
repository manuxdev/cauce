import 'package:flutter/material.dart';

import '../../../src/rust/api/player.dart' as core;
import '../../core/artwork.dart';
import '../../core/detail_page.dart';
import '../../core/error_text.dart';
import '../../core/icons.dart';
import '../../core/l10n.dart';
import '../../core/motion.dart';
import '../../core/skeleton.dart';
import '../../core/status_band.dart';
import '../../core/theme.dart';
import '../../core/tint_scope.dart';
import '../../core/toast.dart';
import '../../core/widgets.dart';
import '../downloads/downloads_view_model.dart';
import '../player/view_models/player_view_model.dart';
import '../track/track_options.dart';
import 'podcasts_section.dart';

const _cover = 200.0;

/// A show's page: its artwork, title, author and description, subscribing, and its episodes
/// newest first with how far each was heard. Pulling down reads the feed again.
class PodcastScreen extends StatefulWidget {
  const PodcastScreen({super.key, required this.feedUrl, required this.player, this.show});

  final String feedUrl;
  final PlayerViewModel player;

  /// What the list already knew of the show, drawn while its feed is read.
  final core.PodcastShow? show;

  @override
  State<PodcastScreen> createState() => _PodcastScreenState();
}

class _PodcastScreenState extends State<PodcastScreen> {
  core.PodcastPage? _page;
  Object? _error;
  bool _expanded = false;

  /// The episode playing and whether it is, last time the progress was read.
  String? _heard;

  @override
  void initState() {
    super.initState();
    _load(refresh: false);
    widget.player.addListener(_followPlayer);
  }

  @override
  void dispose() {
    widget.player.removeListener(_followPlayer);
    super.dispose();
  }

  Future<void> _load({required bool refresh}) async {
    try {
      final page = await core.podcastPage(feedUrl: widget.feedUrl, refresh: refresh);
      if (mounted) {
        setState(() {
          _page = page;
          _error = null;
        });
      }
    } catch (error) {
      if (!mounted) return;
      // A page already drawn stays, and the failed refresh says so.
      if (_page != null) {
        showToast(Toast(title: context.t('common.error'), detail: explainError(error), tone: ToastTone.error));
      } else {
        setState(() => _error = error);
      }
    }
  }

  /// Reads the progress again, with no network, once an episode starts or stops.
  void _followPlayer() {
    final track = widget.player.track;
    final heard = '${isEpisode(track) ? track!.id : ''}:${widget.player.playing}';
    if (heard == _heard) return;
    _heard = heard;
    if (_page != null) _load(refresh: false);
  }

  Future<void> _subscribe(core.PodcastPage page) async {
    final on = !page.subscribed;
    try {
      await core.podcastSubscribe(feedUrl: widget.feedUrl, subscribed: on);
      await _load(refresh: false);
    } catch (error) {
      if (mounted) {
        showToast(Toast(title: context.t('common.error'), detail: explainError(error), tone: ToastTone.error));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final page = _page;
    final show = page?.podcast ?? widget.show;
    final top = MediaQuery.paddingOf(context).top;
    return ListenableBuilder(
      listenable: Listenable.merge([online, downloads, widget.player]),
      builder: (context, _) => DetailPage(
        cover: show?.artwork,
        title: show?.title ?? '',
        titleAt: top + 50 + _cover + 40,
        onRefresh: online.value ? () => _load(refresh: true) : null,
        header: (context, offset) {
          final gone = (offset / (_cover + 50)).clamp(0.0, 1.0);
          return Positioned(
            top: top + 50 - offset.clamp(0.0, double.infinity) * 0.6,
            left: 0,
            right: 0,
            child: Center(
              child: Opacity(
                opacity: 1 - gone,
                child: Transform.scale(
                  scale: 1 - 0.3 * gone,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: const [BoxShadow(color: Color(0x73000000), blurRadius: 40, offset: Offset(0, 18))],
                    ),
                    child: Artwork(url: show?.artwork, size: _cover, radius: 16),
                  ),
                ),
              ),
            ),
          );
        },
        children: [
          SizedBox(height: top + 50 + _cover + 24),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: CauceMetrics.gutter),
            child: Column(
              children: [
                Text(show?.title ?? '', textAlign: TextAlign.center, style: CauceText.headline),
                if (show != null && show.author.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    show.author,
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 15, color: CauceColors.mutedForeground),
                  ),
                ],
                if (page != null) ...[
                  const SizedBox(height: 16),
                  _SubscribeButton(subscribed: page.subscribed, onTap: () => _subscribe(page)),
                ],
                if (show != null && show.description.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  GestureDetector(
                    onTap: () => setState(() => _expanded = !_expanded),
                    child: AnimatedSize(
                      duration: const Duration(milliseconds: 200),
                      alignment: Alignment.topCenter,
                      child: Text(
                        show.description,
                        maxLines: _expanded ? null : 3,
                        overflow: _expanded ? TextOverflow.visible : TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 14.5, height: 1.4, color: CauceColors.mutedForeground),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (page != null) ...[
            SectionHeader(context.t('podcasts.episodes'), count: page.episodes.length),
            if (page.episodes.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 24),
                child: EmptyState(glyph: CauceGlyph.headphones, title: context.t('podcasts.noEpisodes')),
              ),
            for (final episode in page.episodes) _EpisodeRow(episode: episode, player: widget.player),
          ] else if (_error case final error?)
            Padding(
              padding: const EdgeInsets.only(top: 32),
              child: EmptyState(
                glyph: CauceGlyph.alert,
                badge: true,
                danger: true,
                title: context.t('common.error'),
                message: explainError(error),
                actions: [
                  FilledButton(
                    onPressed: () {
                      setState(() => _error = null);
                      _load(refresh: true);
                    },
                    child: Text(context.t('common.retry')),
                  ),
                ],
              ),
            )
          else
            const TrackListSkeleton(),
        ],
      ),
    );
  }
}

class _SubscribeButton extends StatelessWidget {
  const _SubscribeButton({required this.subscribed, required this.onTap});

  final bool subscribed;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Pressable(
      scale: 0.95,
      onTap: onTap,
      child: Container(
        height: 38,
        padding: const EdgeInsets.symmetric(horizontal: 18),
        decoration: BoxDecoration(
          color: subscribed ? TintScope.of(context).surface : CauceColors.accent,
          borderRadius: BorderRadius.circular(19),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            CauceIcon(
              subscribed ? CauceGlyph.check : CauceGlyph.plus,
              size: 15,
              weight: 2.4,
              color: subscribed ? CauceColors.foreground : CauceColors.onAccent,
            ),
            const SizedBox(width: 6),
            Text(
              context.t(subscribed ? 'podcasts.subscribed' : 'podcasts.subscribe'),
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: subscribed ? CauceColors.foreground : CauceColors.onAccent,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One episode: its date, title, and length, what is left or that it was played, with a bar
/// while it is under way. Offline, only a downloaded one plays.
class _EpisodeRow extends StatelessWidget {
  const _EpisodeRow({required this.episode, required this.player});

  final core.PodcastEpisode episode;
  final PlayerViewModel player;

  @override
  Widget build(BuildContext context) {
    final track = episode.track;
    final download = downloads.of(track);
    final playable = online.value || download?.state == core.DownloadState.done;
    final current = player.track;
    final playing = current?.source == track.source && current?.id == track.id;
    final progress = episodeProgress(
      durationMs: track.durationMs,
      positionMs: episode.positionMs,
      played: episode.played,
    );
    final left = episodeLeft(durationMs: track.durationMs, positionMs: episode.positionMs, played: episode.played);
    final length = track.durationMs == BigInt.zero
        ? ''
        : formatDuration(Duration(milliseconds: track.durationMs.toInt()));
    final status = episode.played
        ? context.t('podcasts.played')
        : left != null
        ? context.t('podcasts.left', {'time': formatDuration(left)})
        : length;
    final date = episodeDate(episode.publishedSecs, DateTime.now(), context.t('podcasts.months').split(' '));
    return Opacity(
      opacity: playable ? 1 : 0.4,
      child: InkWell(
        // Only this episode plays: the next in a feed is rarely the one wanted next.
        onTap: playable ? () => player.playQueue([track], 0) : null,
        onLongPress: () => showTrackOptions(context, track),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 10, 12, 10),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (date.isNotEmpty)
                      Text(date, style: TextStyle(fontSize: 12.5, color: CauceColors.mutedForeground)),
                    const SizedBox(height: 2),
                    Text(
                      track.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 16,
                        height: 1.25,
                        fontWeight: FontWeight.w500,
                        color: playing ? CauceColors.accent : CauceColors.foreground,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        if (download?.state == core.DownloadState.done) ...[
                          CauceIcon(CauceGlyph.downloaded, size: 13, color: CauceColors.accent),
                          const SizedBox(width: 5),
                        ],
                        Text(
                          status,
                          style: TextStyle(
                            fontSize: 13,
                            color: CauceColors.mutedForeground,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                        if (progress != null) ...[
                          const SizedBox(width: 10),
                          SizedBox(
                            width: 60,
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(2),
                              child: LinearProgressIndicator(
                                value: progress,
                                minHeight: 3,
                                color: CauceColors.accent,
                                backgroundColor: CauceColors.border,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
              SizedBox(
                width: 36,
                height: 44,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => showTrackOptions(context, track),
                  child: Center(child: CauceIcon(CauceGlyph.more, size: 20, color: CauceColors.mutedForeground)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
