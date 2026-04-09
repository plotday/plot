import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:plot/api/api.dart' show getHeaders;
import 'package:plot/env.dart';

/// In-memory cache for logo image bytes, keyed by URL.
///
/// Uses `putIfAbsent` on a `Future` map so concurrent requests for the same
/// URL share a single HTTP download. After the first download, subsequent
/// calls return the already-resolved future (synchronous render, no jank).
///
/// On non-web platforms, logos are also persisted to disk so they survive
/// restarts and are available offline.
class LogoCache {
  static final Map<String, Future<Uint8List?>> _cache = {};
  static final Map<String, Uint8List?> _resolved = {};
  static Directory? _diskCacheDir;

  /// Whether [url] has a synchronously available result.
  static bool isCached(String url) => _resolved.containsKey(url);

  /// Returns the resolved bytes for [url], or null if not yet resolved.
  static Uint8List? getSync(String url) => _resolved[url];

  /// Returns cached bytes for [url], starting a download if not yet cached.
  static Future<Uint8List?> get(String url) {
    return _cache.putIfAbsent(url, () async {
      // Try disk cache before network (non-web only).
      if (!kIsWeb) {
        final diskBytes = await _readFromDisk(url);
        if (diskBytes != null) {
          _resolved[url] = diskBytes;
          return diskBytes;
        }
      }

      final data = await _download(url);
      _resolved[url] = data;

      // Fire-and-forget disk write on success.
      if (!kIsWeb && data != null) {
        _writeToDisk(url, data);
      }

      return data;
    });
  }

  static Future<Uint8List?> _download(String url) async {
    try {
      final String fetchUrl;
      final Map<String, String> headers;
      if (kIsWeb) {
        // Proxy through our API to avoid CORS errors on external favicons.
        fetchUrl =
            '${Env.apiRoot}/favicon?url=${Uri.encodeComponent(url)}';
        headers = await getHeaders();
      } else {
        fetchUrl = url;
        headers = {};
      }
      final response =
          await http.get(Uri.parse(fetchUrl), headers: headers);
      if (response.statusCode == 200) {
        final bytes = response.bodyBytes;
        // Flutter web's image decoder doesn't support ICO format. Try to
        // extract an embedded PNG from the ICO; fall back to null if the
        // ICO only contains BMP data. Native platforms handle ICO natively.
        if (kIsWeb && _isIco(bytes)) return _extractPngFromIco(bytes);
        return bytes;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Whether [url] was fetched but returned no data (404, network error, etc.).
  static bool isFailed(String url) =>
      _resolved.containsKey(url) && _resolved[url] == null;

  /// Returns true if [url] looks like an SVG.
  static bool isSvg(String url) =>
      url.endsWith('.svg') || url.contains('.svg?');

  /// ICO files start with a 4-byte header: 00 00 01 00.
  static bool _isIco(Uint8List bytes) =>
      bytes.length >= 4 &&
      bytes[0] == 0x00 &&
      bytes[1] == 0x00 &&
      bytes[2] == 0x01 &&
      bytes[3] == 0x00;

  static const _pngSignature = [0x89, 0x50, 0x4E, 0x47];

  /// Extracts the largest PNG image embedded in an ICO file.
  ///
  /// ICO format: 6-byte header (reserved, type, count) followed by 16-byte
  /// directory entries (width, height, …, size[4], offset[4]). Each entry
  /// points to image data that is either BMP or PNG. We pick the largest PNG.
  /// Returns null if no PNG entry is found (BMP-only ICO).
  static Uint8List? _extractPngFromIco(Uint8List ico) {
    if (ico.length < 6) return null;
    final count = ico[4] | (ico[5] << 8);

    int bestSize = 0;
    int bestOffset = 0;
    int bestLength = 0;

    for (int i = 0; i < count; i++) {
      final dirStart = 6 + i * 16;
      if (dirStart + 16 > ico.length) return null;
      final dataSize = ico[dirStart + 8] |
          (ico[dirStart + 9] << 8) |
          (ico[dirStart + 10] << 16) |
          (ico[dirStart + 11] << 24);
      final dataOffset = ico[dirStart + 12] |
          (ico[dirStart + 13] << 8) |
          (ico[dirStart + 14] << 16) |
          (ico[dirStart + 15] << 24);

      if (dataOffset + dataSize > ico.length) continue;
      if (dataSize < 4) continue;

      // Check for PNG signature at the start of the image data.
      if (ico[dataOffset] == _pngSignature[0] &&
          ico[dataOffset + 1] == _pngSignature[1] &&
          ico[dataOffset + 2] == _pngSignature[2] &&
          ico[dataOffset + 3] == _pngSignature[3]) {
        if (dataSize > bestSize) {
          bestSize = dataSize;
          bestOffset = dataOffset;
          bestLength = dataSize;
        }
      }
    }

    if (bestLength == 0) return null;
    return Uint8List.sublistView(ico, bestOffset, bestOffset + bestLength);
  }

  // ---------------------------------------------------------------------------
  // Disk caching (non-web only)
  // ---------------------------------------------------------------------------

  static String _fileNameForUrl(String url) {
    final hash = sha1.convert(url.codeUnits).toString();
    // Preserve .svg extension so callers can detect format from the filename
    // if needed in the future; all other formats use the bare hash.
    if (isSvg(url)) return '$hash.svg';
    return hash;
  }

  static Future<Directory> _getDiskCacheDir() async {
    if (_diskCacheDir != null) return _diskCacheDir!;
    final cacheDir = await getApplicationCacheDirectory();
    _diskCacheDir = Directory('${cacheDir.path}/logos');
    if (!_diskCacheDir!.existsSync()) {
      await _diskCacheDir!.create(recursive: true);
    }
    return _diskCacheDir!;
  }

  static Future<Uint8List?> _readFromDisk(String url) async {
    try {
      final dir = await _getDiskCacheDir();
      final file = File('${dir.path}/${_fileNameForUrl(url)}');
      if (file.existsSync()) {
        return await file.readAsBytes();
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Writes bytes to disk without awaiting — caller should not block on this.
  static void _writeToDisk(String url, Uint8List bytes) {
    _getDiskCacheDir().then((dir) {
      final file = File('${dir.path}/${_fileNameForUrl(url)}');
      file.writeAsBytes(bytes).ignore();
    }).ignore();
  }
}
