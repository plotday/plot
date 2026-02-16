import 'dart:async';
import 'dart:convert';

import 'package:clerk_auth/clerk_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A [Persistor] that stores Clerk auth cache in SharedPreferences.
///
/// Used on web where `dart:io` (File/Directory) is not available.
/// Stores all values as JSON-encoded strings with a key prefix to avoid
/// collisions with other SharedPreferences data.
class SharedPreferencesPersistor implements Persistor {
  static const _prefix = 'clerk_cache_';

  late final SharedPreferences _prefs;
  final _cache = <String, dynamic>{};

  @override
  Future<void> initialize() async {
    _prefs = await SharedPreferences.getInstance();

    // Restore cache from SharedPreferences
    for (final key in _prefs.getKeys()) {
      if (key.startsWith(_prefix)) {
        final cacheKey = key.substring(_prefix.length);
        final raw = _prefs.getString(key);
        if (raw != null) {
          try {
            _cache[cacheKey] = json.decode(raw);
          } on FormatException catch (_) {
            // Corrupted entry — remove and skip
            await _prefs.remove(key);
          }
        }
      }
    }
  }

  @override
  void terminate() {}

  @override
  FutureOr<T?> read<T>(String key) => _cache[key] as T?;

  @override
  FutureOr<void> write<T>(String key, T value) {
    _cache[key] = value;
    _prefs.setString('$_prefix$key', json.encode(value));
  }

  @override
  FutureOr<void> delete(String key) {
    if (_cache.containsKey(key)) {
      _cache.remove(key);
      _prefs.remove('$_prefix$key');
    }
  }
}
