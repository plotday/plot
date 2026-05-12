import 'package:plot/store/store.dart';

/// Cross-component signal: when a notification tap opens a priority for a
/// multi-thread batch, the next-built activity feed reads this and scrolls
/// to the matching section header (typically [ActivitySection.newSection])
/// so the unread threads land at the top of the viewport.
///
/// Written by the notification tap handler; consumed and cleared by
/// `_PriorityPageState` once the activity feed has items.
class PendingNotificationScroll {
  static ActivitySection? section;
}

/// The sections of the Activity tab. Each thread belongs to exactly
/// one ordinary section, computed from `Thread.isActiveThread` /
/// `isScheduledThread` / `isUnreadOnly` / `isInactiveThread`.
///
/// - [eventAgenda] — Pinned event thread + associated threads. Only
///                   present when an event is currently selected.
/// - [today]      — Active threads (todo with `todoNowDate` sentinel or
///                  schedule date today/past).
/// - [scheduled]  — Todo with a future schedule date (per-day sections).
/// - [newSection] — Unread, not active or scheduled.
/// - [done]       — Inactive (everything else).
enum ActivitySection { eventAgenda, today, scheduled, newSection, done }

/// Classify a thread into its Activity-tab section. Mirrors the four
/// boolean getters on Thread; centralized here so callers can switch on
/// the result without re-deriving the booleans.
ActivitySection sectionFor(Thread thread) {
  if (thread.isActiveThread) return ActivitySection.today;
  if (thread.isScheduledThread) return ActivitySection.scheduled;
  if (thread.isUnreadOnly) return ActivitySection.newSection;
  return ActivitySection.done;
}

/// Marker sentinel embedded in `AgendaHeaderItem.text` so the drag
/// dispatcher can identify which section a header belongs to without
/// string-matching on the displayed label. Encoded as
/// `__activity_section__:<section.name>:<displayLabel>`.
///
/// We use a string sentinel rather than a new field on `AgendaHeaderItem`
/// to avoid changes to the agenda-shared item model that the parallel
/// agenda redesign agent is concurrently editing.
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
      case ActivitySection.today:
        return 'Today';
      case ActivitySection.scheduled:
        return 'Scheduled';
      case ActivitySection.newSection:
        return 'New';
      case ActivitySection.done:
        return 'Done';
    }
  }
}

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
