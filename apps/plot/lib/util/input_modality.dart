import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';

/// Tracks whether the most recent *activating* user input was a key press or a
/// pointer (mouse/touch) press.
///
/// Modals consult [lastInputWasKeyboard] when they open to decide whether to
/// pre-arm a default control: a modal opened from the keyboard focuses its
/// primary action (so Enter activates it), while one opened by mouse/touch
/// shows no initial highlight — matching SelectModal's behaviour.
///
/// Only *down* events count. Mouse movement (hover) and key/pointer *up* events
/// are ignored, so idle cursor drift between a keyboard shortcut firing and the
/// modal actually appearing doesn't flip the recorded modality.
class InputModality {
  InputModality._();

  static bool _lastWasKeyboard = false;
  static bool _installed = false;

  /// Whether the most recent activating input (key-down vs pointer-down) came
  /// from the keyboard. Defaults to `false` (pointer) before any input.
  static bool get lastInputWasKeyboard => _lastWasKeyboard;

  /// Installs the global listeners. Idempotent — safe to call more than once.
  /// Must run after the Flutter bindings are initialised.
  static void ensureInstalled() {
    if (_installed) return;
    _installed = true;
    HardwareKeyboard.instance.addHandler(_handleKey);
    GestureBinding.instance.pointerRouter.addGlobalRoute(_handlePointer);
  }

  static bool _handleKey(KeyEvent event) {
    if (event is KeyDownEvent) _lastWasKeyboard = true;
    return false; // Observation only — never consume the event.
  }

  static void _handlePointer(PointerEvent event) {
    if (event is PointerDownEvent) _lastWasKeyboard = false;
  }

  /// Test seam: force the recorded modality. Production code never calls this.
  @visibleForTesting
  static void debugSetLastInputWasKeyboard(bool value) {
    _lastWasKeyboard = value;
  }
}
