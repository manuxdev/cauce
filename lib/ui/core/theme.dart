import 'package:flutter/material.dart';

import 'app_prefs.dart';
import 'tint.dart';

/// The colours of one theme and accent: the neutral plum greys used where no cover tints, the
/// text on them, and the accent.
@immutable
class Palette {
  const Palette._({
    required this.light,
    required this.background,
    required this.settingsBackground,
    required this.group,
    required this.secondary,
    required this.muted,
    required this.raised,
    required this.sheet,
    required this.foreground,
    required this.mutedForeground,
    required this.faintForeground,
    required this.border,
    required this.accent,
    required this.onAccent,
    required this.error,
    required this.warning,
  });

  /// The palette for the light or dark theme with `accent`; the cover accent follows
  /// `coverHue`, magenta while there is none.
  factory Palette.of({required bool light, required AccentChoice accent, double? coverHue}) {
    final picked = _accent(
      light,
      accent == AccentChoice.cover && coverHue == null ? AccentChoice.magenta : accent,
      coverHue,
    );
    // Dark ink on a bright accent, white on a deep one.
    final onAccent = picked.computeLuminance() > 0.3 ? const Color(0xFF220C21) : Colors.white;
    return light
        ? Palette._(
            light: true,
            background: const Color(0xFFF8F4F8),
            settingsBackground: const Color(0xFFF2EDF2),
            group: Colors.white,
            secondary: const Color(0xFFFFFFFF),
            muted: const Color(0xFFEBE5EB),
            raised: const Color(0xFFDED7DE),
            sheet: const Color(0xFFFBF8FB),
            foreground: const Color(0xFF1B1219),
            mutedForeground: const Color(0x991B1219),
            faintForeground: const Color(0x701B1219),
            border: const Color(0x1A1B1219),
            accent: picked,
            onAccent: onAccent,
            error: const Color(0xFFD23F33),
            warning: const Color(0xFFB8740E),
          )
        : Palette._(
            light: false,
            background: const Color(0xFF0E090F),
            settingsBackground: const Color(0xFF0B080C),
            group: const Color(0xFF1C181D),
            secondary: const Color(0xFF1B171C),
            muted: const Color(0xFF251F26),
            raised: const Color(0xFF312C32),
            sheet: const Color(0xFF231D24),
            foreground: const Color(0xFFFFFFFF),
            mutedForeground: const Color(0x8CFFFFFF),
            faintForeground: const Color(0x66FFFFFF),
            border: const Color(0x14FFFFFF),
            accent: picked,
            onAccent: onAccent,
            error: const Color(0xFFFF7A6E),
            warning: const Color(0xFFF3AE58),
          );
  }

  final bool light;

  /// oklch(0.15 0.015 320) dark: a page with no cover behind it.
  final Color background;
  final Color settingsBackground;

  /// The card a settings group sits on.
  final Color group;

  /// Grouped rows, fields and cards over [background].
  final Color secondary;

  /// Chips, soft buttons and skeletons.
  final Color muted;

  /// What is pressed among [muted] things.
  final Color raised;

  /// Bottom sheets and dialogs.
  final Color sheet;
  final Color foreground;
  final Color mutedForeground;
  final Color faintForeground;
  final Color border;

  /// Everything you can press, pick or that is playing.
  final Color accent;

  /// Text and icons on [accent].
  final Color onAccent;
  final Color error;
  final Color warning;

  @override
  bool operator ==(Object other) => other is Palette && other.light == light && other.accent == accent;

  @override
  int get hashCode => Object.hash(light, accent);
}

/// Each accent, deeper in the light theme so it reads on white.
Color _accent(bool light, AccentChoice accent, double? coverHue) => switch (accent) {
  AccentChoice.cover => oklch(light ? 0.56 : 0.72, light ? 0.15 : 0.14, coverHue ?? 330),
  AccentChoice.magenta => light ? const Color(0xFFA9419F) : const Color(0xFFD36FD0),
  AccentChoice.coral => light ? const Color(0xFFC94F33) : const Color(0xFFF0775A),
  AccentChoice.green => light ? const Color(0xFF237F43) : const Color(0xFF4CC26E),
  AccentChoice.blue => light ? const Color(0xFF2468C4) : const Color(0xFF5AA2F7),
  AccentChoice.yellow => light ? const Color(0xFF8A6F00) : const Color(0xFFE9CD3A),
};

/// The palette in use. It changes with the theme and the accent, and [CauceColors.use] makes
/// every widget draw again with the new one.
abstract final class CauceColors {
  static Palette _now = Palette.of(light: false, accent: AccentChoice.magenta);
  static Palette _dark = _now;

  static Palette get now => _now;

  /// The dark palette with the same accent, for the full player, which stays dark in both themes.
  static Palette get dark => _dark;

  /// Switches to `palette`, with `dark` for the player, answering whether anything changed.
  static bool use(Palette palette, Palette dark) {
    if (palette == _now && dark == _dark) return false;
    _now = palette;
    _dark = dark;
    return true;
  }

