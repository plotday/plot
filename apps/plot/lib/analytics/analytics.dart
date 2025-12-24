/// Central PostHog analytics wrapper
///
/// This file provides a centralized interface for tracking events following
/// the [Category] Object Action naming convention.

library;

import 'package:posthog_flutter/posthog_flutter.dart';

import 'conventions.dart';
import 'properties.dart';

export 'conventions.dart';
export 'properties.dart';

/// Central analytics class wrapping PostHog
class Analytics {
  Analytics._();
  static final Analytics instance = Analytics._();

  /// Track an event with PostHog
  Future<void> track(
    String eventName, [
    Map<String, dynamic>? properties,
  ]) async {
    await Posthog().capture(
      eventName: eventName,
      properties: properties?.cast<String, Object>(),
    );
  }

  /// Build and track an event using the naming convention
  Future<void> trackEvent({
    required EventCategory category,
    required EventObject object,
    required EventAction action,
    Map<String, dynamic>? properties,
  }) async {
    final eventName = buildEventName(category, object, action);
    await track(eventName, properties);
  }

  // Convenience methods for common event types

  /// Track an action event (user-initiated actions)
  Future<void> trackAction(
    EventObject object,
    EventAction action, [
    Map<String, dynamic>? properties,
  ]) async {
    await trackEvent(
      category: EventCategory.action,
      object: object,
      action: action,
      properties: properties,
    );
  }

  /// Track a navigation event (screen/route changes)
  Future<void> trackNavigation(
    String screenName, [
    Map<String, dynamic>? properties,
  ]) async {
    await track(
      '[Navigation] $screenName Viewed',
      properties,
    );
  }

  /// Track an error event
  Future<void> trackError(
    String object, {
    required String errorType,
    required String errorMessage,
    String? stackTrace,
    String? context,
  }) async {
    final objectFormatted = object[0].toUpperCase() + object.substring(1);
    await track(
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
  Future<void> trackPerformance({
    required EventObject object,
    required int durationMs,
    required int thresholdMs,
    String? operationType,
  }) async {
    await trackEvent(
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
  Future<void> trackSession(
    EventAction action, [
    Map<String, dynamic>? properties,
  ]) async {
    await trackEvent(
      category: EventCategory.session,
      object: EventObject.user,
      action: action,
      properties: properties,
    );
  }

  /// Identify a user
  Future<void> identify(
    String userId, {
    Map<String, dynamic>? properties,
  }) async {
    await Posthog().identify(
      userId: userId,
      userProperties: properties?.cast<String, Object>(),
    );
  }

  /// Reset user identity (on sign out)
  Future<void> reset() async {
    await Posthog().flush();
    await Posthog().reset();
  }
}
