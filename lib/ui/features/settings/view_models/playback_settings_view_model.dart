import 'package:flutter/foundation.dart';

import '../../../../src/rust/api/player.dart' as core;
import '../../../core/cached_image.dart';
import '../../downloads/downloads_view_model.dart';
import '../../player/now_playing_center.dart';

/// The playback preferences as the settings screens edit them. Every change goes to the core at
/// once, which saves it and applies it to the engine.
class PlaybackSettingsViewModel extends ChangeNotifier {
  core.PlaybackSettings? _settings;
  core.StorageUsage? _usage;

  core.PlaybackSettings? get settings => _settings;
  core.StorageUsage? get usage => _usage;

  /// Every equalizer preset, in upstream's order.
  final List<core.EqualizerPreset> presets = core.equalizerPresets();

  /// The cache sizes allowed, in GB.
  final (int, int) cacheRange = core.cacheGbRange();

  Future<void> load() async {
    _settings = await core.playbackSettings();
    _tellPlatform();
    notifyListeners();
    await refreshUsage();
  }

  Future<void> refreshUsage() async {
    _usage = await core.storageUsage();
    notifyListeners();
  }

  /// The preset the bands match, or null for a custom curve.
  core.EqualizerPreset? get preset {
    final bands = _settings?.bands;
    if (bands == null) return null;
    for (final preset in presets) {
      if (listEquals(preset.bands, bands)) return preset;
    }
    return null;
  }

  void update({
    bool? normalisation,
    bool? gapless,
    String? quality,
    String? qualityCellular,
    bool? dataSaver,
    bool? continueSimilar,
    bool? rememberRepeat,
    bool? resumeOnConnect,
    bool? downloadsWifiOnly,
    bool? downloadLikes,
    String? downloadQuality,
    bool? freeSpace,
    bool? resumeLast,
    bool? equalizer,
    List<double>? bands,
    bool? keepTracks,
    int? cacheGb,
  }) {
    final current = _settings;
    if (current == null) return;
    final next = core.PlaybackSettings(
      normalisation: normalisation ?? current.normalisation,
      gapless: gapless ?? current.gapless,
      quality: quality ?? current.quality,
      qualityCellular: qualityCellular ?? current.qualityCellular,
      dataSaver: dataSaver ?? current.dataSaver,
      continueSimilar: continueSimilar ?? current.continueSimilar,
      rememberRepeat: rememberRepeat ?? current.rememberRepeat,
      resumeOnConnect: resumeOnConnect ?? current.resumeOnConnect,
      downloadsWifiOnly: downloadsWifiOnly ?? current.downloadsWifiOnly,
      downloadLikes: downloadLikes ?? current.downloadLikes,
      downloadQuality: downloadQuality ?? current.downloadQuality,
      freeSpace: freeSpace ?? current.freeSpace,
      resumeLast: resumeLast ?? current.resumeLast,
      equalizer: equalizer ?? current.equalizer,
      bands: bands == null ? current.bands : Float64List.fromList(bands),
      keepTracks: keepTracks ?? current.keepTracks,
      cacheGb: cacheGb ?? current.cacheGb,
    );
    _settings = next;
    notifyListeners();
    core.setPlaybackSettings(settings: next).ignore();
    if (resumeOnConnect != null) _tellPlatform();
    if (keepTracks == false) refreshUsage().ignore();
  }

  void _tellPlatform() {
    final settings = _settings;
    if (settings != null) NowPlayingCenter.options(resumeOnConnect: settings.resumeOnConnect).ignore();
  }

  void setBand(int index, double gain) => update(bands: [...?_settings?.bands]..[index] = gain);

  Future<void> clearCache() async {
    await Future.wait([core.clearCache(), CachedNetworkImage.clear()]);
    await refreshUsage();
  }

  Future<void> clearDownloads() async {
    await core.clearDownloads();
    await Future.wait([refreshUsage(), downloads.refresh()]);
  }
}
