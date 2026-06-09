/// Central PostHog analytics wrapper
///
/// This file provides a centralized interface for tracking events following
/// the [Category] Object Action naming convention.
///
/// Supports multiple platforms:
/// - iOS/Android/macOS: Uses posthog_flutter SDK
/// - Web/Windows: Uses PostHog HTTP API directly. On web, posthog_flutter is
///   only a thin wrapper over a `window.posthog` global that we don't load
///   (no posthog-js snippet in web/index.html), so SDK capture calls silently
///   no-op — the HTTP backend POSTs to the configured host instead.

library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' show HttpException, Platform, SocketException;
import 'dart:ui' show PlatformDispatcher;
import 'package:flutter/foundation.dart'
    show kDebugMode, kIsWeb, kProfileMode;
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:posthog_flutter/posthog_flutter.dart';

import '../api/api_exception.dart';
import '../api/network_exception.dart';
import '../app_info.dart';
import '../env.dart';
import 'conventions.dart';
import 'properties.dart';

export 'conventions.dart';
export 'properties.dart';

final _log = Logger('Tracker');

/// Abstract backend interface for analytics
abstract class AnalyticsBackend {
  Future<void> capture(String eventName, Map<String, dynamic>? properties);
  Future<void> identify(
    String userId,
    Map<String, dynamic>? properties,
    Map<String, dynamic>? propertiesSetOnce,
  );
  Future<void> reset();
  Future<void> flush();
  Future<void> captureException({
    required Object error,
    StackTrace? stackTrace,
    Map<String, dynamic>? properties,
  });
}

/// PostHog SDK backend for iOS, Android, macOS
class PostHogSdkBackend implements AnalyticsBackend {
  @override
  Future<void> capture(
    String eventName,
    Map<String, dynamic>? properties,
  ) async {
    await Posthog().capture(
      eventName: eventName,
      properties: properties?.cast<String, Object>(),
    );
  }

  @override
  Future<void> identify(
    String userId,
    Map<String, dynamic>? properties,
    Map<String, dynamic>? propertiesSetOnce,
  ) async {
    await Posthog().identify(
      userId: userId,
      userProperties: properties?.cast<String, Object>(),
      userPropertiesSetOnce: propertiesSetOnce?.cast<String, Object>(),
    );
  }

  @override
  Future<void> reset() async {
    await Posthog().flush();
    await Posthog().reset();
  }

  @override
  Future<void> flush() async {
    await Posthog().flush();
  }

  @override
  Future<void> captureException({
    required Object error,
    StackTrace? stackTrace,
    Map<String, dynamic>? properties,
  }) async {
    await Posthog().captureException(
      error: error,
      stackTrace: stackTrace,
      properties: properties?.cast<String, Object>(),
    );
  }
}

/// PostHog HTTP API backend for web and Windows
class PostHogApiBackend implements AnalyticsBackend {
  final String _apiKey;
  final String _host;
  final http.Client _client = http.Client();

  String? _distinctId;
  final List<Map<String, dynamic>> _eventQueue = [];
  Timer? _batchTimer;

  static const int _batchSize = 10;
  static const Duration _batchInterval = Duration(seconds: 5);

  PostHogApiBackend(this._apiKey, this._host) {
    // Start batch timer
    _batchTimer = Timer.periodic(_batchInterval, (_) => _sendBatch());
  }

  @override
  Future<void> capture(
    String eventName,
    Map<String, dynamic>? properties,
  ) async {
    final event = {
      'distinct_id': _distinctId ?? 'anonymous',
      'event': eventName,
      'properties': ?properties,
      'timestamp': DateTime.now().toUtc().toIso8601String(),
    };

    _eventQueue.add(event);

    // Send immediately if queue is full
    if (_eventQueue.length >= _batchSize) {
      await _sendBatch();
    }
  }

