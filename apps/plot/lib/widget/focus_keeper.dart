import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;
import 'package:flutter/widgets.dart';
import 'package:window_manager/window_manager.dart';

/// Restores keyboard focus into the app when the desktop window regains focus.
///
/// Flutter dispatches key events *up the focus chain* starting from
/// [FocusManager.primaryFocus]. [Shortcuts]/[CallbackShortcuts] are built on
/// [Focus] nodes, so a binding only fires when the focused node is a
/// descendant of it. macOS parks `primaryFocus` on the [FocusManager] root
/// scope on spurious inactive/hidden lifecycle transitions — most
/// reproducibly when the user Cmd+Tabs away and back. Once focus sits on the
/// root scope the chain no longer includes any of the app's shortcut widgets,
/// so *every* global shortcut (Cmd+K, Cmd+/, …) silently stops firing. The app
/// also has no editable focus owner, so typing — including the "Start a
/// thread" composer — goes nowhere.
///
/// [FocusKeeper] remembers the last node that genuinely held focus and, when
/// the window regains focus while nobody owns it, re-requests that node. This
/// rebuilds the focus chain (so shortcuts fire again) and restores the caret.
/// It only ever claims focus while the app is ownerless, so it never steals
/// focus from a control the user deliberately activated.
///
/// This is the window-refocus counterpart to `AutofocusReclaim`, which only
/// recovers focus on widget mount.
class FocusKeeper with WindowListener {
  FocusKeeper._();

  /// The app-wide instance, started once from the desktop window.
  static final FocusKeeper instance = FocusKeeper._();

  /// Builds an unstarted instance for tests — does not touch
  /// [windowManager] or register a global [FocusManager] listener.
  @visibleForTesting
  FocusKeeper.forTest();

  static bool get _isDesktop =>
      !kIsWeb && (Platform.isMacOS || Platform.isWindows || Platform.isLinux);

  /// The last node that genuinely held focus (a focusable leaf, never a scope).
  FocusNode? _lastFocused;

  bool _started = false;

  @visibleForTesting
  FocusNode? get lastFocused => _lastFocused;

  /// Begin tracking focus and listening for desktop window-focus events.
  /// No-op off desktop, where this failure mode doesn't occur and
  /// [windowManager] isn't available.
  void start() {
    if (_started || !_isDesktop) return;
    _started = true;
    FocusManager.instance.addListener(recordFocus);
    windowManager.addListener(this);
  }

  /// Records the current primary focus when it is a genuine focusable leaf.
  /// Scope nodes — including the root scope macOS parks on during a window
  /// blur — are ignored, so the real target survives the blur and remains the
  /// node we restore to.
  @visibleForTesting
  void recordFocus() {
    final primary = FocusManager.instance.primaryFocus;
    if (primary != null && primary is! FocusScopeNode) {
      _lastFocused = primary;
    }
  }

  @override
  void onWindowFocus() => restoreFocus();

  /// If the app currently has no focus owner, re-request the last node that
  /// genuinely held focus — rebuilding the focus chain so global shortcuts
  /// fire again and the caret returns.
  ///
  /// Retries across a few frames because macOS can park focus on the root
  /// scope a frame or two *after* the window-focus event arrives (the same
  /// race `AutofocusReclaim` guards against). Each frame it only claims while
  /// the app is ownerless, so it never yanks focus from a control the user
  /// just activated; it stops once the target is focused.
  @visibleForTesting
  void restoreFocus({int attempt = 0, int maxAttempts = 5}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final node = _lastFocused;
      // Nothing to restore, or it's already back — done.
      if (node == null || node.hasFocus) return;

      // Only claim focus when nobody else owns it: the root scope (or any
      // scope macOS parked focus on) or no primary focus at all. A real
      // focusable leaf owning focus means the user moved on — never steal it.
      final primary = FocusManager.instance.primaryFocus;
      final ownerless = primary == null || primary is FocusScopeNode;
      if (ownerless && node.context != null && node.canRequestFocus) {
        node.requestFocus();
      }

      // Keep retrying across a few frames in case the focus park lands late.
      // A post-frame callback alone doesn't request a frame, so pump one.
      if (attempt + 1 < maxAttempts) {
        restoreFocus(attempt: attempt + 1, maxAttempts: maxAttempts);
        WidgetsBinding.instance.scheduleFrame();
      }
    });
    WidgetsBinding.instance.scheduleFrame();
  }

  /// Tears down listeners. Used by tests; the app-wide instance lives for the
  /// process lifetime.
  @visibleForTesting
  void stop() {
    if (!_started) return;
    FocusManager.instance.removeListener(recordFocus);
    if (_isDesktop) windowManager.removeListener(this);
    _started = false;
    _lastFocused = null;
  }
}
