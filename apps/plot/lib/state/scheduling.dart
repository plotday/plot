import 'package:plot/store/attention.dart';

/// Pure interval math for the agenda's window-aware auto-block placer.
///
/// The placer's job is to pick a calendar slot for one priority's "respond"
/// block given:
///   - the priority's `respond_window` (active hours when blocks may land)
///   - the priority's `respond_within` SLA
///   - the set of currently-pending respond threads (their arrival times,
///     urgency flags)
///   - the set of busy intervals (calendar events, user-placed/pinned
///     `priority_block` rows, and previously-placed auto-blocks from this
///     compute pass)
///
/// No I/O lives here — all inputs are passed in, and the result is a
/// single [RespondBlockSlot] (or null when there is nothing to place).

/// Closed half-open interval `[start, end)` that the placer must avoid.
class BusyInterval {
  const BusyInterval({required this.start, required this.end});

  final DateTime start;
  final DateTime end;
}

/// One respond-eligible thread's arrival data.
class RespondThreadInput {
  const RespondThreadInput({required this.arrivedAt, required this.urgent});

  final DateTime arrivedAt;
  final bool urgent;
}

/// The placer's output. [overflow] is true whenever the placer couldn't
/// honour all of the "in respond window, before deadline, not busy"
/// constraints simultaneously — typically because every slot before the
/// deadline overlapped a busy interval, or the deadline fell entirely in
/// a closed period. The agenda renders the block's duration in red when
/// overflow is set.
class RespondBlockSlot {
  const RespondBlockSlot({
    required this.start,
    required this.end,
    required this.overflow,
  });

  final DateTime start;
  final DateTime end;
  final bool overflow;
}

/// Compute the response deadline for [threads] under [respondWithin].
/// Urgent threads contribute `arrivedAt` directly (no slack); others
/// contribute `arrivedAt + respondWithin`. Returns the earliest deadline.
DateTime computeRespondDeadline({
  required List<RespondThreadInput> threads,
  required SeeWithinTime respondWithin,
}) {
  assert(threads.isNotEmpty, 'computeRespondDeadline needs at least one thread');
  final slack = seeWithinToDuration(respondWithin);
  DateTime? earliest;
  for (final t in threads) {
    final candidate = t.urgent ? t.arrivedAt : t.arrivedAt.add(slack);
    if (earliest == null || candidate.isBefore(earliest)) earliest = candidate;
  }
  return earliest!;
}

/// Convert a [SeeWithinTime] to a [Duration].
Duration seeWithinToDuration(SeeWithinTime t) {
  switch (t.unit) {
    case SeeWithinUnit.minutes:
      return Duration(minutes: t.value);
    case SeeWithinUnit.hours:
      return Duration(hours: t.value);
    case SeeWithinUnit.days:
      return Duration(days: t.value);
  }
}

/// Find the latest [slotDuration]-long slot ending on or before [deadline]
/// that (a) falls inside one of [respondWindow] and (b) doesn't overlap
/// any [busy] interval.
///
/// Algorithm:
/// 1. Walk backward through the days between today and [deadline].
/// 2. Within each day's respond windows, generate candidate slot starts
///    aligned to 15-minute boundaries, latest-first.
/// 3. Return the first candidate that doesn't overlap a busy interval.
/// 4. If no non-busy candidate fits, fall back to:
///    - the latest in-window slot before [deadline] (overflow = true), or
///    - the next in-window slot after [deadline] when [deadline] lives in
///      a closed period (overflow = true).
///
/// Returns null only when [respondWindow] is empty.
RespondBlockSlot? findRespondBlockSlot({
  required DateTime now,
  required DateTime deadline,
  required List<AttentionWindow> respondWindow,
  required List<BusyInterval> busy,
  Duration slotDuration = const Duration(minutes: 15),
}) {
  if (respondWindow.isEmpty) return null;

  // Deadline already passed → place immediately (snapped to the next
  // 15-minute boundary, clamped to the next respond window if necessary).
  if (!deadline.isAfter(now)) {
    final slot = _placeAtOrAfter(
      moment: now,
      respondWindow: respondWindow,
      slotDuration: slotDuration,
      busy: busy,
    );
    return RespondBlockSlot(
      start: slot.start,
      end: slot.end,
      overflow: true,
    );
  }

  final candidates = _candidateSlotsBeforeDeadline(
    now: now,
    deadline: deadline,
    respondWindow: respondWindow,
    slotDuration: slotDuration,
  );

  for (final candidate in candidates) {
    final candidateEnd = candidate.add(slotDuration);
    if (!_overlapsBusy(start: candidate, end: candidateEnd, busy: busy)) {
      return RespondBlockSlot(
        start: candidate,
        end: candidateEnd,
        overflow: false,
      );
    }
  }

  if (candidates.isNotEmpty) {
    // Every in-window slot before the deadline overlaps a busy interval.
    // Take the latest one anyway and flag the block as overflowing.
    final slot = candidates.first;
    return RespondBlockSlot(
      start: slot,
      end: slot.add(slotDuration),
      overflow: true,
    );
  }

  // No in-window slot exists in [now, deadline] — the deadline falls in
  // a closed period. Spill into the next opening past the deadline.
  final spill = _placeAtOrAfter(
    moment: deadline,
    respondWindow: respondWindow,
    slotDuration: slotDuration,
    busy: busy,
  );
  return RespondBlockSlot(
    start: spill.start,
    end: spill.end,
    overflow: true,
  );
}

