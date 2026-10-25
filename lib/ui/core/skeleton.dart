import 'package:flutter/material.dart';

import 'theme.dart';
import 'tint_scope.dart';

/// Placeholders shaped like the content on its way, shimmering while it loads. One shimmer
/// drives every bone below it, so a whole screen of them pulses in step.
class Skeleton extends StatefulWidget {
  const Skeleton({super.key, required this.child});

  final Widget child;

  @override
  State<Skeleton> createState() => _SkeletonState();
}

/// Bones pulse between half and full strength every 1.2 s, all in step. They show only once
/// loading has taken 300 ms, so a quick load never flashes them.
class _SkeletonState extends State<Skeleton> with TickerProviderStateMixin {
  late final _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 600))
    ..repeat(reverse: true);
  late final _shown = AnimationController(vsync: this, duration: const Duration(milliseconds: 200));
  late final _wait = Future<void>.delayed(const Duration(milliseconds: 300), () {
    if (mounted) _shown.forward();
  });

  @override
  void initState() {
    super.initState();
    _wait.ignore();
  }

  @override
  void dispose() {
    _pulse.dispose();
    _shown.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _shown,
      child: FadeTransition(
        opacity: Tween(begin: 1.0, end: 0.5).animate(CurvedAnimation(parent: _pulse, curve: Curves.easeInOut)),
        child: widget.child,
      ),
    );
  }
}

/// One block of a skeleton.
class Bone extends StatelessWidget {
  const Bone({super.key, this.width, required this.height, this.radius = 8});

  final double? width;
  final double height;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(color: TintScope.of(context).surface, borderRadius: BorderRadius.circular(radius)),
    );
  }
}

/// Rows shaped like [TrackTile]s.
class TrackListSkeleton extends StatelessWidget {
  const TrackListSkeleton({super.key, this.count = 8});

  final int count;

  @override
  Widget build(BuildContext context) {
    return Skeleton(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var index = 0; index < count; index++)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: CauceMetrics.gutter, vertical: 7),
              child: Row(
                children: [
                  const Bone(width: 48, height: 48),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Varied widths read as text rather than as a grid of bars.
                        FractionallySizedBox(widthFactor: 0.5 + (index * 37 % 40) / 100, child: const Bone(height: 14)),
                        const SizedBox(height: 8),
                        FractionallySizedBox(widthFactor: 0.3 + (index * 23 % 30) / 100, child: const Bone(height: 11)),
                      ],
                    ),
                  ),
                  const SizedBox(width: 16),
                  const Bone(width: 32, height: 11),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Shelves shaped like the home screen's: a title over a row of cards.
class ShelvesSkeleton extends StatelessWidget {
  const ShelvesSkeleton({super.key, this.count = 3, this.card = 148});

  final int count;
  final double card;

  @override
  Widget build(BuildContext context) {
    return Skeleton(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var shelf = 0; shelf < count; shelf++) ...[
            const Padding(
              padding: EdgeInsets.fromLTRB(CauceMetrics.gutter, 20, CauceMetrics.gutter, 12),
              child: Bone(width: 160, height: 20),
            ),
            SizedBox(
              height: card + 52,
              child: ListView(
                scrollDirection: Axis.horizontal,
                physics: const NeverScrollableScrollPhysics(),
                padding: const EdgeInsets.symmetric(horizontal: CauceMetrics.gutter),
                children: [
                  for (var index = 0; index < 4; index++)
                    Padding(
                      padding: const EdgeInsets.only(right: 12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Bone(width: card, height: card, radius: CauceMetrics.radius),
                          const SizedBox(height: 10),
                          Bone(width: card * 0.8, height: 13),
                          const SizedBox(height: 6),
                          Bone(width: card * 0.5, height: 11),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}
