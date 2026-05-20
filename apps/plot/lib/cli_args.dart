import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';

/// Centralized service for parsing and accessing command-line arguments.
///
/// Supported arguments:
/// - --user=EMAIL: Sign in as specified user
/// - --password=PASSWORD: Auto sign-in with password (requires --user)
/// - --url=URL: Navigate to URL after sign-in
/// - --dark-mode: Force dark theme
/// - --light-mode: Force light theme
/// - --frozen-time=ISO8601: Freeze time for testing
/// - --profile=NAME: Run in isolated profile with separate database and preferences
/// - --no-profile: Force the unsuffixed (release) database in a debug build,
///   overriding the default `dev` profile assignment. Use to attach a debug
///   build to the same data the released app uses.
/// - --enable-driver-extension: Register the flutter_driver VM service
///   extension so agents can drive the app via dart-mcp's flutter_driver
///   tool. Debug builds only — the call is a no-op in release.
class CliArgs {
  CliArgs._();

  static final Logger _log = Logger('CliArgs');
  static bool _initialized = false;

  static String? _user;
  static String? _password;
  static String? _url;
  static bool _darkMode = false;
  static bool _lightMode = false;
  static DateTime? _frozenTime;
  static String? _profile;
  static bool _noProfile = false;
  static bool _enableDriverExtension = false;

  /// Initializes the CLI argument parser.
  ///
  /// Must be called once at app startup before accessing any arguments.
  static void init(List<String> args) {
    if (_initialized) {
      _log.warning('CliArgs already initialized');
      return;
    }

    for (final arg in args) {
      if (arg.startsWith('--user=')) {
        _user = arg.substring('--user='.length);
        _log.info('User argument: $_user');
      } else if (arg.startsWith('--password=')) {
        _password = arg.substring('--password='.length);
        _log.info('Password argument provided');
      } else if (arg.startsWith('--url=')) {
        _url = arg.substring('--url='.length);
        _log.info('URL argument: $_url');
      } else if (arg == '--dark-mode') {
        _darkMode = true;
        _log.info('Dark mode forced');
      } else if (arg == '--light-mode') {
        _lightMode = true;
        _log.info('Light mode forced');
      } else if (arg.startsWith('--frozen-time=')) {
        final timeStr = arg.substring('--frozen-time='.length);
        try {
          _frozenTime = DateTime.parse(timeStr);
          _log.info('Frozen time: $_frozenTime');
        } catch (e) {
          _log.warning(
            'Invalid --frozen-time format: "$timeStr". '
            'Expected ISO8601 format (e.g., 2024-12-25T14:30:00). '
            'Error: $e',
          );
        }
      } else if (arg.startsWith('--profile=')) {
        _profile = arg.substring('--profile='.length);
        // Validate profile name (alphanumeric, dash, underscore only)
        if (!RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(_profile!)) {
          _log.warning(
            'Invalid profile name: "$_profile". '
            'Must contain only letters, numbers, dashes, and underscores.',
          );
          _profile = null;
        } else {
          _log.info('Profile: $_profile');
        }
      } else if (arg == '--no-profile') {
        _noProfile = true;
        _log.info('--no-profile: using unsuffixed (release) database');
      } else if (arg == '--enable-driver-extension') {
        _enableDriverExtension = true;
        _log.info('--enable-driver-extension: flutter_driver extension enabled');
      }
    }

    // Validate conflicting arguments
    if (_darkMode && _lightMode) {
      _log.warning(
        'Both --dark-mode and --light-mode specified. Using --dark-mode.',
      );
      _lightMode = false;
    }

    if (_password != null && _user == null) {
      _log.warning('--password specified without --user. Password will be ignored.');
    }

    // Automatically use "dev" profile for debug builds if no profile specified.
    // --no-profile opts out so a debug build can attach to the release DB.
    if (_profile == null && kDebugMode && !_noProfile) {
      _profile = 'dev';
      _log.info('Debug build detected: Using default profile "dev"');
    }

    _initialized = true;
  }

  /// Returns the user email if --user argument was provided.
  static String? get user => _user;

  /// Returns the password if --password argument was provided.
  static String? get password => _password;

  /// Returns the URL if --url argument was provided.
  static String? get url => _url;

  /// Returns true if --dark-mode was specified.
  static bool get darkMode => _darkMode;

  /// Returns true if --light-mode was specified.
  static bool get lightMode => _lightMode;

  /// Returns the frozen time if --frozen-time argument was provided.
  static DateTime? get frozenTime => _frozenTime;

  /// Returns the profile name if --profile argument was provided.
  static String? get profile => _profile;

  /// Returns true if theme mode was overridden via CLI.
  static bool get hasThemeOverride => _darkMode || _lightMode;

  /// Returns true if --enable-driver-extension was specified.
  static bool get enableDriverExtension => _enableDriverExtension;
}
