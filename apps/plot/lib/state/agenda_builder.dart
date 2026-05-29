import 'package:plot/state/agenda_model.dart';
// Hide store.dart's `PriorityBlock` (the order-timeline class) so the
// `PriorityBlock` symbol below resolves to agenda_model.dart's UI block.
// The store-side timeline rows are referenced via [PriorityBlockRow]
// instead, which doesn't conflict.
import 'package:plot/store/store.dart' hide PriorityBlock;

/// Pure builder for the agenda's [AgendaModel].
///
/// The agenda is **explicit-only**: the only things that ever appear are
///   1. link-scheduled event threads (calendar events), as [EventBlock]s, and
///   2. focus blocks the user explicitly scheduled (`priority_block` rows
///      with a real time-of-day + duration), as [PriorityBlock]s.
///
/// Both render at the time they are scheduled. Read-only [GapBlock]s mark
/// the free space between consecutive time-anchored blocks. Nothing else —
/// no implicit per-priority grouping of unscheduled todos/notes, no cascade
/// of pending durations, no synthesized "do this anytime" blocks. Threads a
/// user merely scheduled for a day (per-user `state_on`/`state_at` or a
/// shared thread schedule) live in the priority's Active list, NOT here;
/// the agenda only gains a block when the user explicitly creates one.
class AgendaBuilder {
  static AgendaModel build({
    required List<Thread> threads,
    required Priority context,
    required int horizonDays,
    int minFillDays = 0,
    Map<Uuid, List<ThreadAssociationRow>>? associationsByParentId,
    DateTime? now,
    Map<PriorityId, List<PriorityBlockRow>>? priorityBlocksByPriority,

    /// Optional lookup so focus blocks for priorities with no threads in
    /// [threads] still resolve their [Priority]. Defaults to deriving from
    /// `threads`.
    Map<PriorityId, Priority>? priorityById,
  }) {
    final blocksByPriority = priorityBlocksByPriority ?? const {};
    if (threads.isEmpty && blocksByPriority.isEmpty) {
      return AgendaModel.empty;
    }

    final effectiveNow = now ?? Time.now();
    final today = effectiveNow.toDate();
    final todayMidnight = today.toDateTime();

    // A thread is "outside" the current view when its priority is neither
    // the context nor a descendant of it. Outside events render dimmed.
    bool isOutside(Thread t) =>
        t.priority.path != context.path &&
        !context.path.isParent(t.priority.path);

    // Lookups for association rendering and focus-block previews.
    final threadById = <Uuid, Thread>{};
    final threadsByPriority = <PriorityId, List<Thread>>{};
    final priorityLookup = <PriorityId, Priority>{};
    for (final t in threads) {
      threadById[t.id] = t;
      threadsByPriority.putIfAbsent(t.priority.id, () => []).add(t);
      priorityLookup.putIfAbsent(t.priority.id, () => t.priority);
    }
    if (priorityById != null) {
      for (final e in priorityById.entries) {
        priorityLookup.putIfAbsent(e.key, () => e.value);
      }
    }

    final associatedChildIds = <Uuid>{};
    if (associationsByParentId != null) {
      for (final children in associationsByParentId.values) {
        for (final assoc in children) {
          associatedChildIds.add(assoc.childThreadId);
        }
      }
    }

    // --- Events ---------------------------------------------------------
    // An event is a link-schedule instance or a non-todo thread with a real
    // time range. (`Thread.at` already falls back to the all-day `on` range,
    // so every schedule-bearing event has a usable start/end.) Associated
    // children are shown under their parent event, never as top-level events.
    bool isEvent(Thread t) =>
        (t.isLinkScheduleInstance || (t.at != null && !t.todo)) &&
        t.at != null &&
        !associatedChildIds.contains(t.id);

    final seen = <String>{};
    final eventsByDate = <Date, List<Thread>>{};
    for (final t in threads) {
      if (!isEvent(t)) continue;
      final key =
          '${t.id}${t.isLinkScheduleInstance ? '_link' : ''}${t.occurrence ?? ''}';
      if (!seen.add(key)) continue;
      final date = t.agendaAt.toDate();
      if (date.isBefore(today)) continue;
      // On today, drop link-schedule events that already ended — they're
      // read-only external occurrences that need no attention once passed.
      if (date == today &&
          t.isLinkScheduleInstance &&
          t.at?.end != null &&
          t.at!.end!.isBefore(effectiveNow)) {
        continue;
      }
      eventsByDate.putIfAbsent(date, () => []).add(t);
    }

    // --- Focus blocks ---------------------------------------------------
    // priority_block rows with a real time-of-day + positive duration. A
    // midnight-anchored row is an order-timeline anchor, not a focus block.
    final focusByDate =
        <Date, List<({PriorityBlockRow row, Priority priority})>>{};
    for (final entry in blocksByPriority.entries) {
      final priority = priorityLookup[entry.key];
      if (priority == null) continue;
      for (final row in entry.value) {
        if (row.archivedAt != null) continue;
        final d = row.duration;
        if (d == null || d <= Duration.zero) continue;
        final at = row.effectiveAt;
        if (at.isBefore(todayMidnight)) continue;
        if (at.hour == 0 &&
            at.minute == 0 &&
            at.second == 0 &&
            at.millisecond == 0 &&
            at.microsecond == 0) {
          continue;
        }
        focusByDate
            .putIfAbsent(Date(at.year, at.month, at.day), () => [])
            .add((row: row, priority: priority));
      }
    }

    // --- Horizon --------------------------------------------------------
    // Render contiguous days from today through the last day with content
    // (plus a small buffer so users can schedule into upcoming empty days),
    // capped at the query horizon and extended by [minFillDays] as the user
    // scrolls.
    Date? lastContent;
    for (final d in [...eventsByDate.keys, ...focusByDate.keys]) {
      if (lastContent == null || d > lastContent) lastContent = d;
    }
    const emptyDayBuffer = 14;
    final horizon = today.addDays(horizonDays);
    var fillUntil = (lastContent ?? today).addDays(emptyDayBuffer);
    final minFillEnd = today.addDays(minFillDays);
    if (minFillEnd > fillUntil) fillUntil = minFillEnd;
    if (fillUntil > horizon) fillUntil = horizon;

    // --- Build sections -------------------------------------------------
    final sections = <AgendaSection>[];
    for (var date = today; date <= fillUntil; date = date.addDays(1)) {
      final isToday = date == today;
      final sectionId = 'date_$date';

      // Time-anchored blocks for this day: events + focus blocks, sorted by
      // start. (Ties keep events before focus blocks for a stable order.)
      final dayEvents = eventsByDate[date] ?? const [];
      final dayFocus = focusByDate[date] ?? const [];

      final anchored = <({DateTime start, DateTime end, AgendaBlock block})>[];
      for (final event in dayEvents) {
        final eventIsOutside = isOutside(event);
        final associated = <Thread>[];
        if (!eventIsOutside && associationsByParentId != null) {
          final assocs = associationsByParentId[event.id];
          if (assocs != null) {
            final added = <Uuid>{};
            for (final assoc in (assocs.toList()
              ..sort((a, b) => a.order.compareTo(b.order)))) {
              if (!added.add(assoc.childThreadId)) continue;
              final child = threadById[assoc.childThreadId];
              if (child != null) associated.add(child);
            }
          }
        }
        final block = EventBlock(
          id: 'e_${sectionId}_${event.id}'
              '${event.occurrence != null ? '_${event.occurrence}' : ''}',
          priority: event.priority,
          event: event,
          associated: List.unmodifiable(associated),
          isCurrent: isToday && event.at?.includes(effectiveNow) == true,
          isOutside: eventIsOutside,
        );
        anchored.add((start: block.start, end: block.end, block: block));
      }
      for (final entry in dayFocus) {
        final start = entry.row.effectiveAt;
        final end = start.add(entry.row.duration!);
        final preview = (threadsByPriority[entry.priority.id] ?? const [])
            .where((t) => t.active && t.archivedAt == null)
            .toList()
          ..sort((a, b) => b.agendaAt.compareTo(a.agendaAt));
        final block = PriorityBlock(
          id: 'fb_${entry.row.id}',
          priority: entry.priority,
          threads:
              List<Thread>.unmodifiable(preview.take(8).toList(growable: false)),
          cascadeDuration: entry.row.duration,
          windowStart: start,
          windowEnd: end,
          sourceRow: entry.row,
        );
        anchored.add((start: start, end: end, block: block));
      }

      anchored.sort((a, b) {
        final cmp = a.start.compareTo(b.start);
        if (cmp != 0) return cmp;
        // Events before focus blocks on a tie.
        final aEvent = a.block is EventBlock ? 0 : 1;
        final bEvent = b.block is EventBlock ? 0 : 1;
        return aEvent.compareTo(bEvent);
      });

      // Interleave read-only gap markers in the free space between
      // consecutive anchored blocks.
      final blocks = <AgendaBlock>[];
      DateTime? prevEnd;
      for (final a in anchored) {
        if (prevEnd != null && a.start.isAfter(prevEnd)) {
          blocks.add(
            GapBlock(
              id: 'g_${sectionId}_${prevEnd.millisecondsSinceEpoch}',
              priority: context,
              range: DateTimeRange(prevEnd, a.start),
              threads: const [],
            ),
          );
        }
        blocks.add(a.block);
        if (prevEnd == null || a.end.isAfter(prevEnd)) prevEnd = a.end;
      }

      // scheduleAt: the default time the day-header "+" pre-fills when
      // scheduling a focus block — the first hour-long opening in the day.
      final nineAm = date.toStart().add(const Duration(hours: 9));
      final dayStart = isToday && effectiveNow.isAfter(nineAm)
          ? effectiveNow
          : nineAm;
      final scheduleAt =
          _findFirstHourGap(dayStart, date.toEnd(), dayEvents) ?? dayStart;

      sections.add(
        DateSection(
          date: date,
          blocks: List.unmodifiable(blocks),
          isNow: isToday,
          scheduleAt: scheduleAt,
        ),
      );
    }

    return AgendaModel(sections: List.unmodifiable(sections));
  }

