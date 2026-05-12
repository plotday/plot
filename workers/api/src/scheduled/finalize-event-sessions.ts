import { sql, type Kysely } from "kysely";
import type { Bindings } from "../env";
import { createLogger, type Logger } from "@plotday/worker-util";
import { createDb, type DB } from "../db";
import {
  expandRecurrenceForLookback,
  type ExpandedOccurrence,
  type RecurringScheduleParent,
  type ScheduleOverride,
} from "./expand-recurrence";
import {
  resolveCandidates,
  type BlockerRange,
  type EventCandidate,
  type ResolvedSession,
} from "./event-overlap";

const STEADY_LOOKBACK_MS = 30 * 60 * 1000;
const BACKFILL_LOOKBACK_MS = 90 * 24 * 60 * 60 * 1000;
const BACKFILL_USERS_PER_TICK = 20;

/**
 * Periodic sweep that converts ended calendar-event occurrences into
 * `source='event'` Session rows so weekly priority totals reflect time
 * spent on the event when the user's app was closed.
 *
 * Scope: link-based schedules only — i.e. events synced from connected
 * calendars (Google Calendar etc.). User-created thread-only schedules
 * are intentionally NOT finalized here; those accrue time only via
 * explicit `source='active'` sessions from the client.
 *
 * RSVP gate (per user, across all of the user's linked contacts on the
 * schedule):
 *   * no contact has `status='skip'`, OR
 *   * at least one contact has `status='attend'`.
 * This handles duplicate invites where the user declined on one address,
 * and the "attended without RSVPing" case.
 *
 * No double-counting:
 *   * Existing non-archived sessions overlapping the event reduce the
 *     event's free time. Active sessions take precedence over events.
 *   * Among overlapping candidates within one tick, the earlier-ordered
 *     (by at_start, schedule_id, occurrence_at) wins and becomes a
 *     blocker for later candidates.
 *   * One row per (user, schedule, occurrence). The row's `at` is a
 *     synthetic range: it starts at the earliest free moment in the
 *     event window and has length = total non-overlapping seconds.
 *     `SUM(upper(at) - lower(at))` is correct; time-of-day is not.
 *
 * Idempotency: the partial unique index
 *   idx_session_schedule_occurrence (user_id, schedule_id, occurrence_at)
 * carries it. Re-runs UPDATE the `at` if blockers changed (otherwise no
 * write, so seq doesn't churn).
 *
 * Phases:
 *   * Phase A — every tick, steady-state. Users with
 *     `user_settings.event_sessions_finalized_through IS NOT NULL`.
 *     Lookback is GREATEST(finalized_through, now() - 30 min) so missed
 *     ticks self-heal.
 *   * Phase B — every tick, bounded. Up to BACKFILL_USERS_PER_TICK users
 *     where the watermark is NULL. Lookback is 90 days. After processing,
 *     the watermark is set to now() so the next tick uses Phase A.
 *
 * Worker-side note: tracking-paused users are handled by the per-row
 * filter `(us.tracking_paused_at IS NULL OR upper(s.at) < us.tracking_paused_at)`,
 * matching the retroactive reconciliation in `upsert_user_settings`.
 */
export async function finalizeEventSessions(
  env: Bindings,
  _ctx: ExecutionContext
): Promise<void> {
  const logger = createLogger({ operation: "finalizeEventSessions" });
  const db = createDb(env);

  try {
    await runPhaseA(db, logger);
    await runPhaseB(db, logger);
  } catch (error) {
    logger.error("finalizeEventSessions failed", error as Error);
  } finally {
    await db.destroy();
  }
}

async function runPhaseA(db: Kysely<DB>, logger: Logger): Promise<void> {
  const now = new Date();
  const lookbackStart = new Date(now.getTime() - STEADY_LOOKBACK_MS);

  const usersResult = await db.executeQuery(
    sql<{ user_id: string }>`
      SELECT user_id
      FROM public.user_settings
      WHERE event_sessions_finalized_through IS NOT NULL
    `.compile(db)
  );
  const userIds = usersResult.rows.map((r) => r.user_id);
  if (userIds.length === 0) return;

  await processUsers(db, logger, "steady", userIds, lookbackStart, now);

  // Advance the watermark for every Phase A user so a future outage is
  // bounded by their last successful tick rather than by a wall-clock cap.
  await db.executeQuery(
    sql`
      UPDATE public.user_settings
      SET event_sessions_finalized_through = ${now}
      WHERE user_id = ANY(${userIds}::uuid[])
        AND event_sessions_finalized_through IS NOT NULL
    `.compile(db)
  );
}

