/**
 * Pure-function helpers for the event-session finalizer's overlap math.
 *
 * Goal: for each event candidate, compute a single synthetic `at` range
 * that captures the user's "free" time inside the event window — the
 * parts not already covered by another session (active or earlier-kept
 * event). The output range starts at the earliest free moment in the
 * window and has length `free_seconds`. Its `lower`/`upper` no longer
 * correspond to the actual time-of-day of the event; downstream code
 * treats `session.at` as an accounting interval for `SUM(end - start)`,
 * not a clock-time record.
 *
 * No DB, no logger. Easy to unit-test.
 */

export interface TimeRange {
  start: Date;
  end: Date;
}

export interface EventCandidate {
  userId: string;
  scheduleId: string;
  occurrenceAt: Date;
  priorityId: string;
  atStart: Date;
  atEnd: Date;
}

export interface BlockerRange extends TimeRange {
  userId: string;
  /** For the idempotent self-match filter. */
  scheduleId: string | null;
  occurrenceAt: Date | null;
  /** 'event' blockers may be the candidate's own prior write; filter them out. */
  source: string;
}

export interface ResolvedSession {
  userId: string;
  scheduleId: string;
  occurrenceAt: Date;
  priorityId: string;
  atStart: Date;
  atEnd: Date;
}

/**
 * Merge a sorted list of ranges into a disjoint sorted list. Input does
 * NOT need to be pre-sorted; this function sorts a copy. Touch-only
 * adjacency (`a.end === b.start`) collapses into one range.
 */
export function mergeRanges(ranges: TimeRange[]): TimeRange[] {
  if (ranges.length <= 1) return ranges.slice();
  const sorted = ranges
    .slice()
    .sort((a, b) => a.start.getTime() - b.start.getTime());
  const out: TimeRange[] = [{ start: sorted[0].start, end: sorted[0].end }];
  for (let i = 1; i < sorted.length; i++) {
    const last = out[out.length - 1];
    const r = sorted[i];
    if (r.start.getTime() <= last.end.getTime()) {
      if (r.end.getTime() > last.end.getTime()) {
        last.end = r.end;
      }
    } else {
      out.push({ start: r.start, end: r.end });
    }
  }
  return out;
}

/**
 * Intersect a window `[winStart, winEnd)` with a disjoint sorted list of
 * blockers and return the total covered milliseconds. The blockers
 * outside the window contribute zero.
 */
export function totalOverlapMs(
  winStart: Date,
  winEnd: Date,
  mergedBlockers: readonly TimeRange[],
): number {
  let total = 0;
  const ws = winStart.getTime();
  const we = winEnd.getTime();
  for (const b of mergedBlockers) {
    const bs = b.start.getTime();
    const be = b.end.getTime();
    if (be <= ws) continue;
    if (bs >= we) break;
    total += Math.min(be, we) - Math.max(bs, ws);
  }
  return total;
}

/**
 * First point inside `[winStart, winEnd)` not covered by any merged
 * blocker. Returns `winStart` when the window starts free; returns the
 * blocker's end when the window starts inside a blocker. Returns null
 * iff no free point exists (blockers fully cover the window).
 */
export function firstFreePoint(
  winStart: Date,
  winEnd: Date,
  mergedBlockers: readonly TimeRange[],
): Date | null {
  const ws = winStart.getTime();
  const we = winEnd.getTime();
  let cursor = ws;
  for (const b of mergedBlockers) {
    const bs = b.start.getTime();
    const be = b.end.getTime();
    if (be <= cursor) continue;
    if (bs > cursor) return new Date(cursor);
    cursor = Math.max(cursor, be);
    if (cursor >= we) return null;
  }
  return cursor < we ? new Date(cursor) : null;
}

/**
 * Comparator that yields the deterministic order used for within-batch
 * "earlier wins" overlap resolution.
 */
function compareCandidates(a: EventCandidate, b: EventCandidate): number {
  const dt = a.atStart.getTime() - b.atStart.getTime();
  if (dt !== 0) return dt;
  if (a.scheduleId !== b.scheduleId) {
    return a.scheduleId < b.scheduleId ? -1 : 1;
  }
  return a.occurrenceAt.getTime() - b.occurrenceAt.getTime();
}

/**
 * Resolve a batch of event candidates against pre-existing session
 * blockers and against each other (earlier-ordered wins). Emits one
 * resolved session per candidate that has any free time remaining.
 *
 * Idempotency note: the caller pre-fetches blockers via the SPGIST
 * index on `session.at`; the candidate's own prior `source='event'`
 * row (if any) is identified by `(scheduleId, occurrenceAt)` and
 * skipped here so we don't subtract our own previous write.
 */
export function resolveCandidates(
  candidates: readonly EventCandidate[],
  blockers: readonly BlockerRange[],
): ResolvedSession[] {
  const blockersByUser = new Map<string, TimeRange[]>();
  for (const b of blockers) {
    const list = blockersByUser.get(b.userId) ?? [];
    list.push({ start: b.start, end: b.end });
    blockersByUser.set(b.userId, list);
  }

  const ordered = candidates.slice().sort(compareCandidates);
  const out: ResolvedSession[] = [];

  for (const c of ordered) {
    // Pull this user's blockers, filtering the candidate's own idempotent
    // self-match: a prior 'event' row with the same (scheduleId,
    // occurrenceAt) is OUR existing write — including it would shrink
    // the free time to zero on every steady-state tick.
    const userBlockers: TimeRange[] = [];
    for (const b of blockers) {
      if (b.userId !== c.userId) continue;
      if (
        b.source === "event"
        && b.scheduleId === c.scheduleId
        && b.occurrenceAt !== null
        && b.occurrenceAt.getTime() === c.occurrenceAt.getTime()
      ) {
        continue;
      }
      userBlockers.push({ start: b.start, end: b.end });
    }
    // Earlier-ordered kept candidates are blockers too.
    for (const kept of out) {
      if (kept.userId !== c.userId) continue;
      userBlockers.push({ start: kept.atStart, end: kept.atEnd });
    }

    const merged = mergeRanges(userBlockers);
    const overlap = totalOverlapMs(c.atStart, c.atEnd, merged);
    const eventMs = c.atEnd.getTime() - c.atStart.getTime();
    const freeMs = Math.max(0, eventMs - overlap);
    if (freeMs === 0) continue;

    const start = firstFreePoint(c.atStart, c.atEnd, merged);
    if (start === null) continue; // shouldn't happen if freeMs > 0, defensive
    out.push({
      userId: c.userId,
      scheduleId: c.scheduleId,
      occurrenceAt: c.occurrenceAt,
      priorityId: c.priorityId,
      atStart: start,
      atEnd: new Date(start.getTime() + freeMs),
    });
  }

  return out;
}