  @override
  Future<void> identify(
    String userId,
    Map<String, dynamic>? properties,
    Map<String, dynamic>? propertiesSetOnce,
  ) async {
    _distinctId = userId;

    // Send $identify event
    final identifyEvent = {
      'distinct_id': userId,
      'event': '\$identify',
      'properties': {
        '\$set': ?properties,
        '\$set_once': ?propertiesSetOnce,
      },
      'timestamp': DateTime.now().toUtc().toIso8601String(),
    };

    _eventQueue.add(identifyEvent);
    await _sendBatch(); // Send immediately for identify
  }

  @override
  Future<void> reset() async {
    await flush();
    _distinctId = null;
  }

  @override
  Future<void> flush() async {
    await _sendBatch();
  }

  @override
  Future<void> captureException({
    required Object error,
    StackTrace? stackTrace,
    Map<String, dynamic>? properties,
  }) async {
    await capture('\$exception', {
      ...?properties,
      'error': error.toString(),
      if (stackTrace != null) 'stack_trace': stackTrace.toString(),
    });
  }

  Future<void> _sendBatch() async {
    if (_eventQueue.isEmpty) return;

    // Take all events from queue
    final eventsToSend = List<Map<String, dynamic>>.from(_eventQueue);
    _eventQueue.clear();

    try {
      final response = await _client.post(
        Uri.parse('$_host/batch'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'api_key': _apiKey, 'batch': eventsToSend}),
      );

      if (response.statusCode != 200) {
        _log.warning(
          'PostHog API error: ${response.statusCode} ${response.body}',
        );
      }
    } catch (error) {
      _log.warning('Failed to send PostHog events', error);
      // Drop events when offline (as per requirements)
    }
  }

  void dispose() {
    _batchTimer?.cancel();
    _client.close();
  }
}

/// Central analytics tracker with static API
class Tracker {
  Tracker._();
  static final Tracker _instance = Tracker._();

  late final AnalyticsBackend _backend;
  bool _initialized = false;

  /// Properties merged into every event and onto the person profile on
  /// identify. Built once from [AppInfo] at init time. Uses PostHog's
  /// `$app_*` standard names where they apply so the UI surfaces them.
  late final Map<String, dynamic> _superProperties;

  /// Initialize analytics with the appropriate backend for the platform
  static Future<void> init() async {
    await _instance._init();
  }

  Future<void> _init() async {
    if (_initialized) return;

    _superProperties = _buildSuperProperties();

    // Select backend based on platform. `kIsWeb` is checked first so the
    // `dart:io` `Platform.isWindows` access (which throws on web) is never
    // reached in a browser.
    if (kIsWeb || Platform.isWindows) {
      _log.info(
        'Initializing PostHog HTTP API backend '
        '(${kIsWeb ? 'web' : 'Windows'})',
      );
      _backend = PostHogApiBackend(Env.posthogApiKey, Env.posthogHost);
    } else {
      _log.info('Initializing PostHog SDK backend (native)');
      _backend = PostHogSdkBackend();

      // Configure and setup PostHog SDK
      final config = PostHogConfig(Env.posthogApiKey)
        ..host = Env.posthogHost
        ..captureApplicationLifecycleEvents = true
        ..personProfiles = PostHogPersonProfiles.identifiedOnly;
      await Posthog().setup(config);

      // Also register on the SDK so its auto-captured lifecycle events
      // pick up platform/version (those bypass our _track wrapper).
      for (final entry in _superProperties.entries) {
        final value = entry.value;
        if (value != null) await Posthog().register(entry.key, value as Object);
      }
    }

    // Setup error tracking
    _setupErrorTracking();

    _initialized = true;
  }

  Map<String, dynamic> _buildSuperProperties() {
    final clientKind = kIsWeb ? 'web' : 'native';
    String buildMode;
    if (kDebugMode) {
      buildMode = 'debug';
    } else if (kProfileMode) {
      buildMode = 'profile';
    } else {
      buildMode = 'release';
    }
    return <String, dynamic>{
      // PostHog standard property names — surfaced by the UI.
      '\$app_version': AppInfo.version,
      '\$app_build': AppInfo.buildNumber,
      '\$app_name': 'Plot',
      // Our own readable names.
      'platform': AppInfo.platform, // macOS / Windows / Linux / iOS / Android / Web
      'client_kind': clientKind, // web | native
      'build_mode': buildMode, // debug | profile | release
    };
  }