async function runPhaseB(db: Kysely<DB>, logger: Logger): Promise<void> {
  const now = new Date();
  const lookbackStart = new Date(now.getTime() - BACKFILL_LOOKBACK_MS);

  const usersResult = await db.executeQuery(
    sql<{ user_id: string }>`
      SELECT user_id
      FROM public.user_settings
      WHERE event_sessions_finalized_through IS NULL
      ORDER BY user_id
      LIMIT ${BACKFILL_USERS_PER_TICK}
    `.compile(db)
  );
  const userIds = usersResult.rows.map((r) => r.user_id);
  if (userIds.length === 0) return;

  await processUsers(db, logger, "backfill", userIds, lookbackStart, now);

  // Mark these users as backfilled. If processUsers threw, we don't reach
  // here and the same users retry next tick (idempotent).
  await db.executeQuery(
    sql`
      UPDATE public.user_settings
      SET event_sessions_finalized_through = ${now}
      WHERE user_id = ANY(${userIds}::uuid[])
        AND event_sessions_finalized_through IS NULL
    `.compile(db)
  );

  logger.info("Event session backfill processed", {
    user_count: userIds.length,
  });
}

async function processUsers(
  db: Kysely<DB>,
  logger: Logger,
  phase: "steady" | "backfill",
  userIds: string[],
  lookbackStart: Date,
  now: Date
): Promise<void> {
  const lookbackMs = now.getTime() - lookbackStart.getTime();

  const [nonRecurring, recurring] = await Promise.all([
    fetchNonRecurringCandidates(db, userIds, lookbackStart, now),
    fetchAndExpandRecurringCandidates(db, logger, userIds, lookbackMs, now),
  ]);

  const candidates: EventCandidate[] = [...nonRecurring, ...recurring];
  if (candidates.length === 0) return;

  const blockers = await fetchBlockers(db, userIds, candidates);
  const resolved = resolveCandidates(candidates, blockers);
  if (resolved.length === 0) return;

  const writeCounts = await upsertResolved(db, resolved);
  if (writeCounts.inserted > 0 || writeCounts.updated > 0) {
    logger.info("Event session finalizer wrote rows", {
      phase,
      user_count: userIds.length,
      candidates: candidates.length,
      resolved: resolved.length,
      inserted: writeCounts.inserted,
      updated: writeCounts.updated,
    });
  }
}

interface CandidateRow {
  user_id: string;
  schedule_id: string;
  occurrence_at: Date;
  at_start: Date;
  at_end: Date;
  priority_id: string;
}

async function fetchNonRecurringCandidates(
  db: Kysely<DB>,
  userIds: string[],
  lookbackStart: Date,
  now: Date
): Promise<EventCandidate[]> {
  const result = await db.executeQuery(
    sql<CandidateRow>`
      SELECT DISTINCT
        uc.user_id,
        s.id AS schedule_id,
        lower(s.at) AS occurrence_at,
        lower(s.at) AS at_start,
        upper(s.at) AS at_end,
        tp.priority_id
      FROM public.schedule s
        JOIN public.link l ON l.id = s.link_id
        JOIN public.thread t ON t.id = l.thread_id
        JOIN public.thread_priority tp ON tp.thread_id = t.id
        JOIN public.user_contact uc
          ON uc.user_id = tp.user_id AND uc.linked = TRUE
        JOIN public.schedule_contact sc_user
          ON sc_user.schedule_id = s.id AND sc_user.contact_id = uc.contact_id
        LEFT JOIN public.user_settings us ON us.user_id = uc.user_id
      WHERE
        uc.user_id = ANY(${userIds}::uuid[])
        AND s.archived_at IS NULL
        AND s.link_id IS NOT NULL
        AND s.recurrence_rule IS NULL
        AND s.occurrence IS NULL
        AND t.archived_at IS NULL
        AND s.at && tstzrange(${lookbackStart}, ${now}, '[]')
        AND upper(s.at) >= ${lookbackStart}
        AND upper(s.at) < ${now}
        AND (us.tracking_paused_at IS NULL OR upper(s.at) < us.tracking_paused_at)
        AND (
          NOT EXISTS (
            SELECT 1 FROM public.schedule_contact sc_decl
              JOIN public.user_contact uc_decl
                ON uc_decl.contact_id = sc_decl.contact_id
                AND uc_decl.user_id = uc.user_id
                AND uc_decl.linked = TRUE
            WHERE sc_decl.schedule_id = s.id AND sc_decl.status = 'skip'
          )
          OR EXISTS (
            SELECT 1 FROM public.schedule_contact sc_acc
              JOIN public.user_contact uc_acc
                ON uc_acc.contact_id = sc_acc.contact_id
                AND uc_acc.user_id = uc.user_id
                AND uc_acc.linked = TRUE
            WHERE sc_acc.schedule_id = s.id AND sc_acc.status = 'attend'
          )
        )
    `.compile(db)
  );
  return result.rows.map(rowToCandidate);
}

