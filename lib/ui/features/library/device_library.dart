import 'package:flutter/services.dart';

/// A song in the phone's Music library that has a file behind it.
class DeviceSong {
  DeviceSong.fromMap(Map<Object?, Object?> map)
    : id = map['id']! as String,
      title = map['title'] as String? ?? '',
      artist = map['artist'] as String? ?? '',
      album = map['album'] as String? ?? '',
      duration = Duration(milliseconds: map['durationMs'] as int? ?? 0),
      cover = map['cover'] as String?;

  final String id;
  final String title;
  final String artist;
  final String album;
  final Duration duration;

  /// A local JPEG of the artwork.
  final String? cover;
}

/// The phone's Music library, through the native `cauce/media_library` channel.
class DeviceLibrary {
  static const _channel = MethodChannel('cauce/media_library');

  /// Asks for access the first time; empty when it is refused.
  static Future<List<DeviceSong>> songs() async {
    final songs = await _channel.invokeListMethod<Map<Object?, Object?>>('songs') ?? const [];
    return [for (final song in songs) DeviceSong.fromMap(song)];
  }

  /// A file of the song the engine can read, exported once and kept in the cache.
  static Future<String?> export(String id) => _channel.invokeMethod<String>('export', id);

  /// Exports `songs` from `start` and plays them, starting as soon as the first few are ready.
  /// The next few export after, so the next time they queue too. Empty when the chosen song
  /// itself cannot be exported.
  static Future<List<String>> ready(List<DeviceSong> songs, int start) async {
    final first = await export(songs[start].id);
    if (first == null) return const [];
    final ready = <String>[first];
    // ponytail: the queue holds what is exported when play starts; append to the live queue
    // as exports finish if longer runs matter.
    for (final song in songs.skip(start + 1).take(_ahead - 1)) {
      if (await export(song.id) case final path?) ready.add(path);
    }
    () async {
      for (final song in songs.skip(start + _ahead).take(_warm)) {
        await export(song.id);
      }
    }();
    return ready;
  }

  static const _ahead = 4;
  static const _warm = 30;
}

/// A folder picked in the Files app and the audio files in it.
class PickedFolder {
  PickedFolder.fromMap(Map<Object?, Object?> map)
    : name = map['name']! as String,
      files = [for (final file in map['files']! as List<Object?>) file! as String];

  final String name;
  final List<String> files;
}

/// Folders outside the app, such as On My iPhone › Downloads, picked once and read on each visit.
class PickedFolders {
  static const _channel = MethodChannel('cauce/media_library');

  /// Opens the folder picker; whether one was picked.
  static Future<bool> add() async => await _channel.invokeMethod<bool>('addFolder') ?? false;

  static Future<List<PickedFolder>> list() async {
    final folders = await _channel.invokeListMethod<Map<Object?, Object?>>('folders') ?? const [];
    return [for (final folder in folders) PickedFolder.fromMap(folder)];
  }

  static Future<void> remove(String name) => _channel.invokeMethod<void>('removeFolder', name);
}