class _Slot {
  const _Slot({required this.start, required this.end});
  final DateTime start;
  final DateTime end;
}

/// Place a slot at or after [moment], snapped to a 15-minute boundary
/// inside one of [respondWindow]. Tries to honour [busy] by advancing
/// within the window, but accepts a busy overlap as last resort rather
/// than failing.
_Slot _placeAtOrAfter({
  required DateTime moment,
  required List<AttentionWindow> respondWindow,
  required Duration slotDuration,
  required List<BusyInterval> busy,
}) {
  for (var i = 0; i < 14; i++) {
    final day = DateTime(moment.year, moment.month, moment.day + i);
    final weekday = day.weekday;
    for (final w in respondWindow) {
      if (!w.days.contains(weekday)) continue;
      final wStart = _windowStart(day, w);
      final wEnd = _windowEnd(day, w);
      DateTime candidate = i == 0 && moment.isAfter(wStart)
          ? snapForward(moment)
          : wStart;
      if (candidate.isBefore(wStart)) candidate = wStart;
      while (!candidate.add(slotDuration).isAfter(wEnd)) {
        if (!_overlapsBusy(
          start: candidate,
          end: candidate.add(slotDuration),
          busy: busy,
        )) {
          return _Slot(
            start: candidate,
            end: candidate.add(slotDuration),
          );
        }
        candidate = candidate.add(slotDuration);
      }
    }
  }
  // Worst-case fallback: place at [moment] snapped forward, ignoring
  // windows entirely. Shouldn't happen if respondWindow has any opening
  // in the next 14 days.
  final snapped = snapForward(moment);
  return _Slot(start: snapped, end: snapped.add(slotDuration));
}

DateTime _windowStart(DateTime day, AttentionWindow w) {
  final parts = w.start.split(':');
  return DateTime(
    day.year,
    day.month,
    day.day,
    int.parse(parts[0]),
    int.parse(parts[1]),
  );
}

DateTime _windowEnd(DateTime day, AttentionWindow w) {
  final parts = w.end.split(':');
  return DateTime(
    day.year,
    day.month,
    day.day,
    int.parse(parts[0]),
    int.parse(parts[1]),
  );
}

/// Round [moment] forward to the next 15-minute boundary. Already-aligned
/// moments are returned unchanged.
DateTime snapForward(DateTime moment) {
  if (moment.minute % 15 == 0 &&
      moment.second == 0 &&
      moment.millisecond == 0 &&
      moment.microsecond == 0) {
    return DateTime(
      moment.year,
      moment.month,
      moment.day,
      moment.hour,
      moment.minute,
    );
  }
  final base = DateTime(
    moment.year,
    moment.month,
    moment.day,
    moment.hour,
    moment.minute,
  );
  final remainder = base.minute % 15;
  return base.add(Duration(minutes: 15 - remainder));
}

/// Round [moment] backward to the previous 15-minute boundary.
DateTime snapBackward(DateTime moment) {
  final minutes = moment.minute - (moment.minute % 15);
  return DateTime(
    moment.year,
    moment.month,
    moment.day,
    moment.hour,
    minutes,
  );
}

bool _overlapsBusy({
  required DateTime start,
  required DateTime end,
  required List<BusyInterval> busy,
}) {
  for (final b in busy) {
    if (start.isBefore(b.end) && b.start.isBefore(end)) return true;
  }
  return false;
}

/// Generate candidate slot starts in `[now, deadline]` from latest to
/// earliest, snapped to 15-minute boundaries and constrained to lie
/// inside one of [respondWindow].
List<DateTime> _candidateSlotsBeforeDeadline({
  required DateTime now,
  required DateTime deadline,
  required List<AttentionWindow> respondWindow,
  required Duration slotDuration,
}) {
  final candidates = <DateTime>[];
  final startDay = DateTime(deadline.year, deadline.month, deadline.day);
  final endDay = DateTime(now.year, now.month, now.day);
  for (
    var day = startDay;
    !day.isBefore(endDay);
    day = day.subtract(const Duration(days: 1))
  ) {
    final weekday = day.weekday;
    for (final w in respondWindow) {
      if (!w.days.contains(weekday)) continue;
      final wStart = _windowStart(day, w);
      final wEnd = _windowEnd(day, w);
      final rangeStart = wStart.isAfter(now) ? wStart : now;
      final rangeEnd = wEnd.isBefore(deadline) ? wEnd : deadline;
      if (!rangeStart.isBefore(rangeEnd)) continue;
      // Latest slot start whose end ≤ rangeEnd.
      var slotStart = snapBackward(rangeEnd.subtract(slotDuration));
      while (!slotStart.isBefore(rangeStart) &&
          !slotStart.add(slotDuration).isAfter(rangeEnd)) {
        candidates.add(slotStart);
        slotStart = slotStart.subtract(slotDuration);
      }
    }
  }
  // Latest-first so callers can pick the latest non-busy slot greedily.
  candidates.sort((a, b) => b.compareTo(a));
  // Dedupe (overlapping windows on the same day could emit the same slot).
  if (candidates.length > 1) {
    final seen = <int>{};
    candidates.retainWhere((c) => seen.add(c.millisecondsSinceEpoch));
  }
  return candidates;
}