interface ParentRow {
  id: string;
  at_start: Date;
  duration_seconds: string | number;
  recurrence_rule: string;
  recurrence_exdates: Date[] | null;
  link_id: string;
}

interface OverrideRow {
  link_id: string;
  occurrence: string;
  at_start: Date;
  at_end: Date;
}

async function fetchAndExpandRecurringCandidates(
  db: Kysely<DB>,
  logger: Logger,
  userIds: string[],
  lookbackMs: number,
  now: Date
): Promise<EventCandidate[]> {
  const windowStart = new Date(now.getTime() - lookbackMs);

  // Parent series. Filter to link-only and to series that overlap the
  // window. The check `lower(s.at) <= now AND (upper_inf OR upper >= windowStart)`
  // is "the series may have an occurrence ending in the window"; JS
  // expansion does the precise math.
  const parentsResult = await db.executeQuery(
    sql<ParentRow>`
      SELECT
        s.id,
        lower(s.at) AS at_start,
        EXTRACT(EPOCH FROM s.duration)::float8 AS duration_seconds,
        s.recurrence_rule,
        s.recurrence_exdates,
        s.link_id
      FROM public.schedule s
      WHERE s.recurrence_rule IS NOT NULL
        AND s.occurrence IS NULL
        AND s.archived_at IS NULL
        AND s.link_id IS NOT NULL
        AND s.at IS NOT NULL
        AND lower(s.at) <= ${now}
        AND (upper_inf(s.at) OR upper(s.at) >= ${windowStart})
    `.compile(db)
  );
  if (parentsResult.rows.length === 0) return [];
  const parents = parentsResult.rows;

  // Per-link priority filings for the users we're processing. One round-
  // trip up front avoids fanning out per-occurrence inside the inner
  // INSERT (the old shape's `candidate_users` CTE). With this map, each
  // occurrence becomes O(1) lookups in JS.
  const linkIds = Array.from(new Set(parents.map((p) => p.link_id)));
  const linkFilingsResult = await db.executeQuery(
    sql<{ link_id: string; user_id: string; priority_id: string }>`
      SELECT l.id AS link_id, tp.user_id, tp.priority_id
      FROM public.link l
        JOIN public.thread t ON t.id = l.thread_id
        JOIN public.thread_priority tp ON tp.thread_id = t.id
      WHERE l.id = ANY(${linkIds}::uuid[])
        AND t.archived_at IS NULL
        AND tp.user_id = ANY(${userIds}::uuid[])
    `.compile(db)
  );
  // link_id -> [{user_id, priority_id}, ...]
  const filingsByLink = new Map<string, { user_id: string; priority_id: string }[]>();
  for (const r of linkFilingsResult.rows) {
    const list = filingsByLink.get(r.link_id) ?? [];
    list.push({ user_id: r.user_id, priority_id: r.priority_id });
    filingsByLink.set(r.link_id, list);
  }
  if (filingsByLink.size === 0) return [];

  // RSVP eligibility per (schedule, user). One query keyed on the parent
  // series IDs and the active users — returns the user IDs whose RSVP
  // gate passes for each schedule.
  const parentIds = parents.map((p) => p.id);
  const rsvpResult = await db.executeQuery(
    sql<{ schedule_id: string; user_id: string }>`
      WITH per_user AS (
        SELECT
          s.id AS schedule_id,
          uc.user_id,
          BOOL_OR(sc.status = 'attend') AS has_attend,
          BOOL_OR(sc.status = 'skip') AS has_skip
        FROM public.schedule s
          JOIN public.schedule_contact sc ON sc.schedule_id = s.id
          JOIN public.user_contact uc
            ON uc.contact_id = sc.contact_id AND uc.linked = TRUE
        WHERE s.id = ANY(${parentIds}::uuid[])
          AND uc.user_id = ANY(${userIds}::uuid[])
        GROUP BY s.id, uc.user_id
      )
      SELECT schedule_id, user_id FROM per_user
      WHERE has_attend OR NOT COALESCE(has_skip, FALSE)
    `.compile(db)
  );
  // schedule_id -> Set<user_id>
  const rsvpBySchedule = new Map<string, Set<string>>();
  for (const r of rsvpResult.rows) {
    const set = rsvpBySchedule.get(r.schedule_id) ?? new Set<string>();
    set.add(r.user_id);
    rsvpBySchedule.set(r.schedule_id, set);
  }

  // Per-user tracking_paused_at lookup so we can filter occurrences whose
  // end falls inside the paused window.
  const settingsResult = await db.executeQuery(
    sql<{ user_id: string; tracking_paused_at: Date | null }>`
      SELECT user_id, tracking_paused_at
      FROM public.user_settings
      WHERE user_id = ANY(${userIds}::uuid[])
    `.compile(db)
  );
  const pausedByUser = new Map<string, Date | null>();
  for (const r of settingsResult.rows) {
    pausedByUser.set(r.user_id, r.tracking_paused_at);
  }

  // Overrides for the parent series. The schema constraint
  // `schedule_no_archived_occurrence` guarantees overrides aren't archived.
  const overridesResult = await db.executeQuery(
    sql<OverrideRow>`
      SELECT
        s.link_id,
        s.occurrence,
        lower(s.at) AS at_start,
        upper(s.at) AS at_end
      FROM public.schedule s
      WHERE s.occurrence IS NOT NULL
        AND s.link_id IS NOT NULL
        AND s.at IS NOT NULL
        AND s.link_id = ANY(${linkIds}::uuid[])
    `.compile(db)
  );
  const overridesByLink = new Map<string, ScheduleOverride[]>();
  for (const o of overridesResult.rows) {
    const list = overridesByLink.get(o.link_id) ?? [];
    list.push({
      occurrence: o.occurrence,
      atStart: o.at_start,
      atEnd: o.at_end,
    });
    overridesByLink.set(o.link_id, list);
  }

  // Expand each parent in JS, then fan out to (user, occurrence) candidates.
  const candidates: EventCandidate[] = [];
  for (const parent of parents) {
    const filings = filingsByLink.get(parent.link_id);
    if (!filings || filings.length === 0) continue;

    const durationSeconds =
      typeof parent.duration_seconds === "string"
        ? parseFloat(parent.duration_seconds)
        : parent.duration_seconds;
    if (!durationSeconds || durationSeconds <= 0) continue;

    const parentEntity: RecurringScheduleParent = {
      id: parent.id,
      atStart: parent.at_start,
      durationSeconds,
      recurrenceRule: parent.recurrence_rule,
      recurrenceExdates: parent.recurrence_exdates ?? [],
    };
    const overrides = overridesByLink.get(parent.link_id) ?? [];

    let occurrences: ExpandedOccurrence[];
    try {
      occurrences = expandRecurrenceForLookback(
        parentEntity,
        overrides,
        now,
        lookbackMs
      );
    } catch (error) {
      logger.warn("Failed to expand recurring schedule", {
        schedule_id: parent.id,
        error_message: error instanceof Error ? error.message : String(error),
      });
      continue;
    }
    if (occurrences.length === 0) continue;

    const rsvpUsers = rsvpBySchedule.get(parent.id);
    if (!rsvpUsers || rsvpUsers.size === 0) continue;

    for (const occ of occurrences) {
      for (const filing of filings) {
        if (!rsvpUsers.has(filing.user_id)) continue;
        const paused = pausedByUser.get(filing.user_id);
        if (paused !== null && paused !== undefined && occ.atEnd >= paused) {
          continue;
        }
        candidates.push({
          userId: filing.user_id,
          scheduleId: parent.id,
          occurrenceAt: occ.occurrenceAt,
          priorityId: filing.priority_id,
          atStart: occ.atStart,
          atEnd: occ.atEnd,
        });
      }
    }
  }
  return candidates;
}

