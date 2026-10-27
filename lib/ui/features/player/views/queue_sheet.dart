import 'dart:async';
import '../../radio/radio_section.dart';

import 'package:flutter/material.dart';

import '../../../../src/rust/api/player.dart' as core;
import '../../../core/app_prefs.dart';
import '../../../core/app_scope.dart';
import '../../../core/artwork.dart';
import '../../../core/motion.dart';
import '../../../core/icons.dart';
import '../../../core/l10n.dart';
import '../../../core/theme.dart';
import '../../../core/tint_scope.dart';
import '../../../core/track_tile.dart';
import '../../../core/widgets.dart';
import '../../track/track_options.dart';
import '../view_models/player_view_model.dart';

/// The queue on a dark shade of the cover's colour: the track playing with its like and options,
/// what can be done to the queue, then what comes next, held and dragged to reorder. A tap plays
/// that track.
class QueueSheet extends StatefulWidget {
  const QueueSheet({super.key, required this.player});

  final PlayerViewModel player;

  static Future<void> open(BuildContext context, PlayerViewModel player) => showModalBottomSheet(
    sheetAnimationStyle: sheetAnimation,
    useRootNavigator: true,
    context: context,
    isScrollControlled: true,
    backgroundColor: CauceColors.light ? CauceColors.sheet : TintScope.of(context).vivid.shade(0.22, 0.05),
    barrierColor: Colors.black.withValues(alpha: 0.5),
    builder: (_) => QueueSheet(player: player),
  );

  @override
  State<QueueSheet> createState() => _QueueSheetState();
}

class _QueueSheetState extends State<QueueSheet> {
  /// What is still to play as just dragged, shown until the core's queue says the same.
  List<core.TrackItem>? _moved;

  PlayerViewModel get player => widget.player;

  /// Shows `upcoming` at once while `change` reaches the core.
  void _change(List<core.TrackItem> upcoming, Future<void> change) {
    setState(() => _moved = upcoming);
    unawaited(
      change.whenComplete(() {
        // A change the core turned down shows the queue as it is.
        Future.delayed(const Duration(milliseconds: 400), () {
          if (mounted) setState(() => _moved = null);
        });
      }),
    );
  }

  void _reorder(List<core.TrackItem> upcoming, int current, int from, int to) {
    if (to > from) to--;
    if (to == from) return;
    tick();
    final order = [...upcoming];
    order.insert(to, order.removeAt(from));
    _change(order, player.moveQueued(current + 1 + from, current + 1 + to));
  }

  void _remove(List<core.TrackItem> upcoming, int current, int offset) {
    thud();
    _change([...upcoming]..removeAt(offset), player.removeQueued(current + 1 + offset));
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    // As tall as the queue it holds when it opens: the track, the actions, a heading and the rows.
    final rows = player.queue.length - (player.index ?? 0) - 1;
    final fits = ((150 + 84 + 44 + 64.0 * rows + 40 + media.padding.bottom) / media.size.height).clamp(0.35, 0.92);
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: fits,
      minChildSize: fits < 0.25 ? fits : 0.25,
      maxChildSize: fits,
      builder: (context, scroll) => ListenableBuilder(
        listenable: player,
        builder: (context, _) {
          final queue = player.queue;
          final current = player.index ?? 0;
          if (current >= queue.length) return const SizedBox.shrink();
          final playing = queue[current];
          final fromCore = queue.sublist(current + 1);
          final moved = _moved;
          final upcoming = moved != null && !_same(moved, fromCore) ? moved : fromCore;
          return CustomScrollView(
            controller: scroll,
            slivers: [
              SliverToBoxAdapter(child: _NowPlaying(track: playing)),
              SliverToBoxAdapter(
                child: _Actions(player: player, hasUpcoming: upcoming.isNotEmpty),
              ),
              if (upcoming.isNotEmpty) ...[
                SliverToBoxAdapter(child: Overline(context.t('player.upNext'))),
                SliverReorderableList(
                  itemCount: upcoming.length,
                  onReorder: (from, to) => _reorder(upcoming, current, from, to),
                  proxyDecorator: (child, _, animation) => AnimatedBuilder(
                    animation: animation,
                    builder: (context, child) => Material(
                      color: CauceColors.light ? CauceColors.raised : TintScope.of(context).vivid.shade(0.3, 0.06),
                      elevation: 12 * animation.value,
                      shadowColor: Colors.black,
                      borderRadius: BorderRadius.circular(12),
                      child: child,
                    ),
                    child: child,
                  ),
                  itemBuilder: (context, offset) {
                    final track = upcoming[offset];
                    // The same track queued twice keeps a key per copy that moving others leaves alone.
                    final copy = upcoming
                        .take(offset)
                        .where((other) => other.id == track.id && other.source == track.source)
                        .length;
                    return Dismissible(
                      key: ValueKey('${track.source}/${track.id}/$copy'),
                      direction: DismissDirection.endToStart,
                      onDismissed: (_) => _remove(upcoming, current, offset),
                      background: Container(
                        color: CauceColors.error,
                        alignment: Alignment.centerRight,
                        padding: const EdgeInsets.only(right: 24),
                        child: const CauceIcon(CauceGlyph.trash, size: 22, color: Colors.white, weight: 2.2),
                      ),
                      child: TrackTile(
                        track: track,
                        mixed: true,
                        // Only the grip drags; holding the row opens its options.
                        trailing: ReorderableDragStartListener(
                          index: offset,
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: CauceIcon(CauceGlyph.grip, size: 20, color: Color(0x8CFFFFFF)),
                          ),
                        ),
                        onTap: () => player.jump(current + 1 + offset),
                      ),
                    );
                  },
                ),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(CauceMetrics.gutter, 12, CauceMetrics.gutter, 0),
                    child: Text(context.t('queue.hold'), style: CauceText.caption),
                  ),
                ),
              ],
              SliverToBoxAdapter(child: SizedBox(height: 40 + media.padding.bottom)),
            ],
          );
        },
      ),
    );
  }

  static bool _same(List<core.TrackItem> a, List<core.TrackItem> b) =>
      a.length == b.length &&
      [for (var i = 0; i < a.length; i++) a[i].id == b[i].id && a[i].source == b[i].source].every((same) => same);
}

