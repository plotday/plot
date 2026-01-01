import 'package:logging/logging.dart';
import 'package:plot/cli_args.dart';

/// Service that provides current time, with support for freezing time via
/// command-line argument for testing and screenshots.
///
/// Usage:
/// - Normal: Time.now() returns DateTime.now()
/// - Frozen: Pass --frozen-time=2024-12-25T14:30:00 to freeze time
class Time {
  Time._();

  static final Logger _log = Logger('Time');
  static DateTime? _frozenTime;

  /// Initializes the Time service.
  ///
  /// Uses frozen time from CLI arguments if provided.
  static void init() {
    if (_frozenTime != null) {
      _log.warning('Time already initialized');
      return;
    }

    // Get frozen time from centralized CLI argument parser
    _frozenTime = CliArgs.frozenTime;
    if (_frozenTime != null) {
      _log.info('Time frozen to: $_frozenTime');
    }
  }

  /// Returns the current DateTime, or frozen time if set.
  static DateTime now() => _frozenTime ?? DateTime.now();

  /// Returns true if time is frozen.
  static bool isFrozen() => _frozenTime != null;
}