  static bool get light => _now.light;
  static Color get background => _now.background;
  static Color get settingsBackground => _now.settingsBackground;
  static Color get group => _now.group;
  static Color get secondary => _now.secondary;
  static Color get muted => _now.muted;
  static Color get raised => _now.raised;
  static Color get sheet => _now.sheet;
  static Color get foreground => _now.foreground;
  static Color get mutedForeground => _now.mutedForeground;
  static Color get faintForeground => _now.faintForeground;
  static Color get border => _now.border;
  static Color get accent => _now.accent;
  static Color get onAccent => _now.onAccent;
  static Color get error => _now.error;
  static Color get warning => _now.warning;

  /// Text and icons on a white button, whatever the theme.
  static const onPrimary = Color(0xFF220C21);
}

/// Corner radii and gutters shared by every screen.
abstract final class CauceMetrics {
  static const gutter = 20.0;
  static const radius = 8.0;
  static const artworkRadius = 12.0;
  static const groupRadius = 14.0;
}

/// The display face, for titles and the logo.
const displayFont = 'SpaceGrotesk';

/// Type for titles, in Space Grotesk; everything else is the system face.
abstract final class CauceText {
  static const largeTitle = TextStyle(
    fontFamily: displayFont,
    fontSize: 34,
    height: 1.1,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.7,
  );
  static const section = TextStyle(
    fontFamily: displayFont,
    fontSize: 21,
    height: 1.2,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.3,
  );
  static const headline = TextStyle(
    fontFamily: displayFont,
    fontSize: 26,
    height: 1.15,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.4,
  );

  /// The caps label over a group of settings or a list.
  static TextStyle get overline => TextStyle(
    fontSize: 13,
    height: 1.3,
    fontWeight: FontWeight.w500,
    letterSpacing: 0.6,
    color: CauceColors.mutedForeground,
  );
  static TextStyle get caption => TextStyle(fontSize: 13.5, height: 1.4, color: CauceColors.mutedForeground);
}

/// The app's theme in `palette`, the one in use when unset.
ThemeData cauceTheme([Palette? palette]) {
  final p = palette ?? CauceColors.now;
  final light = p.light;
  final scheme = (light ? ColorScheme.light : ColorScheme.dark)(
    surface: p.background,
    onSurface: p.foreground,
    onSurfaceVariant: p.mutedForeground,
    surfaceContainer: p.secondary,
    surfaceContainerHigh: p.muted,
    primary: p.accent,
    onPrimary: p.onAccent,
    secondary: p.mutedForeground,
    error: p.error,
    outline: p.border,
    outlineVariant: p.border,
  );
  return ThemeData(
    useMaterial3: true,
    brightness: light ? Brightness.light : Brightness.dark,
    colorScheme: scheme,
    // Pages sit over the tint the app paints behind them.
    scaffoldBackgroundColor: Colors.transparent,
    canvasColor: p.background,
    splashFactory: NoSplash.splashFactory,
    highlightColor: p.foreground.withValues(alpha: 0.04),
    textSelectionTheme: TextSelectionThemeData(cursorColor: p.accent),
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
        TargetPlatform.android: CupertinoPageTransitionsBuilder(),
      },
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      scrolledUnderElevation: 0,
      centerTitle: true,
      foregroundColor: p.accent,
      titleTextStyle: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: p.foreground),
    ),
    iconTheme: IconThemeData(color: p.foreground),
    listTileTheme: ListTileThemeData(
      contentPadding: EdgeInsets.symmetric(horizontal: CauceMetrics.gutter),
      subtitleTextStyle: TextStyle(fontSize: 13.5, color: p.mutedForeground),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: const WidgetStatePropertyAll(Colors.white),
      trackColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected) ? p.accent : p.raised,
      ),
      trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
    ),
    sliderTheme: SliderThemeData(
      trackHeight: 4,
      activeTrackColor: p.accent,
      inactiveTrackColor: p.raised,
      thumbColor: Colors.white,
      overlayShape: RoundSliderOverlayShape(overlayRadius: 14),
      thumbShape: RoundSliderThumbShape(enabledThumbRadius: 11, elevation: 2),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: p.accent),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: p.raised,
      contentTextStyle: TextStyle(color: p.foreground, fontSize: 15),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: p.sheet,
      surfaceTintColor: Colors.transparent,
      showDragHandle: false,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(30))),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: p.accent,
        textStyle: const TextStyle(fontSize: 17, fontWeight: FontWeight.w400),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: p.accent,
        foregroundColor: p.onAccent,
        minimumSize: const Size(0, 44),
        padding: const EdgeInsets.symmetric(horizontal: 22),
        shape: const StadiumBorder(),
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: p.secondary,
      hintStyle: TextStyle(color: p.mutedForeground),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
      contentPadding: const EdgeInsets.symmetric(vertical: 12),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: p.muted,
      selectedColor: p.foreground,
      side: BorderSide.none,
      shape: const StadiumBorder(),
      labelStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
      secondaryLabelStyle: const TextStyle(fontWeight: FontWeight.w600, color: CauceColors.onPrimary),
      showCheckmark: false,
    ),
  );
}

/// "3:07" or "1:02:45".
String formatDuration(Duration duration) {
  final hours = duration.inHours;
  final minutes = duration.inMinutes.remainder(60);
  final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
  return hours > 0 ? '$hours:${minutes.toString().padLeft(2, '0')}:$seconds' : '$minutes:$seconds';
}
