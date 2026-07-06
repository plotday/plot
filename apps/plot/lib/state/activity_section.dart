import 'package:plot/state/agenda_model.dart';
import 'package:plot/store/store.dart';

/// Cross-component signal: when the user taps a multi-thread
/// notification, [NotificationLandingPage] sets this to true. The
/// matching priority page consumes it on mount and scrolls to the top
/// of the unified feed, then clears the flag. Single-thread notifications
/// still route through `ThreadLookupRoute` and never touch this signal.
class PendingActivityFeedView {
  /// Scroll-to-top hint for multi-thread notification taps.
  static bool scrollToUpdates = false;

  /// One-shot: when true, the next [PriorityPage] to mount will enable
  /// the unread-only filter once, then clear this flag. Set by
  /// [_navigateToNotificationTarget] for multi-thread and no-thread
  /// notification taps. Single-thread deep-links leave this false (the
  /// thread opens directly; Task 11's auto-off handles the empty case).
  /// Normal (non-notification) navigation into a focus never sets this.
  static bool openUnreadOnly = false;
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
/// The feed is built in this order. There is no separate "Updates"
/// section: active to-dos hold the top of [doing] in their chosen
/// `order` (read and unread intermixed), and non-active unread threads
/// gather in a cluster at the BOTTOM of [doing] (sorted by urgency,
/// importance, order) so incoming messages never push committed work
/// down. When the user opens a non-active unread thread it stays
/// sticky-pinned in that bottom cluster until they navigate away, then
/// drains to its natural primary section (usually [activity], or
/// [scheduled] if it has a future day).
///
/// - [eventAgenda] — Pinned event thread + associated threads. Only
///                   present when an event is currently selected.
/// - [doing]      — Active to-dos at the top, holding their `order`
///                  position (read and unread intermixed), then a
///                  cluster of non-active unread threads at the bottom
///                  (sorted by urgent, importance, order). Reorderable
///                  end-to-end.
/// - [scheduled]  — Read active threads scheduled for a future day.
///                  Per-day sub-sections, reorderable within a day.
/// - [activity]   — Tail of history: read threads with no active
///                  state. Only the top is a valid drop target;
///                  drops there mark the thread done and bump it to
///                  the top of activity.
enum ActivitySection { eventAgenda, doing, scheduled, activity }

/// Classify a thread into its natural primary section based on its
/// underlying state. Non-active unread threads are gathered into the
/// bottom cluster of [doing] by the feed builder independently of this
/// classification, so when such a thread is later marked read it returns
/// to the section this function would return for it (i.e. its scheduled
/// day, or activity if it has no active state).
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
      case ActivitySection.doing:
        return 'Active';
      case ActivitySection.scheduled:
        return 'Scheduled';
      case ActivitySection.activity:
        return 'Done';
    }
  }
}

/// True for sections where the user can drop a thread anywhere within
/// the section's slot range to position it exactly. Doing and per-day
/// Scheduled rows accept arbitrary drops; Activity only accepts a drop
/// at the very top.
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
  const ActivityFeedTabData({
    required this.items,
    this.everythingFeed = false,
    this.context,
    this.moveGen = 0,
    this.movedIds = const {},
    this.unreadClusterIds = const {},
  });

  final List<AgendaItem> items;

  /// Generation counter advanced when this rebuild was caused by an
  /// explicit user state change in the sectioned feed; the page animates
  /// the items diff when it advances. Unchanged for stream-driven
  /// rebuilds.
  final int moveGen;

  /// The threads whose explicit state change produced this generation.
  final Set<ThreadId> movedIds;

  /// The priority context these items were built for. The page compares each
  /// row's filed priority against THIS (via [PriorityState.activeTabContext])
  /// — not the live `state.context` — to decide whether to show the per-row
  /// sub-priority (focus) label. During a focus switch the previous focus's
  /// items are deliberately kept on screen until the new feed rebuilds; if the
  /// label keyed on the live context, those kept rows would briefly sprout the
  /// previous focus's label (their filed priority no longer matches the new
  /// context) for the frame before they swap out. Keeping the comparison on
  /// the build-time context keeps header and items in the same generation.
  final Priority? context;

  /// True when these items were built for the dedicated (non-search,
  /// non-filter) "Everything" feed — i.e. the unsectioned cross-focus list
  /// that leads with a single "Everything" header. The page reads this
  /// (via [PriorityState.activeTabEverythingFeed]) instead of the live
  /// `everything` flag so the header and the items always belong to the
  /// same generation: when the flag flips on navigation but the feed hasn't
  /// rebuilt yet, the header doesn't appear over stale sectioned data.
  final bool everythingFeed;

  /// Thread ids of the non-active unread cluster at the bottom of the Doing
  /// section. Used by the drag system to apply source-aware drop boundaries:
  /// an active thread can only land at the end of Active (not between cluster
  /// rows), while an unread thread keeps full reorder + promote-up behavior.
  /// Empty when the feed is in flat mode (search/filter/everything) or when
  /// there is no unread cluster.
  final Set<ThreadId> unreadClusterIds;

  static const empty = ActivityFeedTabData(items: []);
}
