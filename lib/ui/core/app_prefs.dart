import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// The tab the app opens on.
enum StartTab { last, home, search, library }

/// Light, dark, or as the phone is set.
enum ThemeChoice { system, light, dark }

/// How much the playing cover colours the app.
enum CoverColor {
  /// Every page takes the cover's hue.
  immersive(1),

  /// A hint of it.
  subtle(0.4),

  /// Only the full player does.
  neutral(0);

  const CoverColor(this.strength);

  /// How strongly pages take the cover's hue, 0 to 1.
  final double strength;
}

/// The colour of what can be pressed: one of a few, or the playing cover's.
enum AccentChoice { cover, magenta, coral, green, blue, yellow }

/// The home screen icon.
enum AppIconChoice { night, paper, magenta, coral }

/// How tall list rows are.
enum ListDensity { compact, normal, comfortable }

/// The full player's look, which its lyrics follow.
enum PlayerDesign { classic, vinyl, poster, tape, immersive }

/// How the full player draws where the song is; [auto] is the design's own.
enum SeekStyle { auto, line, wave, ripple, capsule, dots, tape, ring }

/// How the transport buttons are drawn; [auto] is the design's own.
enum ButtonLook { auto, circle, outline, key, plain }

/// How the player goes from one song to the next: each design its own way, or a plain fade.
enum TrackChange { design, fade }

/// How far the player's motion goes.
enum MotionIntensity {
  soft(0.6),
  normal(1),
  vivid(1.4);

  const MotionIntensity(this.scale);

  /// What distances, glows and swings are multiplied by.
  final double scale;
}

/// How the app itself behaves, kept across launches: where it opens, touch feedback, holding a
/// row for its options, keeping recent searches, and how providers work together.
class AppPrefs extends ChangeNotifier {
  StartTab startTab = StartTab.last;
  int _lastTab = 0;
  bool haptics = true;
  bool holdForOptions = true;
  bool saveSearches = true;

  /// Search offers «All», every connected provider at once.
  bool searchAll = false;

  /// A track a provider cannot play is looked for in the others.
  bool substitute = true;

  /// The providers by slug, in the order combined results come in.
  List<String> providerOrder = const [];

  ThemeChoice theme = ThemeChoice.system;
  CoverColor coverColor = CoverColor.immersive;
  AccentChoice accent = AccentChoice.magenta;
  AppIconChoice appIcon = AppIconChoice.night;

  /// The full player's colour drifts slowly while it plays.
  bool movingBackground = true;

  PlayerDesign playerDesign = PlayerDesign.classic;
  SeekStyle seekStyle = SeekStyle.auto;

  /// The mini player draws its line in the full player's bar style too.
  bool miniSeekStyle = false;
  ButtonLook buttonLook = ButtonLook.auto;

  /// The vinyl turns while it plays.
  bool spinVinyl = true;

  /// The ripple and the VU meters follow the sound.
  bool reactive = true;
  TrackChange trackChange = TrackChange.design;
  MotionIntensity intensity = MotionIntensity.normal;

  /// Lists that mix providers mark each row with its provider's letters.
  bool providerTag = true;
  ListDensity density = ListDensity.normal;

  /// How large lyrics are drawn, from [minLyricsScale] to [maxLyricsScale].
  double lyricsScale = 1;
  bool lyricsCentered = false;

  /// Lights each word as it is sung, where the source times words.
  bool wordByWord = true;

  /// Moves synced lyrics earlier (negative) or later against the music.
  Duration lyricsOffset = Duration.zero;

  /// The full player opens on the lyrics.
  bool openLyrics = false;

  /// The lyrics source groups in the order tried: `provider`, `server`, `lrclib` and `lrc`.
  List<String> lyricsSources = lyricsSourceGroups;

  /// Downloads keep their lyrics, so they show offline.
  bool saveLyrics = true;
  File? _file;

  /// The tab to open on.
  int get initialTab => switch (startTab) {
    StartTab.last => _lastTab,
    StartTab.home => 0,
    StartTab.search => 1,
    StartTab.library => 2,
  };

