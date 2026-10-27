import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'app_prefs.dart';
import '../../src/rust/api/player.dart' hide downloads;
import '../features/downloads/downloads_view_model.dart';
import '../features/track/track_options.dart';
import 'artwork.dart';
import 'icons.dart';
import 'l10n.dart';
import 'theme.dart';
import 'widgets.dart';

/// One track in a list: cover (or its number on an album), title, artists and album with its
/// download state, then the length or a playing mark, and the options button.
class TrackTile extends StatelessWidget {
  const TrackTile({
    super.key,
    required this.track,
    required this.onTap,
    this.playing = false,
    this.number,
    this.showAlbum = true,
    this.trailing,
    this.mixed = false,
    this.onRemove,
  });

  final TrackItem track;
  final VoidCallback onTap;
  final bool playing;

  /// Shown in place of the cover, for a release's own track list.
  final int? number;
  final bool showAlbum;

  /// Replaces the options button, such as a grip in the queue.
  final Widget? trailing;

  /// In a list mixing providers, where each row can say which one it comes from.
  final bool mixed;

  /// Takes the row out of the playlist it is in, offered among its options.
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final subtitle = [track.artists, if (showAlbum) track.album].where((part) => part.isNotEmpty).join(' · ');
    final (height, artwork, pad) = switch (appPrefs.density) {
      ListDensity.compact => (52.0, 40.0, 4.0),
      ListDensity.normal => (62.0, 48.0, 7.0),
      ListDensity.comfortable => (72.0, 54.0, 10.0),
    };
    return Opacity(
      opacity: track.playable ? 1 : 0.4,
      child: InkWell(
        // One the provider cannot play may still be found in another.
        onTap: track.playable || appPrefs.substitute ? onTap : null,
        onLongPress: appPrefs.holdForOptions ? () => showTrackOptions(context, track, onRemove: onRemove) : null,
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: height),
          child: Padding(
            padding: EdgeInsets.fromLTRB(20, pad, 12, pad),
            child: ListenableBuilder(
              listenable: downloads,
              builder: (context, _) {
                final download = downloads.of(track);
                final failed = download?.state == DownloadState.failed;
                return Row(
                  children: [
                    if (number case final number?)
                      SizedBox(
                        width: 22,
                        child: Text(
                          '$number',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w500,
                            color: playing ? CauceColors.accent : CauceColors.mutedForeground,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      )
                    else
                      Artwork(url: track.cover, size: artwork, radius: 8),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            track.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 16,
                              height: 1.25,
                              fontWeight: FontWeight.w500,
                              color: playing ? CauceColors.accent : CauceColors.foreground,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Row(
                            children: [
                              if (mixed && appPrefs.providerTag && track.source != 'local') _Tag(track.source),
                              ?_mark(context, download),
                              Flexible(
                                child: Text(
                                  subtitle,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(fontSize: 13.5, height: 1.25, color: CauceColors.mutedForeground),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    if (failed)
                      _RetryButton(onTap: () => downloads.download([track]))
                    else if (playing)
                      const SizedBox(
                        width: 40,
                        child: Align(alignment: Alignment.centerRight, child: PlayingBars()),
                      )
                    else
                      SizedBox(
                        width: 40,
                        child: Text(
                          // A station has no length to show.
                          track.durationMs == BigInt.zero
                              ? ''
                              : formatDuration(Duration(milliseconds: track.durationMs.toInt())),
                          textAlign: TextAlign.right,
                          style: TextStyle(
                            fontSize: 14,
                            color: CauceColors.mutedForeground,
                            fontFeatures: [FontFeature.tabularFigures()],
                          ),
                        ),
                      ),
                    trailing ??
                        SizedBox(
                          width: 36,
                          height: 44,
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () => showTrackOptions(context, track, onRemove: onRemove),
                            child: Center(
                              child: CauceIcon(CauceGlyph.more, size: 20, color: CauceColors.mutedForeground),
                            ),
                          ),
                        ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  /// The download state before the artists: a mark, a ring with how far it got, or the error.
  static Widget? _mark(BuildContext context, DownloadItem? download) {
    final state = download?.state;
    if (state == null) return null;
    return Padding(
      padding: const EdgeInsets.only(right: 5),
      child: _DownloadMark(state: state, progress: download?.progress),
    );
  }
}

/// How a download stands, moving between its states: the ring fills smoothly, closes and gives
/// way to a check drawn in when it ends, and a failure shakes twice and turns red.
class _DownloadMark extends StatefulWidget {
  const _DownloadMark({required this.state, required this.progress});

  final DownloadState state;
  final double? progress;

  @override
  State<_DownloadMark> createState() => _DownloadMarkState();
}

class _DownloadMarkState extends State<_DownloadMark> with SingleTickerProviderStateMixin {
  /// Runs once when the download settles, done or failed; at rest it stays at the end.
  late final _settle = AnimationController(vsync: this, duration: const Duration(milliseconds: 300), value: 1);

  @override
  void didUpdateWidget(_DownloadMark old) {
    super.didUpdateWidget(old);
    final settled = widget.state == DownloadState.done || widget.state == DownloadState.failed;
    if (settled && old.state != widget.state && !MediaQuery.disableAnimationsOf(context)) {
      _settle.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _settle.dispose();
    super.dispose();
  }

  Widget _ring(double progress, {double scale = 1}) => Transform.scale(
    scale: scale,
    child: SizedBox.square(
      dimension: 11,
      child: CircularProgressIndicator(
        strokeWidth: 2,
        value: progress,
        backgroundColor: Colors.white.withValues(alpha: 0.18),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _settle,
      builder: (context, _) {
        final t = _settle.value;
        return switch (widget.state) {
          // The ring closes and shrinks away in the first part, then the check draws in from the
          // left over the rest.
          DownloadState.done => SizedBox(
            width: 13,
            height: 13,
            child: Stack(
              alignment: Alignment.center,
              children: [
                if (t < 0.15) _ring(1, scale: 1 - t / 0.15),
                ClipRect(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    widthFactor: Curves.easeOut.transform(((t - 0.13) / 0.87).clamp(0.0, 1.0)),
                    child: CauceIcon(CauceGlyph.downloaded, size: 13, color: CauceColors.accent),
                  ),
                ),
              ],
            ),
          ),
          DownloadState.queued || DownloadState.running => Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              TweenAnimationBuilder<double>(
                tween: Tween(end: widget.progress ?? 0),
                duration: const Duration(milliseconds: 200),
                builder: (context, progress, _) => _ring(widget.progress == null ? 0 : progress),
              ),
              const SizedBox(width: 4),
              Text(
                '${((widget.progress ?? 0) * 100).round()} %',
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                  color: CauceColors.accent,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          // Two swings of 3 points either way.
          DownloadState.failed => Transform.translate(
            offset: Offset(3 * math.sin(t * 4 * math.pi) * (1 - t), 0),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                CauceIcon(CauceGlyph.alert, size: 13, color: CauceColors.error, weight: 2.2),
                const SizedBox(width: 4),
                Text(
                  context.t('common.error'),
                  style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: CauceColors.error),
                ),
              ],
            ),
          ),
        };
      },
    );
  }
}

class _RetryButton extends StatelessWidget {
  const _RetryButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 30,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: CauceColors.foreground.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(15),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CauceIcon(CauceGlyph.retry, size: 14, weight: 2.2),
            const SizedBox(width: 5),
            Text(context.t('common.retry'), style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }
}

/// Four accent bars bouncing, the mark of what is playing.
class PlayingBars extends StatefulWidget {
  const PlayingBars({super.key, this.color});

  /// The accent when unset.
  final Color? color;

  @override
  State<PlayingBars> createState() => _PlayingBarsState();
}

class _PlayingBarsState extends State<PlayingBars> with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(vsync: this, duration: const Duration(milliseconds: 1200))..repeat();

  static const _phases = [0.0, 0.35, 0.7, 0.15];

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final still = MediaQuery.disableAnimationsOf(context);
    return SizedBox(
      height: 16,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) => Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            for (final (index, phase) in _phases.indexed) ...[
              if (index > 0) const SizedBox(width: 2.5),
              Container(
                width: 3,
                height: still ? const [9.0, 16.0, 6.0, 12.0][index] : 5 + 11 * _wave(_controller.value + phase),
                decoration: BoxDecoration(
                  color: (widget.color ?? CauceColors.accent),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  static double _wave(double t) => (1 - (2 * (t % 1) - 1).abs());
}

/// The provider's letters in its colour, before the artist in a list that mixes providers.
class _Tag extends StatelessWidget {
  const _Tag(this.slug);

  final String slug;

  @override
  Widget build(BuildContext context) {
    final brand = brandOf(slug);
    return Container(
      margin: const EdgeInsets.only(right: 6),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(color: brand.color.withValues(alpha: 0.18), borderRadius: BorderRadius.circular(4)),
      child: Text(
        brand.letters,
        style: TextStyle(fontSize: 10, height: 1.2, fontWeight: FontWeight.w700, color: brand.color),
      ),
    );
  }
}
