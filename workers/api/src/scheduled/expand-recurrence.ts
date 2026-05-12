import { RRule, RRuleSet } from "rrule";

export interface RecurringScheduleParent {
  id: string;
  atStart: Date;
  durationSeconds: number;
  recurrenceRule: string;
  recurrenceExdates: Date[];
}

export interface ScheduleOverride {
  /** ISO string from the schedule.occurrence column. */
  occurrence: string;
  atStart: Date;
  atEnd: Date;
}

export interface ExpandedOccurrence {
  scheduleId: string;
  occurrenceAt: Date;
  atStart: Date;
  atEnd: Date;
}

/**
 * Expand a recurring schedule parent's RRULE in JS, applying exdates and
 * per-occurrence overrides, and return the occurrences whose end falls in
 * the lookback window `[windowEnd - lookbackMs, windowEnd)`.
 *
 * Pure function — no DB, no logger. Throws if `recurrenceRule` cannot be
 * parsed; the caller should catch per-parent so one bad rule doesn't kill
 * the whole tick.
 *
 * Timezone caveat: the schedule table doesn't carry a tzid column, so
 * expansion runs in UTC. "Every Tuesday at 9am local" series will drift
 * across DST. Tracked as a follow-up.
 */
export function expandRecurrenceForLookback(
  parent: RecurringScheduleParent,
  overrides: ScheduleOverride[],
  windowEnd: Date,
  lookbackMs: number,
): ExpandedOccurrence[] {
  const windowStart = new Date(windowEnd.getTime() - lookbackMs);
  const durationMs = parent.durationSeconds * 1000;

  // Generously bound the start search so partial-window occurrences (those
  // that started before the lookback but ended inside it) are caught.
  const expandFrom = new Date(windowStart.getTime() - durationMs);
  const expandTo = windowEnd;

  const set = new RRuleSet();
  set.rrule(
    new RRule({
      ...RRule.parseString(parent.recurrenceRule),
      dtstart: parent.atStart,
    }),
  );
  for (const exdate of parent.recurrenceExdates) {
    set.exdate(exdate);
  }

  const occurrenceStarts = set.between(expandFrom, expandTo, true);

  const overrideByOccurrenceMs = new Map<number, ScheduleOverride>();
  for (const ovr of overrides) {
    const occMs = new Date(ovr.occurrence).getTime();
    if (!Number.isNaN(occMs)) {
      overrideByOccurrenceMs.set(occMs, ovr);
    }
  }

  const result: ExpandedOccurrence[] = [];
  for (const occStart of occurrenceStarts) {
    const override = overrideByOccurrenceMs.get(occStart.getTime());
    const atStart = override ? override.atStart : occStart;
    const atEnd = override
      ? override.atEnd
      : new Date(occStart.getTime() + durationMs);
    if (atEnd >= windowStart && atEnd < windowEnd) {
      result.push({
        scheduleId: parent.id,
        occurrenceAt: occStart,
        atStart,
        atEnd,
      });
    }
  }
  return result;
}
