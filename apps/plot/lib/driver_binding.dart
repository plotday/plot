// ignore_for_file: depend_on_referenced_packages, invalid_use_of_visible_for_testing_member
// flutter_driver is declared in pubspec.yaml under `dependencies`, but pub
// classifies SDK packages as `direct overridden` in pubspec.lock, which trips
// the `depend_on_referenced_packages` lint.
// `FlutterDriverExtension` and its `call` method are `@visibleForTesting`,
// but our whole reason for being here is to register them outside the stock
// `enableFlutterDriverExtension()` path so we can disable frame sync.

import 'package:flutter/widgets.dart';
import 'package:flutter_driver/driver_extension.dart' show FlutterDriverExtension;
import 'package:flutter_test/flutter_test.dart' show TestDefaultBinaryMessengerBinding;

/// A debug-only WidgetsBinding subclass that registers the flutter_driver
/// VM service extension AND immediately disables flutter_driver's "frame
/// sync" behavior.
///
/// We can't use the stock `enableFlutterDriverExtension()` because Plot has
/// continuous transient animations (super_editor cursor blink, etc.). With
/// frame sync on (the default), every finder-based command waits for
/// `SchedulerBinding.transientCallbackCount == 0` before AND after running
/// the finder, and that condition is essentially never true while animations
/// are active — every command times out (`TimeoutException: Future not
/// completed` from `FlutterDriverExtension.call`).
///
/// `FlutterDriver.runUnsynchronized` / the `set_frame_sync` driver command
/// are the standard fix on the test side, but the dart-mcp `flutter_driver`
/// tool only exposes a fixed enum of commands — `set_frame_sync` is not in
/// it. So we register the extension ourselves and dispatch a synchronous
/// `set_frame_sync=false` against it right after registration, before any
/// external agent connects.
class DriverBinding extends WidgetsFlutterBinding
    with TestDefaultBinaryMessengerBinding {
  static bool _initialized = false;

  /// Initialize the binding. Must be called before
  /// `WidgetsFlutterBinding.ensureInitialized()` — otherwise the standard
  /// binding gets installed first and our subclass never runs.
  static WidgetsBinding ensureInitialized() {
    if (!_initialized) {
      _initialized = true;
      DriverBinding();
    }
    return WidgetsBinding.instance;
  }

  @override
  void initServiceExtensions() {
    super.initServiceExtensions();
    final extension = FlutterDriverExtension(
      null, // dataHandler
      false, // silenceErrors
      true, // enableTextEntryEmulation
    );
    registerServiceExtension(name: 'driver', callback: extension.call);
    // Disable frame sync once the root widget is attached. The set_frame_sync
    // command has `requiresRootWidgetAttached = true`, so it would fail an
    // assertion if dispatched directly from initServiceExtensions (which runs
    // before runApp). Defer to the first post-frame callback — by then runApp
    // has mounted the root widget. The `call` method is async but the
    // set_frame_sync handler just assigns a field, so we fire and forget.
    addPostFrameCallback((_) {
      extension.call(<String, String>{
        'command': 'set_frame_sync',
        'enabled': 'false',
      });
    });
  }
}
