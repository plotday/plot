/// Pure decision logic for the notification opt-in prompt flow.
///
/// Kept free of platform/Firebase imports so it is trivially unit-testable.
/// [NotificationService] supplies the I/O (OS permission status, persistence)
/// and calls into these functions.
library;

/// Per-device, per-user opt-in state. Persisted as a string via
/// `ProfilePreferences` (profile-scoped → per device).
enum NotificationPromptState {
  /// Never resolved (fresh install / first run after this ships).
  unset,

  /// User enabled and the OS grant succeeded at least once.
  optedIn,

  /// User tapped "Not now" or denied the OS dialog. Auto-prompts stop.
  declined,
}

/// What the UI should do for the current (OS-permission, stored-state) pair.
enum NotificationPromptAction { none, showPriming, showReEnable }

/// Result of mapping an OS permission-request to a user-facing outcome.
enum NotificationPromptOutcome { granted, declined, openSettings }

/// Local prefs key for [NotificationPromptState], namespaced per user.
String notificationPromptStateKey(String userId) =>
    'notif_prompt_state:$userId';

/// Parse a stored state string. Null/unknown → [NotificationPromptState.unset].
NotificationPromptState parseNotificationPromptState(String? raw) {
  switch (raw) {
    case 'optedIn':
      return NotificationPromptState.optedIn;
    case 'declined':
      return NotificationPromptState.declined;
    default:
      return NotificationPromptState.unset;
  }
}

/// Serialize a state for persistence.
String serializeNotificationPromptState(NotificationPromptState state) =>
    state.name;

/// The core decision: given whether the OS currently grants notifications and
/// the stored per-device state, decide what (if anything) to prompt.
NotificationPromptAction decidePromptAction({
  required bool osGranted,
  required NotificationPromptState state,
}) {
  if (osGranted) return NotificationPromptAction.none;
  switch (state) {
    case NotificationPromptState.unset:
      return NotificationPromptAction.showPriming;
    case NotificationPromptState.optedIn:
      return NotificationPromptAction.showReEnable;
    case NotificationPromptState.declined:
      return NotificationPromptAction.none;
  }
}

/// Map the result of an OS permission request to a user-facing outcome.
/// A denial on the very first ask is a normal decline; a denial after we have
/// asked before means the OS won't show the dialog again → send to settings.
NotificationPromptOutcome mapRequestOutcome({
  required bool granted,
  required bool wasFirstAsk,
}) {
  if (granted) return NotificationPromptOutcome.granted;
  return wasFirstAsk
      ? NotificationPromptOutcome.declined
      : NotificationPromptOutcome.openSettings;
}
