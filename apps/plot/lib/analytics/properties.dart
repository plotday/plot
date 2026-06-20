/// Standard property builders for PostHog events
///
/// This file contains helper functions to build consistent event properties
/// across the application.

library;

/// Standard property keys
class PropertyKey {
  // Action properties
  static const String actionType = 'action_type';
  static const String success = 'success';
  static const String durationMs = 'duration_ms';
  static const String triggeredBy = 'triggered_by';
  static const String shortcutUsed = 'shortcut_used';

  // Error properties
  static const String errorType = 'error_type';
  static const String errorMessage = 'error_message';
  static const String stackTrace = 'stack_trace';

  // Navigation properties
  static const String screenName = 'screen_name';
  static const String routeParams = 'route_params';
  static const String previousScreen = 'previous_screen';
  static const String navigationType = 'navigation_type';
  static const String timeOnPreviousScreenMs = 'time_on_previous_screen_ms';
  static const String layoutMode = 'layout_mode';

  // Activity properties
  static const String activityType = 'activity_type';
  static const String hasStartTime = 'has_start_time';
  static const String tagCount = 'tag_count';
  static const String tagName = 'tag_name';
  static const String priorityId = 'priority_id';
  static const String source = 'source';

  // Priority properties
  static const String depthLevel = 'depth_level';
  static const String hasParent = 'has_parent';
  static const String childCount = 'child_count';
  static const String twistCount = 'twist_count';

  // Filter properties
  static const String filterType = 'filter_type';
  static const String filterValue = 'filter_value';
  static const String activeFilterCount = 'active_filter_count';

  // Session properties
  static const String sessionDurationMs = 'session_duration_ms';
  static const String firstSession = 'first_session';
  static const String daysSinceSignup = 'days_since_signup';

  // Performance properties
  static const String thresholdMs = 'threshold_ms';

  // Bloc properties
  static const String blocType = 'bloc_type';
}

/// Values for triggered_by property
class TriggerSource {
  static const String keyboard = 'keyboard';
  static const String mouse = 'mouse';
  static const String programmatic = 'programmatic';
}

/// Values for navigation_type property
class NavigationType {
  static const String push = 'push';
  static const String replace = 'replace';
  static const String pop = 'pop';
}

/// Values for layout_mode property
class LayoutMode {
  static const String singlePanel = 'single_panel';
  static const String multiPanel = 'multi_panel';
}

/// Values for source property (activity creation)
class ActivitySource {
  static const String userCreated = 'user_created';
  static const String synced = 'synced';
  static const String twist = 'twist';
}

/// Build action execution properties.
///
/// [extra] carries command-specific properties (e.g. `is_todo`,
/// `attachment_count`, `connector`) contributed by a [Command]'s
/// `eventProperties` getter. They are merged after the standard keys so a
/// command can describe *what kind* of action it was without firing a separate
/// event.
Map<String, dynamic> buildActionProperties({
  required String actionType,
  required bool success,
  required int durationMs,
  String? triggeredBy,
  String? shortcutUsed,
  String? errorType,
  String? errorMessage,
  Map<String, Object?>? extra,
}) {
  final properties = <String, dynamic>{
    PropertyKey.actionType: actionType,
    PropertyKey.success: success,
    PropertyKey.durationMs: durationMs,
  };

  if (triggeredBy != null) {
    properties[PropertyKey.triggeredBy] = triggeredBy;
  }

  if (shortcutUsed != null) {
    properties[PropertyKey.shortcutUsed] = shortcutUsed;
  }

  if (errorType != null) {
    properties[PropertyKey.errorType] = errorType;
  }

  if (errorMessage != null) {
    properties[PropertyKey.errorMessage] = errorMessage;
  }

  if (extra != null) {
    for (final entry in extra.entries) {
      // Only attach non-null extras; a null means "not applicable" and would
      // just add noise to the event.
      if (entry.value != null) properties[entry.key] = entry.value;
    }
  }

  return properties;
}

/// Build navigation properties
Map<String, dynamic> buildNavigationProperties({
  required String screenName,
  String? routeParams,
  String? previousScreen,
  String? navigationType,
  int? timeOnPreviousScreenMs,
  String? layoutMode,
}) {
  final properties = <String, dynamic>{
    PropertyKey.screenName: screenName,
  };

  if (routeParams != null) {
    properties[PropertyKey.routeParams] = routeParams;
  }

  if (previousScreen != null) {
    properties[PropertyKey.previousScreen] = previousScreen;
  }

  if (navigationType != null) {
    properties[PropertyKey.navigationType] = navigationType;
  }

  if (timeOnPreviousScreenMs != null) {
    properties[PropertyKey.timeOnPreviousScreenMs] = timeOnPreviousScreenMs;
  }

  if (layoutMode != null) {
    properties[PropertyKey.layoutMode] = layoutMode;
  }

  return properties;
}

/// Build error properties
Map<String, dynamic> buildErrorProperties({
  required String errorType,
  required String errorMessage,
  String? stackTrace,
  String? context,
}) {
  final properties = <String, dynamic>{
    PropertyKey.errorType: errorType,
    PropertyKey.errorMessage: errorMessage,
  };

  if (stackTrace != null) {
    properties[PropertyKey.stackTrace] = stackTrace;
  }

  if (context != null) {
    properties['context'] = context;
  }

  return properties;
}

/// Build activity properties
Map<String, dynamic> buildActivityProperties({
  String? activityType,
  bool? hasStartTime,
  int? tagCount,
  String? tagName,
  String? priorityId,
  String? source,
}) {
  final properties = <String, dynamic>{};

  if (activityType != null) {
    properties[PropertyKey.activityType] = activityType;
  }

  if (hasStartTime != null) {
    properties[PropertyKey.hasStartTime] = hasStartTime;
  }

  if (tagCount != null) {
    properties[PropertyKey.tagCount] = tagCount;
  }

  if (tagName != null) {
    properties[PropertyKey.tagName] = tagName;
  }

  if (priorityId != null) {
    properties[PropertyKey.priorityId] = priorityId;
  }

  if (source != null) {
    properties[PropertyKey.source] = source;
  }

  return properties;
}

/// Build priority properties
Map<String, dynamic> buildPriorityProperties({
  int? depthLevel,
  bool? hasParent,
  int? childCount,
  int? twistCount,
}) {
  final properties = <String, dynamic>{};

  if (depthLevel != null) {
    properties[PropertyKey.depthLevel] = depthLevel;
  }

  if (hasParent != null) {
    properties[PropertyKey.hasParent] = hasParent;
  }

  if (childCount != null) {
    properties[PropertyKey.childCount] = childCount;
  }

  if (twistCount != null) {
    properties[PropertyKey.twistCount] = twistCount;
  }

  return properties;
}

/// Build performance properties
Map<String, dynamic> buildPerformanceProperties({
  required int durationMs,
  required int thresholdMs,
  String? operationType,
}) {
  final properties = <String, dynamic>{
    PropertyKey.durationMs: durationMs,
    PropertyKey.thresholdMs: thresholdMs,
  };

  if (operationType != null) {
    properties['operation_type'] = operationType;
  }

  return properties;
}

/// Extract first N lines of stack trace for reporting
String extractStackTrace(StackTrace stackTrace, {int lines = 3}) {
  final stackString = stackTrace.toString();
  final stackLines = stackString.split('\n');
  final limitedLines = stackLines.take(lines).toList();
  return limitedLines.join('\n');
}