  Map<String, dynamic> _mergeSuperProperties(
    Map<String, dynamic>? properties,
  ) {
    if (properties == null || properties.isEmpty) {
      return Map<String, dynamic>.from(_superProperties);
    }
    // Caller-provided properties win on key conflicts.
    return {..._superProperties, ...properties};
  }

  void _setupErrorTracking() {
    // Catch uncaught Flutter errors
    FlutterError.onError = (FlutterErrorDetails details) async {
      if (!_shouldIgnore(details.exception, details.stack)) {
        _log.severe('Uncaught Flutter error', details.exception, details.stack);
        await _backend.captureException(
          error: details.exception,
          stackTrace: details.stack,
          properties: _superProperties,
        );
      }
      FlutterError.presentError(details);
    };

    // Catch async errors that occur outside of the Flutter framework
    PlatformDispatcher
        .instance
        .onError = (Object error, StackTrace stackTrace) {
      if (!_shouldIgnore(error, stackTrace)) {
        _log.severe('Uncaught async error', error, stackTrace);
        _backend.captureException(
          error: error,
          stackTrace: stackTrace,
          properties: _superProperties,
        );
      }
      return true; // Marks the error as handled
    };
  }

  /// Filter out expected/handled errors that shouldn't be reported to PostHog.
  bool _shouldIgnore(Object error, StackTrace? stackTrace) {
    // Ignore harmless forui FTappable error: findRenderObject() called on a
    // defunct element when a button is removed while the pointer is still
    // down (e.g. tapping a button that closes a modal).
    if (error is FlutterError &&
        error.message.contains('renderObject of inactive element') &&
        stackTrace != null &&
        stackTrace.toString().contains('tappable.dart')) {
      return true;
    }

    // Ignore DNS lookup failures when polling for Clerk session tokens.
    // These occur when the device is offline and are already caught and
    // handled internally by the clerk_auth library.
    if (error.toString().contains("Failed host lookup: 'clerk.plot.day'")) {
      return true;
    }

    // Ignore network errors (timeouts, connection failures, socket errors).
    // These are expected during offline periods and are already handled
    // by the sync orchestrator. HttpException and SocketException also
    // surface from NetworkImage loads when a remote host drops the
    // connection mid-request — not a bug. http.ClientException covers
    // package:http failures like "Connection closed before full header
    // was received" surfaced by clerk_auth after its retries exhaust.
    if (error is NetworkException ||
        error is HttpException ||
        error is SocketException ||
        error is http.ClientException) {
      return true;
    }

    // Ignore auth failures — the user will be signed out via
    // _checkAuthError, so these are expected not bugs.
    if (error is ApiException && error.statusCode == 401) {
      return true;
    }

    return false;
  }

  /// Track an event with PostHog
  static Future<void> track(
    String eventName, [
    Map<String, dynamic>? properties,
  ]) async {
    await _instance._track(eventName, properties);
  }

  Future<void> _track(
    String eventName,
    Map<String, dynamic>? properties,
  ) async {
    await _backend.capture(eventName, _mergeSuperProperties(properties));
  }

  /// Build and track an event using the naming convention
  static Future<void> trackEvent({
    required EventCategory category,
    required EventObject object,
    required EventAction action,
    Map<String, dynamic>? properties,
  }) async {
    await _instance._trackEvent(
      category: category,
      object: object,
      action: action,
      properties: properties,
    );
  }

  Future<void> _trackEvent({
    required EventCategory category,
    required EventObject object,
    required EventAction action,
    Map<String, dynamic>? properties,
  }) async {
    final eventName = buildEventName(category, object, action);
    await _track(eventName, properties);
  }

  // Convenience methods for common event types