  void read(Map<String, Object?> json) {
    startTab = StartTab.values.asNameMap()[json['startTab']] ?? StartTab.last;
    _lastTab = json['lastTab'] as int? ?? 0;
    haptics = json['haptics'] as bool? ?? true;
    holdForOptions = json['holdForOptions'] as bool? ?? true;
    saveSearches = json['saveSearches'] as bool? ?? true;
    searchAll = json['searchAll'] as bool? ?? false;
    substitute = json['substitute'] as bool? ?? true;
    providerOrder = [...?(json['providerOrder'] as List?)?.whereType<String>()];
    theme = ThemeChoice.values.asNameMap()[json['theme']] ?? ThemeChoice.system;
    coverColor = CoverColor.values.asNameMap()[json['coverColor']] ?? CoverColor.immersive;
    accent = AccentChoice.values.asNameMap()[json['accent']] ?? AccentChoice.magenta;
    appIcon = AppIconChoice.values.asNameMap()[json['appIcon']] ?? AppIconChoice.night;
    movingBackground = json['movingBackground'] as bool? ?? true;
    providerTag = json['providerTag'] as bool? ?? true;
    playerDesign = PlayerDesign.values.asNameMap()[json['playerDesign']] ?? PlayerDesign.classic;
    seekStyle = SeekStyle.values.asNameMap()[json['seekStyle']] ?? SeekStyle.auto;
    miniSeekStyle = json['miniSeekStyle'] as bool? ?? false;
    buttonLook = ButtonLook.values.asNameMap()[json['buttonLook']] ?? ButtonLook.auto;
    spinVinyl = json['spinVinyl'] as bool? ?? true;
    reactive = json['reactive'] as bool? ?? true;
    trackChange = TrackChange.values.asNameMap()[json['trackChange']] ?? TrackChange.design;
    intensity = MotionIntensity.values.asNameMap()[json['intensity']] ?? MotionIntensity.normal;
    density = ListDensity.values.asNameMap()[json['density']] ?? ListDensity.normal;
    lyricsScale = ((json['lyricsScale'] as num?)?.toDouble() ?? 1).clamp(minLyricsScale, maxLyricsScale);
    lyricsCentered = json['lyricsCentered'] as bool? ?? false;
    wordByWord = json['wordByWord'] as bool? ?? true;
    lyricsOffset = Duration(milliseconds: json['lyricsOffsetMs'] as int? ?? 0);
    openLyrics = json['openLyrics'] as bool? ?? false;
    // Known groups as saved, with any the saved list lacks put back at their default place.
    final saved = [...?(json['lyricsSources'] as List?)?.whereType<String>().where(lyricsSourceGroups.contains)];
    for (final (index, group) in lyricsSourceGroups.indexed) {
      if (!saved.contains(group)) saved.insert(index.clamp(0, saved.length), group);
    }
    lyricsSources = saved;
    saveLyrics = json['saveLyrics'] as bool? ?? true;
  }

  Map<String, Object?> toJson() => {
    'startTab': startTab.name,
    'lastTab': _lastTab,
    'haptics': haptics,
    'holdForOptions': holdForOptions,
    'saveSearches': saveSearches,
    'searchAll': searchAll,
    'substitute': substitute,
    'providerOrder': providerOrder,
    'theme': theme.name,
    'coverColor': coverColor.name,
    'accent': accent.name,
    'appIcon': appIcon.name,
    'movingBackground': movingBackground,
    'providerTag': providerTag,
    'playerDesign': playerDesign.name,
    'seekStyle': seekStyle.name,
    'miniSeekStyle': miniSeekStyle,
    'buttonLook': buttonLook.name,
    'spinVinyl': spinVinyl,
    'reactive': reactive,
    'trackChange': trackChange.name,
    'intensity': intensity.name,
    'density': density.name,
    'lyricsScale': lyricsScale,
    'lyricsCentered': lyricsCentered,
    'wordByWord': wordByWord,
    'lyricsOffsetMs': lyricsOffset.inMilliseconds,
    'openLyrics': openLyrics,
    'lyricsSources': lyricsSources,
    'saveLyrics': saveLyrics,
  };

  /// Puts the player's design, bar, buttons and motion back as they come.
  void resetPlayerDesign() {
    playerDesign = PlayerDesign.classic;
    seekStyle = SeekStyle.auto;
    miniSeekStyle = false;
    buttonLook = ButtonLook.auto;
    spinVinyl = true;
    movingBackground = true;
    reactive = true;
    trackChange = TrackChange.design;
    intensity = MotionIntensity.normal;
  }

  Future<void> load() async {
    final file = File('${(await getApplicationSupportDirectory()).path}/app.json');
    _file = file;
    try {
      read(jsonDecode(await file.readAsString()) as Map<String, Object?>);
    } on Object {
      // Nothing saved yet, or unreadable: the defaults stand.
    }
    notifyListeners();
  }

  /// Applies `change` and keeps the result.
  void update(void Function(AppPrefs prefs) change) {
    change(this);
    notifyListeners();
    _file?.writeAsString(jsonEncode(toJson())).ignore();
  }

  /// Remembers the tab in use, for opening on it next time.
  void usedTab(int tab) {
    if (tab == _lastTab) return;
    _lastTab = tab;
    _file?.writeAsString(jsonEncode(toJson())).ignore();
  }
}

final appPrefs = AppPrefs();

const minLyricsScale = 0.8;
const maxLyricsScale = 1.3;
const lyricsSourceGroups = ['provider', 'server', 'lrclib', 'lrc'];

/// A light tick, as a selection makes, when touch feedback is on.
void tick() {
  if (appPrefs.haptics) HapticFeedback.selectionClick();
}

/// A firmer tap, as a like makes, when touch feedback is on.
void thud() {
  if (appPrefs.haptics) HapticFeedback.mediumImpact();
}