  /// First gap of at least one hour in a day's schedule, or null if none.
  /// [dayStart] is the earliest time to consider, [dayEnd] the latest, and
  /// [events] the day's scheduled events.
  static DateTime? _findFirstHourGap(
    DateTime dayStart,
    DateTime dayEnd,
    List<Thread> events,
  ) {
    const oneHour = Duration(hours: 1);
    final scheduled =
        events.where((e) => e.at?.start != null && e.at?.end != null).toList()
          ..sort((a, b) => a.at!.start!.compareTo(b.at!.start!));

    if (scheduled.isEmpty) {
      return dayEnd.difference(dayStart) >= oneHour ? dayStart : null;
    }

    if (scheduled.first.at!.start!.difference(dayStart) >= oneHour) {
      return dayStart;
    }
    for (var i = 0; i < scheduled.length - 1; i++) {
      final end = scheduled[i].at!.end!;
      final nextStart = scheduled[i + 1].at!.start!;
      final gapStart = end.isAfter(dayStart) ? end : dayStart;
      if (nextStart.difference(gapStart) >= oneHour) return gapStart;
    }
    final lastEnd = scheduled.last.at!.end!;
    final gapStart = lastEnd.isAfter(dayStart) ? lastEnd : dayStart;
    return dayEnd.difference(gapStart) >= oneHour ? gapStart : null;
  }
}
