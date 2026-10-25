import 'dart:io';

import 'package:flutter/material.dart';

import 'cached_image.dart';
import 'theme.dart';

/// A track's cover: a url for streamed tracks, a file path for local ones, a note when there is
/// none or it fails to load.
class Artwork extends StatelessWidget {
  const Artwork({super.key, required this.url, required this.size, this.radius = CauceMetrics.radius});

  final String? url;
  final double size;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final placeholder = Container(
      width: size,
      height: size,
      color: CauceColors.muted,
      child: Icon(Icons.music_note_rounded, size: size * 0.4, color: CauceColors.mutedForeground),
    );
    final provider = artworkProvider(url);
    // Decoded at the size drawn, so a list of thumbnails does not hold full-size covers.
    final pixels = (size * MediaQuery.devicePixelRatioOf(context)).round();
    final image = provider == null
        ? placeholder
        : Image(
            image: ResizeImage.resizeIfNeeded(pixels, null, provider),
            width: size,
            height: size,
            fit: BoxFit.cover,
            gaplessPlayback: true,
            frameBuilder: (_, child, frame, synchronous) => synchronous
                ? child
                : AnimatedOpacity(
                    opacity: frame == null ? 0 : 1,
                    duration: const Duration(milliseconds: 180),
                    child: child,
                  ),
            errorBuilder: (_, _, _) => placeholder,
          );
    return ClipRRect(borderRadius: BorderRadius.circular(radius), child: image);
  }
}

/// The cover as a full-bleed image provider, for blurred backdrops. `null` when there is none.
ImageProvider? artworkProvider(String? url) => switch (url) {
  null => null,
  _ when url.startsWith('http') => CachedNetworkImage(url),
  _ => FileImage(File(url)),
};
