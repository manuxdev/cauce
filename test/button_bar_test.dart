import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:cauce/ui/core/button_bar.dart';

MediaQueryData _bottom(double inset) => MediaQueryData(
  padding: EdgeInsets.only(bottom: inset),
  viewPadding: EdgeInsets.only(bottom: inset),
);

void main() {
  test('Android three-button bar gets a gap above it', () {
    final media = clearButtonBar(_bottom(48), TargetPlatform.android);
    expect(media.padding.bottom, greaterThan(48));
    expect(media.viewPadding.bottom, media.padding.bottom);
  });

  test('a gesture handle, an iPhone and an open keyboard keep their insets', () {
    expect(clearButtonBar(_bottom(24), TargetPlatform.android).padding.bottom, 24);
    expect(clearButtonBar(_bottom(48), TargetPlatform.iOS).padding.bottom, 48);
    final typing = MediaQueryData(viewPadding: const EdgeInsets.only(bottom: 48));
    expect(clearButtonBar(typing, TargetPlatform.android).padding.bottom, 0);
  });
}
