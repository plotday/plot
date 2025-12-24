/// PostHog Event Naming Convention
///
/// Format: [Category] Object Action
///
/// Categories (capitalized, in brackets):
/// - [Action]: User-initiated actions (CRUD operations)
/// - [Navigation]: Screen/route changes
/// - [Error]: Errors and failures
/// - [Performance]: Performance monitoring events
/// - [Session]: Authentication and session events
///
/// Objects (Title Case):
/// - Activity, Priority, Twist, Tag, Filter, etc.
/// - Screen names: Priority Detail, Activity List, Settings, etc.
///
/// Actions (Title Case):
/// - Past tense verbs from approved dictionary
///
/// Verb Dictionary:
///
/// CRUD Verbs (past tense):
/// - added: Entity created/added
/// - updated: Entity modified
/// - archived: Entity soft-deleted/archived
/// - unarchived: Entity unarchived/undeleted
/// - deleted: Entity permanently deleted
///
/// State Change Verbs:
/// - started: Activity/process began
/// - finished: Activity/process completed
/// - scheduled: Time assigned to activity
/// - rescheduled: Time changed for activity
/// - pinned: Entity pinned to top
/// - unpinned: Entity unpinned
/// - tagged: Tag added to entity
/// - untagged: Tag removed from entity
/// - unfinished: Activity marked incomplete
/// - moved: Entity moved to different container/priority
///
/// Navigation Verbs:
/// - viewed: Screen/page/entity viewed
/// - opened: Dialog/modal/detail opened
/// - closed: Dialog/modal closed
/// - navigated: Route changed
///
/// Interaction Verbs:
/// - clicked: Button/link clicked
/// - searched: Search query executed
/// - filtered: Filter applied
/// - sorted: Sort order changed
/// - selected: Item picked from list
///
/// Session Verbs:
/// - signed_in: User authenticated
/// - signed_out: User logged out
/// - identified: User identity set
///
/// Error/Performance Verbs:
/// - failed: Operation failed
/// - timed_out: Operation exceeded time limit
/// - errored: Error occurred
///
/// Examples:
/// - [Action] Activity Added
/// - [Action] Priority Updated
/// - [Action] Activity Archived
/// - [Action] Activity Unarchived
/// - [Action] Activity Tagged
/// - [Navigation] Priority Detail Viewed
/// - [Error] Activity Failed
/// - [Performance] Action Timed Out
/// - [Session] User Signed In

library;

/// Event categories
enum EventCategory {
  action('action'),
  navigation('navigation'),
  error('error'),
  performance('performance'),
  session('session');

  const EventCategory(this.value);
  final String value;
}

/// Common event objects
enum EventObject {
  activity('activity'),
  note('note'),
  priority('priority'),
  twist('twist'),
  tag('tag'),
  filter('filter'),
  archived('archived'),
  user('user'),
  action('action'),
  navigation('navigation'),
  commandBar('command_bar'),
  modal('modal'),
  settings('settings');

  const EventObject(this.value);
  final String value;
}

/// Approved action verbs (past tense)
enum EventAction {
  // CRUD
  added('added'),
  updated('updated'),
  archived('archived'),
  unarchived('unarchived'),
  deleted('deleted'),

  // State changes
  started('started'),
  finished('finished'),
  scheduled('scheduled'),
  rescheduled('rescheduled'),
  unscheduled('unscheduled'),
  pinned('pinned'),
  unpinned('unpinned'),
  tagged('tagged'),
  untagged('untagged'),
  unfinished('unfinished'),
  moved('moved'),

  // Navigation
  viewed('viewed'),
  opened('opened'),
  closed('closed'),
  navigated('navigated'),

  // Interaction
  clicked('clicked'),
  searched('searched'),
  filtered('filtered'),
  sorted('sorted'),
  selected('selected'),

  // Session
  signedIn('signed_in'),
  signedOut('signed_out'),
  identified('identified'),

  // Error/Performance
  failed('failed'),
  timedOut('timed_out'),
  errored('errored');

  const EventAction(this.value);
  final String value;
}

/// Helper to convert snake_case to Title Case
String _toTitleCase(String snakeCase) {
  return snakeCase
      .split('_')
      .map((word) => word[0].toUpperCase() + word.substring(1))
      .join(' ');
}

/// Helper to build event names following the convention
String buildEventName(
  EventCategory category,
  EventObject object,
  EventAction action,
) {
  final categoryFormatted = _toTitleCase(category.value);
  final objectFormatted = _toTitleCase(object.value);
  final actionFormatted = _toTitleCase(action.value);
  return '[$categoryFormatted] $objectFormatted $actionFormatted';
}
