import 'package:flutter/material.dart';

import 'artwork.dart';
import 'motion.dart';
import 'theme.dart';

/// An album or playlist: its cover, then its title and a quiet line under it. It sinks a little
/// while pressed.
class ReleaseCard extends StatelessWidget {
  const ReleaseCard({
    super.key,
    required this.cover,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.size = 136,
    this.heroTag,
  });

  /// Flies the cover to the page it opens, which uses the same tag.
  final Object? heroTag;

  final String? cover;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Pressable(
      onTap: onTap,
      child: SizedBox(
        width: size,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            switch (heroTag) {
              final tag? => Hero(
                tag: tag,
                transitionOnUserGestures: true,
                child: Artwork(url: cover, size: size, radius: CauceMetrics.artworkRadius),
              ),
              null => Artwork(url: cover, size: size, radius: CauceMetrics.artworkRadius),
            },
            const SizedBox(height: 8),
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500, height: 1.25),
            ),
            if (subtitle.isNotEmpty)
              Text(
                subtitle,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 13.5, height: 1.3, color: CauceColors.mutedForeground),
              ),
          ],
        ),
      ),
    );
  }
}

/// An artist: a round picture over the name, centred.
class ArtistCircle extends StatelessWidget {
  const ArtistCircle({super.key, required this.cover, required this.name, required this.onTap, this.size = 96});

  final String? cover;
  final String name;
  final VoidCallback onTap;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Pressable(
      onTap: onTap,
      child: SizedBox(
        width: size,
        child: Column(
          children: [
            Artwork(url: cover, size: size, radius: size / 2),
            const SizedBox(height: 10),
            Text(
              name,
              maxLines: 2,
              textAlign: TextAlign.center,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w500, height: 1.25),
            ),
          ],
        ),
      ),
    );
  }
}

/// A horizontal row of cards under a [SectionHeader].
class Shelf extends StatelessWidget {
  const Shelf({super.key, required this.height, required this.children});

  final double height;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: CauceMetrics.gutter),
        itemCount: children.length,
        separatorBuilder: (_, _) => const SizedBox(width: 12),
        itemBuilder: (_, index) => children[index],
      ),
    );
  }
}