/// The track playing, large, with its like and its options.
class _NowPlaying extends StatelessWidget {
  const _NowPlaying({required this.track});

  final core.TrackItem track;

  @override
  Widget build(BuildContext context) {
    final favorites = AppScope.of(context).favorites;
    return Padding(
      padding: const EdgeInsets.fromLTRB(CauceMetrics.gutter, 22, 8, 16),
      child: Row(
        children: [
          Artwork(url: track.cover, size: 84, radius: 12),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  track.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontFamily: displayFont, fontSize: 20, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 3),
                Text(
                  track.artists,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 15, color: CauceColors.mutedForeground),
                ),
              ],
            ),
          ),
          if (track.source != 'local')
            ListenableBuilder(
              listenable: favorites,
              builder: (context, _) {
                final saved = favorites.saved(track);
                return IconButton(
                  onPressed: () {
                    thud();
                    favorites.toggle(track);
                  },
                  icon: CauceIcon(
                    saved ? CauceGlyph.heartFilled : CauceGlyph.heart,
                    size: 24,
                    color: saved ? CauceColors.accent : null,
                  ),
                );
              },
            ),
          IconButton(
            onPressed: () => showTrackOptions(context, track),
            icon: const CauceIcon(CauceGlyph.more, size: 22),
          ),
        ],
      ),
    );
  }
}

/// Shuffle what is left, repeat, stop after this track, and clear what is left.
class _Actions extends StatelessWidget {
  const _Actions({required this.player, required this.hasUpcoming});

  final PlayerViewModel player;
  final bool hasUpcoming;

  @override
  Widget build(BuildContext context) {
    final repeat = player.repeat;
    return Padding(
      padding: const EdgeInsets.fromLTRB(CauceMetrics.gutter, 0, CauceMetrics.gutter, 8),
      child: Row(
        children: [
          _Action(
            glyph: CauceGlyph.shuffle,
            label: context.t('queue.shuffle'),
            onTap: hasUpcoming ? player.shuffleUpcoming : null,
          ),
          _Action(
            glyph: CauceGlyph.repeat,
            label: context.t(repeat == core.RepeatMode.one ? 'queue.repeatOne' : 'queue.repeat'),
            on: repeat != core.RepeatMode.off,
            onTap: player.cycleRepeat,
          ),
          // A station never ends, so there is no end to stop after.
          if (!isStation(player.track))
            _Action(
              glyph: CauceGlyph.clock,
              label: context.t('queue.stopAfter'),
              on: player.stopsAfterCurrent,
              onTap: () => player.stopAfterCurrent(!player.stopsAfterCurrent),
            ),
          _Action(
            glyph: CauceGlyph.trash,
            label: context.t('queue.clear'),
            onTap: hasUpcoming ? player.clearUpcoming : null,
          ),
        ],
      ),
    );
  }
}

class _Action extends StatelessWidget {
  const _Action({required this.glyph, required this.label, required this.onTap, this.on = false});

  final CauceGlyph glyph;
  final String label;
  final VoidCallback? onTap;

  /// A setting that is on, in the accent.
  final bool on;

  @override
  Widget build(BuildContext context) {
    final color = on ? CauceColors.accent : CauceColors.foreground;
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Opacity(
          opacity: onTap == null ? 0.4 : 1,
          child: Pressable(
            scale: 0.94,
            onTap: () {
              if (onTap == null) return;
              tick();
              onTap!();
            },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              height: 64,
              decoration: BoxDecoration(
                color: on ? CauceColors.accent.withValues(alpha: 0.18) : CauceColors.foreground.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  CauceIcon(glyph, size: 21, color: color, weight: 2.1),
                  const SizedBox(height: 5),
                  Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: color),
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
