import 'package:flutter/widgets.dart';

/// Taller than any gesture handle: past this, Android's bottom inset is the three-button bar.
const _buttonBar = 32.0;

/// The room kept between the app's bottom edge and the buttons.
const _gap = 10.0;

/// [media] with its bottom inset raised over Android's button bar, so the dock, toasts, sheets
/// and the player's controls sit clear of the buttons rather than flush against them. A gesture
/// handle, an iPhone and an open keyboard (which leaves no bottom padding) keep theirs.
MediaQueryData clearButtonBar(MediaQueryData media, TargetPlatform platform) {
  if (platform != TargetPlatform.android || media.viewPadding.bottom <= _buttonBar) return media;
  EdgeInsets lift(EdgeInsets insets) => insets.bottom > 0 ? insets.copyWith(bottom: insets.bottom + _gap) : insets;
  return media.copyWith(padding: lift(media.padding), viewPadding: lift(media.viewPadding));
}
