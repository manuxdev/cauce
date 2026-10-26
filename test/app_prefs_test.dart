import 'package:flutter_test/flutter_test.dart';
import 'package:cauce/ui/core/app_prefs.dart';

void main() {
  test('nothing saved reads as the defaults', () {
    final prefs = AppPrefs()..read({});
    expect(prefs.haptics, isTrue);
    expect(prefs.holdForOptions, isTrue);
    expect(prefs.saveSearches, isTrue);
    expect(prefs.startTab, StartTab.last);
    expect(prefs.initialTab, 0);
    expect(prefs.searchAll, isFalse);
    expect(prefs.substitute, isTrue);
    expect(prefs.providerOrder, isEmpty);
    expect(prefs.theme, ThemeChoice.system);
    expect(prefs.coverColor, CoverColor.immersive);
    expect(prefs.accent, AccentChoice.magenta);
    expect(prefs.appIcon, AppIconChoice.night);
    expect(prefs.movingBackground, isTrue);
    expect(prefs.providerTag, isTrue);
    expect(prefs.density, ListDensity.normal);
  });

  test('appearance reads back the same, and an unknown name falls back to the default', () {
    final prefs = AppPrefs()
      ..read({
        'theme': 'light',
        'coverColor': 'subtle',
        'accent': 'cover',
        'appIcon': 'paper',
        'movingBackground': false,
        'providerTag': false,
        'density': 'compact',
      });
    final again = AppPrefs()..read(prefs.toJson());
    expect(again.theme, ThemeChoice.light);
    expect(again.coverColor, CoverColor.subtle);
    expect(again.accent, AccentChoice.cover);
    expect(again.appIcon, AppIconChoice.paper);
    expect(again.movingBackground, isFalse);
    expect(again.providerTag, isFalse);
    expect(again.density, ListDensity.compact);
    expect((AppPrefs()..read({'theme': 'sepia'})).theme, ThemeChoice.system);
  });

  test('lyrics read back the same, and a source list missing some keeps them, in default order', () {
    final defaults = AppPrefs()..read({});
    expect(defaults.lyricsScale, 1);
    expect(defaults.lyricsCentered, isFalse);
    expect(defaults.wordByWord, isTrue);
    expect(defaults.lyricsOffset, Duration.zero);
    expect(defaults.openLyrics, isFalse);
    expect(defaults.lyricsSources, ['provider', 'lrclib', 'lrc']);
    expect(defaults.saveLyrics, isTrue);

    final prefs = AppPrefs()
      ..read({
        'lyricsScale': 1.2,
        'lyricsCentered': true,
        'wordByWord': false,
        'lyricsOffsetMs': -500,
        'openLyrics': true,
        'lyricsSources': ['lrc', 'unknown'],
        'saveLyrics': false,
      });
    final again = AppPrefs()..read(prefs.toJson());
    expect(again.lyricsScale, 1.2);
    expect(again.lyricsCentered, isTrue);
    expect(again.wordByWord, isFalse);
    expect(again.lyricsOffset, const Duration(milliseconds: -500));
    expect(again.openLyrics, isTrue);
    expect(again.lyricsSources, ['lrc', 'provider', 'lrclib']);
    expect(again.saveLyrics, isFalse);
    expect((AppPrefs()..read({'lyricsScale': 9.0})).lyricsScale, 1.3);
  });

  test('the cover colour sets how strongly pages take the cover hue', () {
    expect(CoverColor.immersive.strength, 1);
    expect(CoverColor.subtle.strength, inExclusiveRange(0, 1));
    expect(CoverColor.neutral.strength, 0);
  });

  test('the start tab is the last one used unless one is picked', () {
    final prefs = AppPrefs()..read({'lastTab': 2});
    expect(prefs.initialTab, 2);
    prefs.read({'lastTab': 2, 'startTab': 'search'});
    expect(prefs.initialTab, 1);
  });

  test('what is written reads back the same', () {
    final prefs = AppPrefs()
      ..read({
        'haptics': false,
        'startTab': 'library',
        'lastTab': 3,
        'searchAll': true,
        'substitute': false,
        'providerOrder': ['subsonic', 'local'],
      });
    final again = AppPrefs()..read(prefs.toJson());
    expect(again.searchAll, isTrue);
    expect(again.substitute, isFalse);
    expect(again.providerOrder, ['subsonic', 'local']);
    expect(again.haptics, isFalse);
    expect(again.startTab, StartTab.library);
    expect(again.initialTab, 2);
  });

  test('the player design reads back the same, and a reset puts back the defaults', () {
    final defaults = AppPrefs()..read({});
    expect(defaults.playerDesign, PlayerDesign.classic);
    expect(defaults.seekStyle, SeekStyle.auto);
    expect(defaults.buttonLook, ButtonLook.auto);
    expect(defaults.spinVinyl, isTrue);
    expect(defaults.reactive, isTrue);
    expect(defaults.trackChange, TrackChange.design);
    expect(defaults.intensity, MotionIntensity.normal);

    final prefs = AppPrefs()
      ..read({
        'playerDesign': 'tape',
        'seekStyle': 'dots',
        'buttonLook': 'key',
        'spinVinyl': false,
        'reactive': false,
        'trackChange': 'fade',
        'intensity': 'vivid',
        'movingBackground': false,
      });
    final again = AppPrefs()..read(prefs.toJson());
    expect(again.playerDesign, PlayerDesign.tape);
    expect(again.seekStyle, SeekStyle.dots);
    expect(again.buttonLook, ButtonLook.key);
    expect(again.spinVinyl, isFalse);
    expect(again.reactive, isFalse);
    expect(again.trackChange, TrackChange.fade);
    expect(again.intensity, MotionIntensity.vivid);
    expect((AppPrefs()..read({'seekStyle': 'zigzag'})).seekStyle, SeekStyle.auto);

    again.resetPlayerDesign();
    expect(again.playerDesign, PlayerDesign.classic);
    expect(again.seekStyle, SeekStyle.auto);
    expect(again.buttonLook, ButtonLook.auto);
    expect(again.spinVinyl, isTrue);
    expect(again.reactive, isTrue);
    expect(again.trackChange, TrackChange.design);
    expect(again.intensity, MotionIntensity.normal);
    expect(again.movingBackground, isTrue);
  });
}
