import 'package:logging/logging.dart';

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
  /// Parses command-line arguments for --frozen-time=ISO8601 format.
  /// Example: --frozen-time=2024-12-25T14:30:00
  static void init(List<String> args) {
    if (_frozenTime != null) {
      _log.warning('Time already initialized');
      return;
    }

    // Parse --frozen-time argument
    for (final arg in args) {
      if (arg.startsWith('--frozen-time=')) {
        final timeStr = arg.substring('--frozen-time='.length);
        try {
          _frozenTime = DateTime.parse(timeStr);
          _log.info('Time frozen to: $_frozenTime');
        } catch (e) {
          _log.warning(
            'Invalid --frozen-time format: "$timeStr". '
            'Expected ISO8601 format (e.g., 2024-12-25T14:30:00). '
            'Error: $e',
          );
        }
        break;
      }
    }
  }

  /// Returns the current DateTime, or frozen time if set.
  static DateTime now() => _frozenTime ?? DateTime.now();

  /// Returns true if time is frozen.
  static bool isFrozen() => _frozenTime != null;
}