  /// Track an action event (user-initiated actions)
  static Future<void> trackAction(
    EventObject object,
    EventAction action, [
    Map<String, dynamic>? properties,
  ]) async {
    await _instance._trackAction(object, action, properties);
  }

  Future<void> _trackAction(
    EventObject object,
    EventAction action,
    Map<String, dynamic>? properties,
  ) async {
    await _trackEvent(
      category: EventCategory.action,
      object: object,
      action: action,
      properties: properties,
    );
  }

  /// Track a navigation event (screen/route changes)
  static Future<void> trackNavigation(
    String screenName, [
    Map<String, dynamic>? properties,
  ]) async {
    await _instance._trackNavigation(screenName, properties);
  }

  Future<void> _trackNavigation(
    String screenName,
    Map<String, dynamic>? properties,
  ) async {
    await _track('[Navigation] $screenName Viewed', properties);
  }

  /// Track an error event
  static Future<void> trackError(
    String object, {
    required String errorType,
    required String errorMessage,
    String? stackTrace,
    String? context,
  }) async {
    await _instance._trackError(
      object,
      errorType: errorType,
      errorMessage: errorMessage,
      stackTrace: stackTrace,
      context: context,
    );
  }

  Future<void> _trackError(
    String object, {
    required String errorType,
    required String errorMessage,
    String? stackTrace,
    String? context,
  }) async {
    final objectFormatted = object[0].toUpperCase() + object.substring(1);
    await _track(
      '[Error] $objectFormatted Failed',
      buildErrorProperties(
        errorType: errorType,
        errorMessage: errorMessage,
        stackTrace: stackTrace,
        context: context,
      ),
    );
  }

  /// Track a performance event (slow operations)
  static Future<void> trackPerformance({
    required EventObject object,
    required int durationMs,
    required int thresholdMs,
    String? operationType,
  }) async {
    await _instance._trackPerformance(
      object: object,
      durationMs: durationMs,
      thresholdMs: thresholdMs,
      operationType: operationType,
    );
  }

  Future<void> _trackPerformance({
    required EventObject object,
    required int durationMs,
    required int thresholdMs,
    String? operationType,
  }) async {
    await _trackEvent(
      category: EventCategory.performance,
      object: object,
      action: EventAction.timedOut,
      properties: buildPerformanceProperties(
        durationMs: durationMs,
        thresholdMs: thresholdMs,
        operationType: operationType,
      ),
    );
  }

  /// Track a session event
  static Future<void> trackSession(
    EventAction action, [
    Map<String, dynamic>? properties,
  ]) async {
    await _instance._trackSession(action, properties);
  }

  Future<void> _trackSession(
    EventAction action,
    Map<String, dynamic>? properties,
  ) async {
    await _trackEvent(
      category: EventCategory.session,
      object: EventObject.user,
      action: action,
      properties: properties,
    );
  }

  /// Identify a user
  static Future<void> identify(
    String userId, {
    Map<String, dynamic>? properties,
    Map<String, dynamic>? propertiesSetOnce,
  }) async {
    await _instance._identify(
      userId,
      properties: properties,
      propertiesSetOnce: propertiesSetOnce,
    );
  }

  Future<void> _identify(
    String userId, {
    Map<String, dynamic>? properties,
    Map<String, dynamic>? propertiesSetOnce,
  }) async {
    // Stamp last-known platform/version on the person profile too, so we can
    // see what an inactive user was last running without hunting for events.
    await _backend.identify(
      userId,
      _mergeSuperProperties(properties),
      propertiesSetOnce,
    );
  }

  /// Reset user identity (on sign out)
  static Future<void> reset() async {
    await _instance._reset();
  }

  Future<void> _reset() async {
    await _backend.reset();
  }

  /// Capture an exception
  static Future<void> captureException(
    Object error,
    StackTrace? stackTrace,
  ) async {
    await _instance._captureException(error, stackTrace);
  }

  Future<void> _captureException(Object error, StackTrace? stackTrace) async {
    await _backend.captureException(
      error: error,
      stackTrace: stackTrace,
      properties: _superProperties,
    );
  }
}