function rowToCandidate(r: CandidateRow): EventCandidate {
  return {
    userId: r.user_id,
    scheduleId: r.schedule_id,
    occurrenceAt: r.occurrence_at,
    priorityId: r.priority_id,
    atStart: r.at_start,
    atEnd: r.at_end,
  };
}

interface BlockerRow {
  user_id: string;
  at_start: Date;
  at_end: Date;
  schedule_id: string | null;
  occurrence_at: Date | null;
  source: string;
}

async function fetchBlockers(
  db: Kysely<DB>,
  userIds: string[],
  candidates: readonly EventCandidate[]
): Promise<BlockerRange[]> {
  let minStart = candidates[0].atStart;
  let maxEnd = candidates[0].atEnd;
  for (const c of candidates) {
    if (c.atStart < minStart) minStart = c.atStart;
    if (c.atEnd > maxEnd) maxEnd = c.atEnd;
  }

  const result = await db.executeQuery(
    sql<BlockerRow>`
      SELECT
        user_id,
        lower(at) AS at_start,
        upper(at) AS at_end,
        schedule_id,
        occurrence_at,
        source
      FROM public.session
      WHERE archived_at IS NULL
        AND user_id = ANY(${userIds}::uuid[])
        AND at && tstzrange(${minStart}, ${maxEnd}, '[]')
    `.compile(db)
  );
  return result.rows.map((r) => ({
    userId: r.user_id,
    start: r.at_start,
    end: r.at_end,
    scheduleId: r.schedule_id,
    occurrenceAt: r.occurrence_at,
    source: r.source,
  }));
}

