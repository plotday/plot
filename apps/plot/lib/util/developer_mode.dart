import 'package:flutter/foundation.dart';

/// In-memory singleton for developer mode toggle.
/// Resets on app restart — no persistence.
class DeveloperMode {
  DeveloperMode._();

  static bool _enabled = false;
  static final List<DateTime> _tapTimes = [];
  static const _tapWindow = Duration(seconds: 2);
  static const _tapsRequired = 3;

  /// Listen to this to rebuild when developer mode is toggled.
  static final notifier = ChangeNotifier();

  static bool get isEnabled => _enabled;

  /// Record a tap on the version item.
  /// Returns true if developer mode was just toggled (3rd tap in window).
  static bool recordTap() {
    final now = DateTime.now();
    _tapTimes.removeWhere((t) => now.difference(t) > _tapWindow);
    _tapTimes.add(now);
    if (_tapTimes.length >= _tapsRequired) {
      _tapTimes.clear();
      _enabled = !_enabled;
      // ignore: invalid_use_of_visible_for_testing_member, invalid_use_of_protected_member
      notifier.notifyListeners();
      return true;
    }
    return false;
  }
}
