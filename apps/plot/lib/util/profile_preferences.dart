import 'package:shared_preferences/shared_preferences.dart';

/// Wrapper around SharedPreferences for profile-aware preferences.
///
/// Profile isolation is handled globally via [SharedPreferences.setPrefix]
/// in main.dart, so this class delegates directly without key prefixing.
class ProfilePreferences {
  ProfilePreferences._(this._prefs);

  final SharedPreferences _prefs;

  static ProfilePreferences? _instance;

  /// Initialize the ProfilePreferences singleton.
  /// Must be called early in app startup, after CliArgs.init() and
  /// SharedPreferences.setPrefix().
  static Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _instance = ProfilePreferences._(prefs);
  }

  static ProfilePreferences get instance {
    if (_instance == null) {
      throw StateError(
        'ProfilePreferences not initialized. Call ProfilePreferences.init() first.',
      );
    }
    return _instance!;
  }

  // Delegate all SharedPreferences methods
  Future<bool> setBool(String key, bool value) => _prefs.setBool(key, value);
  bool? getBool(String key) => _prefs.getBool(key);

  Future<bool> setDouble(String key, double value) =>
      _prefs.setDouble(key, value);
  double? getDouble(String key) => _prefs.getDouble(key);

  Future<bool> setInt(String key, int value) => _prefs.setInt(key, value);
  int? getInt(String key) => _prefs.getInt(key);

  Future<bool> setString(String key, String value) =>
      _prefs.setString(key, value);
  String? getString(String key) => _prefs.getString(key);

  Future<bool> setStringList(String key, List<String> value) =>
      _prefs.setStringList(key, value);
  List<String>? getStringList(String key) => _prefs.getStringList(key);

  Future<bool> remove(String key) => _prefs.remove(key);
  bool containsKey(String key) => _prefs.containsKey(key);

  /// All stored keys (without the global profile prefix, which
  /// [SharedPreferences.setPrefix] strips transparently).
  Set<String> getKeys() => _prefs.getKeys();

  /// Remove every stored key matching [test]. Used to clear prefix-keyed
  /// preferences (e.g. per-role / per-priority entries) whose exact names
  /// aren't known ahead of time.
  Future<void> removeWhere(bool Function(String key) test) async {
    for (final key in _prefs.getKeys().where(test).toList()) {
      await _prefs.remove(key);
    }
  }
}
