import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// In-memory cache for logo image bytes, keyed by URL.
///
/// Uses `putIfAbsent` on a `Future` map so concurrent requests for the same
/// URL share a single HTTP download. After the first download, subsequent
/// calls return the already-resolved future (synchronous render, no jank).
class LogoCache {
  static final Map<String, Future<Uint8List?>> _cache = {};
  static final Map<String, Uint8List?> _resolved = {};

  /// Whether [url] has a synchronously available result.
  static bool isCached(String url) => _resolved.containsKey(url);

  /// Returns the resolved bytes for [url], or null if not yet resolved.
  static Uint8List? getSync(String url) => _resolved[url];

  /// Returns cached bytes for [url], starting a download if not yet cached.
  static Future<Uint8List?> get(String url) {
    return _cache.putIfAbsent(url, () async {
      final data = await _download(url);
      _resolved[url] = data;
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

  /// Returns true if [url] looks like an SVG.
  static bool isSvg(String url) =>
      url.endsWith('.svg') || url.contains('.svg?');
}