async function upsertResolved(
  db: Kysely<DB>,
  resolved: readonly ResolvedSession[]
): Promise<{ inserted: number; updated: number }> {
  const values = sql.join(
    resolved.map(
      (r) => sql`(
        ${r.userId}::uuid,
        ${r.priorityId}::uuid,
        tstzrange(${r.atStart.toISOString()}::timestamptz, ${r.atEnd.toISOString()}::timestamptz, '[)'),
        ${r.scheduleId}::uuid,
        ${r.occurrenceAt.toISOString()}::timestamptz
      )`
    ),
    sql`, `
  );

  const result = await db.executeQuery(
    sql<{ action: "inserted" | "updated" }>`
      WITH input (user_id, priority_id, at, schedule_id, occurrence_at) AS (
        VALUES ${values}
      ),
      upserted AS (
        INSERT INTO public.session
          (user_id, priority_id, at, source, schedule_id, occurrence_at, precedence, updated_by)
        SELECT
          i.user_id, i.priority_id, i.at, 'event',
          i.schedule_id, i.occurrence_at, 0, 0
        FROM input i
        ON CONFLICT (user_id, schedule_id, occurrence_at)
          WHERE schedule_id IS NOT NULL AND archived_at IS NULL
        DO UPDATE SET
          at = EXCLUDED.at,
          priority_id = EXCLUDED.priority_id,
          updated_by = 0
          WHERE session.at <> EXCLUDED.at
            OR session.priority_id <> EXCLUDED.priority_id
        RETURNING (xmax = 0) AS inserted
      )
      SELECT CASE WHEN inserted THEN 'inserted' ELSE 'updated' END AS action
      FROM upserted
    `.compile(db)
  );

  let inserted = 0;
  let updated = 0;
  for (const r of result.rows) {
    if (r.action === "inserted") inserted++;
    else updated++;
  }
  return { inserted, updated };
}
