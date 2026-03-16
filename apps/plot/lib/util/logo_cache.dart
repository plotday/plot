import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

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
      final response = await http.get(Uri.parse(url));
      if (response.statusCode == 200) {
        return response.bodyBytes;
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
