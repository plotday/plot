import 'package:plot/state/agenda_model.dart';
import 'package:plot/store/store.dart';

/// Cross-component signal: when the user taps a multi-thread
/// notification, [NotificationLandingPage] sets this to true. The
/// matching priority page consumes it on mount and scrolls to the
/// Updates section at the top of the unified feed, then clears the
/// flag. Single-thread notifications still route through
/// `ThreadLookupRoute` and never touch this signal.
class PendingActivityFeedView {
  /// Scroll-to-top hint for multi-thread notification taps.
  static bool scrollToUpdates = false;

  /// Deprecated alias for [scrollToUpdates] retained for transitional
  /// callers. The unified feed always shows Updates at the top, so the
  /// old "open Catch up tab" semantics map cleanly onto the scroll hint.
  @Deprecated('Use scrollToUpdates')
  static bool get openCatchUpTab => scrollToUpdates;
  @Deprecated('Use scrollToUpdates')
  static set openCatchUpTab(bool value) => scrollToUpdates = value;
}

/// Transitional shim: the unified feed has only one "tab" (the whole
/// feed). Callers that still reference [ActivityTab] route through this
/// single-value enum; the per-tab SQL paths short-circuit to the
/// unified builder.
enum ActivityTab {
  unified('Activity');

  const ActivityTab(this.label);
  final String label;

  /// All callers reference [actionFilter] to decide which thread_state
  /// flag to filter on. The unified feed never filters at the tab level
  /// (the user's search filters drive that), so this is always null.
  String? get actionFilter => null;

  /// Retained for callers that branched on this. Always false in the
  /// unified feed.
  bool get isActionTab => false;

  /// Backwards-compat alias.
  static const ActivityTab catchUp = ActivityTab.unified;
  static const ActivityTab respond = ActivityTab.unified;
  static const ActivityTab doIt = ActivityTab.unified;
  static const ActivityTab read = ActivityTab.unified;
  static const ActivityTab all = ActivityTab.unified;
}

/// The sections of the unified activity feed.
///
/// The feed is built in this order; the Updates section explicitly
/// duplicates: every unread thread appears in Updates in addition to
/// whichever non-Updates section it would otherwise sit in.
///
/// - [eventAgenda] — Pinned event thread + associated threads. Only
///                   present when an event is currently selected.
/// - [updates]    — All unread threads. Sorted by urgency, like the
///                  pre-tab "Catch up" view. Not a drop target — drops
///                  fall through to the section below.
/// - [doing]      — Active threads not scheduled for the future.
///                  Reorderable end-to-end.
/// - [scheduled]  — Active threads scheduled for a future day.
///                  Per-day sub-sections, reorderable within a day.
/// - [activity]   — Tail of history: everything that's not unread and
///                  not active. Only the top is a valid drop target;
///                  drops there mark the thread done and bump it to
///                  the top of activity.
enum ActivitySection { eventAgenda, updates, doing, scheduled, activity }

/// Classify a thread into its primary (non-Updates) section. The feed
/// builder layers the Updates section on top by scanning for unread
/// threads independently.
ActivitySection primarySectionFor(Thread thread) {
  if (thread.isActiveThread) return ActivitySection.doing;
  if (thread.isScheduledThread) return ActivitySection.scheduled;
  return ActivitySection.activity;
}

/// Backwards-compat alias for callers that haven't moved to the
/// primary/Updates split yet. Returns the primary section.
ActivitySection sectionFor(Thread thread) => primarySectionFor(thread);

/// Marker sentinel embedded in `AgendaHeaderItem.text` so the drag
/// dispatcher can identify which section a header belongs to without
/// string-matching on the displayed label. Encoded as
/// `__activity_section__:<section.name>:<displayLabel>`.
class ActivitySectionMarker {
  static const String prefix = '__activity_section__';

  static String encode(ActivitySection section, {String? label}) {
    return '$prefix:${section.name}:${label ?? defaultLabel(section)}';
  }

  static ({ActivitySection section, String label})? tryDecode(String text) {
    if (!text.startsWith('$prefix:')) return null;
    final parts = text.substring(prefix.length + 1).split(':');
    if (parts.length < 2) return null;
    ActivitySection? section;
    for (final s in ActivitySection.values) {
      if (s.name == parts[0]) {
        section = s;
        break;
      }
    }
    if (section == null) return null;
    final label = parts.sublist(1).join(':');
    return (section: section, label: label);
  }

  static String defaultLabel(ActivitySection section) {
    switch (section) {
      case ActivitySection.eventAgenda:
        return 'Event Agenda';
      case ActivitySection.updates:
        return 'Updates';
      case ActivitySection.doing:
        return 'Doing';
      case ActivitySection.scheduled:
        return 'Scheduled';
      case ActivitySection.activity:
        return 'Activity';
    }
  }
}

/// True for sections where the user can drop a thread anywhere within
/// the section's slot range to position it exactly. Doing and per-day
/// Scheduled rows accept arbitrary drops; Activity only accepts a drop
/// at the very top; Updates is not a drop target at all.
bool sectionAcceptsArbitraryDrop(ActivitySection section) =>
    section == ActivitySection.doing || section == ActivitySection.scheduled;

/// True when the section is a valid drop target only at its very top
/// (and clamps drops anywhere inside to that single slot).
bool sectionDropsAtTopOnly(ActivitySection section) =>
    section == ActivitySection.activity;

/// True when the section accepts no drops at all. The drag dispatcher
/// should fall through to the next section if the pointer is over one
/// of these.
bool sectionRejectsDrops(ActivitySection section) =>
    section == ActivitySection.updates ||
    section == ActivitySection.eventAgenda;

/// Human-readable relative-date label for a Scheduled-section header.
/// "Tomorrow" for today+1, weekday name for the next 6 days, "MMM d"
/// otherwise (with year suffix when the date is outside the current year).
String relativeDateLabel(Date date) {
  final today = Date.today();
  final days = date.difference(today).inDays;
  if (days == 0) return 'Today';
  if (days == 1) return 'Tomorrow';
  if (days >= 2 && days <= 6) {
    const weekdays = [
      'Monday',
      'Tuesday',
      'Wednesday',
      'Thursday',
      'Friday',
      'Saturday',
      'Sunday',
    ];
    return weekdays[date.weekday - 1];
  }
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  final m = months[date.month - 1];
  if (date.year != today.year) return '$m ${date.day}, ${date.year}';
  return '$m ${date.day}';
}

/// Per-feed build output. Kept for callers that still expect a typed
/// container; mirrors the pre-tab and tab-era shape.
class ActivityFeedTabData {
  const ActivityFeedTabData({required this.items});

  final List<AgendaItem> items;

  static const empty = ActivityFeedTabData(items: []);
}
