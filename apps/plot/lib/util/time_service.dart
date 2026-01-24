import 'package:logging/logging.dart';
import 'package:plot/cli_args.dart';

/// Service that provides current time, with support for freezing time via
/// command-line argument or runtime control for testing and screenshots.
///
/// Usage:
/// - Normal: Time.now() returns DateTime.now()
/// - Frozen via CLI: Pass --frozen-time=2024-12-25T14:30:00 to freeze time
/// - Frozen at runtime: Call Time.setFrozenTime(DateTime) to freeze time
class Time {
  Time._();

  static final Logger _log = Logger('Time');
  static DateTime? _frozenTime;
  static void Function()? _onTimeChanged;

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

  /// Sets or clears frozen time at runtime.
  ///
  /// When frozen time is set, [now()] will return this value instead of
  /// the current DateTime. When set to null, time returns to normal flow.
  ///
  /// Triggers [_onTimeChanged] callback if registered, allowing Clock service
  /// and other listeners to be notified of the change.
  static void setFrozenTime(DateTime? dateTime) {
    final previous = _frozenTime;
    _frozenTime = dateTime;

    if (dateTime != null) {
      _log.info('Time frozen to: $dateTime (was: ${previous ?? 'live'})');
    } else {
      _log.info('Time unfrozen (was frozen to: $previous)');
    }

    _onTimeChanged?.call();
  }

  /// Convenience method to unfreeze time.
  ///
  /// Equivalent to calling setFrozenTime(null).
  static void unfreeze() => setFrozenTime(null);

  /// Registers a callback to be notified when frozen time changes.
  ///
  /// Used by Clock service to trigger stream updates when time is frozen/unfrozen.
  static void setOnTimeChanged(void Function()? callback) {
    _onTimeChanged = callback;
  }

  /// Returns the current DateTime, or frozen time if set.
  static DateTime now() => _frozenTime ?? DateTime.now();

  /// Returns true if time is frozen.
  static bool isFrozen() => _frozenTime != null;
}
