import 'package:shared_preferences/shared_preferences.dart';
import 'package:plot/cli_args.dart';

/// Wrapper around SharedPreferences that automatically prefixes keys with profile name.
/// This enables running multiple isolated app instances simultaneously.
class ProfilePreferences {
  ProfilePreferences._(this._prefs, this._prefix);

  final SharedPreferences _prefs;
  final String _prefix;

  static ProfilePreferences? _instance;

  /// Initialize the ProfilePreferences singleton.
  /// Must be called early in app startup, after CliArgs.init().
  static Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    final profile = CliArgs.profile;
    final prefix = profile != null ? 'profile:$profile:' : '';
    _instance = ProfilePreferences._(prefs, prefix);
  }

  static ProfilePreferences get instance {
    if (_instance == null) {
      throw StateError(
        'ProfilePreferences not initialized. Call ProfilePreferences.init() first.',
      );
    }
    return _instance!;
  }

  String _key(String key) => '$_prefix$key';

  // Delegate all SharedPreferences methods with key prefixing
  Future<bool> setBool(String key, bool value) =>
      _prefs.setBool(_key(key), value);
  bool? getBool(String key) => _prefs.getBool(_key(key));

  Future<bool> setDouble(String key, double value) =>
      _prefs.setDouble(_key(key), value);
  double? getDouble(String key) => _prefs.getDouble(_key(key));

  Future<bool> setInt(String key, int value) =>
      _prefs.setInt(_key(key), value);
  int? getInt(String key) => _prefs.getInt(_key(key));

  Future<bool> setString(String key, String value) =>
      _prefs.setString(_key(key), value);
  String? getString(String key) => _prefs.getString(_key(key));

  Future<bool> setStringList(String key, List<String> value) =>
      _prefs.setStringList(_key(key), value);
  List<String>? getStringList(String key) => _prefs.getStringList(_key(key));

  Future<bool> remove(String key) => _prefs.remove(_key(key));
  bool containsKey(String key) => _prefs.containsKey(_key(key));
}
