import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:path_provider/path_provider.dart';

/// Where downloaded images are kept, set once at launch by [CachedNetworkImage.prepare].
Directory? _folder;
final _http = HttpClient()..connectionTimeout = const Duration(seconds: 10);

/// A network image kept on disk after its first download, so covers come back at once on later
/// launches instead of being fetched again.
// ponytail: no eviction; the folder goes with "Clear cache" in the settings, or with iOS
// clearing the app's caches when space runs low.
@immutable
class CachedNetworkImage extends ImageProvider<CachedNetworkImage> {
  const CachedNetworkImage(this.url);

  final String url;

  /// Makes the folder ready and gives the in-memory cache room for a library's worth of covers.
  static Future<void> prepare() async {
    final folder = Directory('${(await getApplicationCacheDirectory()).path}/images');
    await folder.create(recursive: true);
    _folder = folder;
    PaintingBinding.instance.imageCache
      ..maximumSize = 2000
      ..maximumSizeBytes = 256 << 20;
  }

  /// Removes every kept image.
  static Future<void> clear() async {
    final folder = _folder;
    if (folder == null || !await folder.exists()) return;
    await folder.delete(recursive: true);
    await folder.create();
  }

  @override
  Future<CachedNetworkImage> obtainKey(ImageConfiguration configuration) => SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(CachedNetworkImage key, ImageDecoderCallback decode) =>
      MultiFrameImageStreamCompleter(codec: _load(decode), scale: 1, debugLabel: url);

  Future<ui.Codec> _load(ImageDecoderCallback decode) async {
    final file = _folder == null ? null : File('${_folder!.path}/${_name(url)}');
    Uint8List? bytes;
    if (file != null && await file.exists()) {
      bytes = await file.readAsBytes();
    }
    if (bytes == null || bytes.isEmpty) {
      bytes = await _download();
      if (file != null) unawaited(_keep(file, bytes));
    }
    return decode(await ui.ImmutableBuffer.fromUint8List(bytes));
  }

  Future<Uint8List> _download() async {
    final request = await _http.getUrl(Uri.parse(url));
    final response = await request.close();
    if (response.statusCode != HttpStatus.ok) {
      throw HttpException('the image answered ${response.statusCode}', uri: Uri.parse(url));
    }
    return consolidateHttpClientResponseBytes(response);
  }

  /// Writes beside the file and moves it in place, so a crash never leaves half an image.
  static Future<void> _keep(File file, Uint8List bytes) async {
    try {
      final partial = File('${file.path}.part');
      await partial.writeAsBytes(bytes, flush: true);
      await partial.rename(file.path);
    } on FileSystemException {
      // A full disk only means the image is fetched again next time.
    }
  }

  /// A 64-bit FNV-1a of the url, which is short, stable across launches and safe as a file name.
  static String _name(String url) {
    var hash = 0xcbf29ce484222325;
    for (final unit in url.codeUnits) {
      hash = ((hash ^ unit) * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
    }
    return hash.toUnsigned(64).toRadixString(16);
  }

  @override
  bool operator ==(Object other) => other is CachedNetworkImage && other.url == url;

  @override
  int get hashCode => url.hashCode;
}
