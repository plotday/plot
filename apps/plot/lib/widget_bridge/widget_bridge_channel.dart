import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'package:plot/analytics/tracker.dart';

import 'widget_data.dart';

/// Method-channel name shared with every native widget host
/// (iOS/macOS WidgetKit plugin, Android plugin, Windows plugin).
const String widgetBridgeChannelName = 'day.plot/widgets';

/// Inbound action name reserved for the future quick-create-note
/// flow. Native code may send this today; Flutter just logs.
const String widgetActionCreateNote = 'createNote';

/// Inbound action name reserved for opening a specific priority
/// from a widget tap. Native code may send this today; Flutter just
/// logs.
const String widgetActionOpenPriority = 'openPriority';

/// Timer controls sent from the menubar / tray surface. Each maps to
/// a single `NowBloc` method in `WidgetBridge._handleAction`; the
/// behaviour is intentionally identical to the in-app commands in
/// `lib/command/timer.dart` so the two surfaces stay in lockstep.
const String widgetActionStartTimer = 'startTimer';
const String widgetActionPauseTimer = 'pauseTimer';
const String widgetActionStopTimer = 'stopTimer';
const String widgetActionAddTime = 'addTime';
const String widgetActionRemoveTime = 'removeTime';

/// Signature for handlers attached via [WidgetBridgeChannel.onAction].
typedef WidgetActionHandler =
    Future<Object?> Function(String name, Map<String, Object?> args);

/// Wraps the [MethodChannel] used to talk to platform-specific
/// widget plugins. The Flutter side calls [writeState] to push the
/// latest [WidgetState] into shared platform storage and [reloadAll]
/// to ask the host to refresh any rendered widgets.
///
/// Inbound actions from native (`onWidgetAction`) are routed to a
/// single handler set via [setHandler]. Today the handler is a stub
/// that just logs; once we have real designs the command layer will
/// register a real handler.
class WidgetBridgeChannel {
  WidgetBridgeChannel._();

  static final WidgetBridgeChannel instance = WidgetBridgeChannel._();

  final MethodChannel _channel = const MethodChannel(widgetBridgeChannelName);

  bool _attached = false;
  WidgetActionHandler? _handler;

  /// Whether the current platform is one we ship a widget host for.
  /// Web and Linux are silent no-ops.
  static bool get isSupportedPlatform {
    if (kIsWeb) return false;
    return defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.windows;
  }

  /// Attach the inbound handler. Safe to call multiple times — only
  /// the first call wires up the [MethodChannel] listener.
  void attach() {
    if (_attached || !isSupportedPlatform) return;
    _attached = true;
    _channel.setMethodCallHandler(_onMethodCall);
  }

  /// Replace the inbound handler. Pass null to restore the default
  /// (logging) handler.
  void setHandler(WidgetActionHandler? handler) {
    _handler = handler;
  }

  /// Push the latest state into platform shared storage. Encodes as
  /// JSON to keep the native side trivially decodable across all
  /// four hosts.
  Future<void> writeState(WidgetState state) async {
    if (!isSupportedPlatform) return;
    try {
      await _channel.invokeMethod<void>('writeState', <String, Object?>{
        'json': jsonEncode(state.toJson()),
      });
    } on MissingPluginException {
      // Plugin is intentionally absent on platforms where the host
      // hasn't been wired up yet — silently no-op.
    } catch (error, stackTrace) {
      await Tracker.captureException(error, stackTrace);
    }
  }

  /// Ask the platform host to reload its widget timelines / repaint
  /// the tray icon. Called after [writeState] so widgets pick up the
  /// new payload on their next refresh.
  Future<void> reloadAll() async {
    if (!isSupportedPlatform) return;
    try {
      await _channel.invokeMethod<void>('reloadAll');
    } on MissingPluginException {
      // See [writeState].
    } catch (error, stackTrace) {
      await Tracker.captureException(error, stackTrace);
    }
  }

  Future<Object?> _onMethodCall(MethodCall call) async {
    if (call.method != 'onWidgetAction') return null;
    final raw = call.arguments;
    if (raw is! Map) return null;
    final name = raw['name'];
    if (name is! String) return null;
    final args = <String, Object?>{};
    final rawArgs = raw['args'];
    if (rawArgs is Map) {
      for (final entry in rawArgs.entries) {
        final key = entry.key;
        if (key is String) args[key] = entry.value;
      }
    }
    final handler = _handler;
    if (handler == null) {
      debugPrint('[widget-bridge] action="$name" (no handler attached)');
      return null;
    }
    try {
      return await handler(name, args);
    } catch (error, stackTrace) {
      await Tracker.captureException(error, stackTrace);
      return null;
    }
  }
}
