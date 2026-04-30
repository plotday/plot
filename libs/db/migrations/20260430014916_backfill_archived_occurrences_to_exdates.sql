-- Backfill: fold any existing archived occurrence schedule rows into their
-- parent schedule's recurrence_exdates, then delete them. The runtime
-- already does this translation for new writes (workers/api/src/twist/
-- tools/plot/schedule.ts createLinkSchedules); this migration cleans up
-- any rows that pre-date the runtime translation, so the new CHECK
-- constraint at the bottom can be enforced.

-- Link-scoped: append archived child occurrence dates onto the parent
-- recurring schedule's exdates list (deduped, sorted, NOT NULL).
UPDATE "public"."schedule" p
SET recurrence_exdates = (
    SELECT ARRAY(
        SELECT DISTINCT v
        FROM unnest(
            COALESCE(p.recurrence_exdates, ARRAY[]::timestamptz[])
            || ARRAY(
                SELECT (s.occurrence::timestamptz)
                FROM "public"."schedule" s
                WHERE s.link_id = p.link_id
                  AND s.occurrence IS NOT NULL
                  AND s.archived_at IS NOT NULL
            )
        ) AS v
        WHERE v IS NOT NULL
        ORDER BY v
    )
)
WHERE p.link_id IS NOT NULL
  AND p.user_id IS NULL
  AND p.occurrence IS NULL
  AND p.recurrence_rule IS NOT NULL
  AND EXISTS (
      SELECT 1 FROM "public"."schedule" s
      WHERE s.link_id = p.link_id
        AND s.occurrence IS NOT NULL
        AND s.archived_at IS NOT NULL
  );

-- Thread-scoped: same fold for schedules attached directly to a thread.
UPDATE "public"."schedule" p
SET recurrence_exdates = (
    SELECT ARRAY(
        SELECT DISTINCT v
        FROM unnest(
            COALESCE(p.recurrence_exdates, ARRAY[]::timestamptz[])
            || ARRAY(
                SELECT (s.occurrence::timestamptz)
                FROM "public"."schedule" s
                WHERE s.thread_id = p.thread_id
                  AND s.occurrence IS NOT NULL
                  AND s.archived_at IS NOT NULL
            )
        ) AS v
        WHERE v IS NOT NULL
        ORDER BY v
    )
)
WHERE p.thread_id IS NOT NULL
  AND p.user_id IS NULL
  AND p.occurrence IS NULL
  AND p.recurrence_rule IS NOT NULL
  AND EXISTS (
      SELECT 1 FROM "public"."schedule" s
      WHERE s.thread_id = p.thread_id
        AND s.occurrence IS NOT NULL
        AND s.archived_at IS NOT NULL
  );

-- Delete the archived occurrence rows now that their dates are captured in
-- parent exdates (or are orphans without a recurring parent — either way,
-- they should not exist under the new constraint).
DELETE FROM "public"."schedule"
WHERE occurrence IS NOT NULL
  AND archived_at IS NOT NULL;

-- Modify "schedule" table
ALTER TABLE "public"."schedule" ADD CONSTRAINT "schedule_no_archived_occurrence" CHECK (NOT ((occurrence IS NOT NULL) AND (archived_at IS NOT NULL)));
