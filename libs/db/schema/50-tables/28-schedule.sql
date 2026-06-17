-- Shared & link-attached schedules. Per-user todo state (action, order, the
-- per-user "do on this date" intent) lives on `thread_state`; this table is
-- now purely for shared/link-scoped temporal data (calendar events,
-- connector-emitted occurrences, shared thread base schedules).
CREATE TABLE "public"."schedule" (
    "id" uuid PRIMARY KEY DEFAULT uuidv7 () NOT NULL,
    "created_at" timestamptz NOT NULL DEFAULT now(),
    "updated_at" timestamptz NOT NULL DEFAULT now(),
    "archived_at" timestamptz,
    "at" tstzrange,
    "on" daterange,
    "recurrence_rule" text,
    "duration" interval,
    "recurrence_exdates" timestamptz[],
    "occurrence" text,
    "reason" text,
    "thread_id" uuid REFERENCES public.thread (id) ON DELETE CASCADE,
    "link_id" uuid REFERENCES public.link (id) ON DELETE CASCADE,
    "seq" xid8 NOT NULL DEFAULT pg_current_xact_id()
);

-- Recurring schedules:
--   recurrence_rule + duration define the pattern.
--   recurrence_exdates lists dates excluded from expansion (cancelled/deleted occurrences).
--   Occurrence schedule rows (occurrence IS NOT NULL) are for overrides only
--   (time changes, RSVP differences). Deleted occurrences do NOT get a schedule row —
--   they are represented solely via recurrence_exdates on the base schedule.

-- Exactly one of at/on must be set (no schedules without timing now that
-- per-user undated "todo" intent lives on thread_state instead).
ALTER TABLE "public"."schedule"
    ADD CONSTRAINT schedule_at_xor_on CHECK (
        (at IS NOT NULL AND "on" IS NULL) OR
        (at IS NULL AND "on" IS NOT NULL)
    );

-- duration requires recurrence_rule and vice versa (unless occurrence is set — occurrence exceptions can override duration)
ALTER TABLE "public"."schedule"
    ADD CONSTRAINT schedule_recurrence_duration CHECK (
        occurrence IS NOT NULL OR
        (recurrence_rule IS NULL AND duration IS NULL) OR
        (recurrence_rule IS NOT NULL AND duration IS NOT NULL)
    );

-- Schedule reason tracks why item is on agenda (null = legacy/unknown)
ALTER TABLE "public"."schedule"
    ADD CONSTRAINT schedule_reason_check CHECK (reason IS NULL OR reason IN ('unread', 'task', 'add', 'schedule'));

-- Cannot have both recurrence_rule and occurrence (occurrence is an exception to a recurrence)
ALTER TABLE "public"."schedule"
    ADD CONSTRAINT schedule_recurrence_xor_occurrence CHECK (NOT (recurrence_rule IS NOT NULL AND occurrence IS NOT NULL));

-- Cancelled occurrences are represented via recurrence_exdates on the base
-- schedule, never as separate archived schedule rows. The runtime layer in
-- workers/api/src/twist/tools/plot/schedule.ts (createLinkSchedules)
-- translates connector-emitted `archived: true` occurrences into exdate
-- additions on the parent. This constraint enforces the design at the
-- storage layer so legacy or buggy paths cannot reintroduce the divergent
-- representation.
ALTER TABLE "public"."schedule"
    ADD CONSTRAINT schedule_no_archived_occurrence CHECK (NOT (occurrence IS NOT NULL AND archived_at IS NOT NULL));

-- Exactly one of thread_id/link_id must be set
ALTER TABLE "public"."schedule"
    ADD CONSTRAINT schedule_thread_xor_link CHECK (
        (thread_id IS NOT NULL AND link_id IS NULL) OR (thread_id IS NULL AND link_id IS NOT NULL)
    );

-- One exception per occurrence per thread
CREATE UNIQUE INDEX schedule_thread_occurrence_unique ON "public"."schedule" ("thread_id", "occurrence")
WHERE
    occurrence IS NOT NULL;

-- One exception per occurrence per link
CREATE UNIQUE INDEX schedule_link_occurrence_unique ON "public"."schedule" ("link_id", "occurrence")
WHERE
    occurrence IS NOT NULL;

-- One shared base schedule per link (non-occurrence)
CREATE UNIQUE INDEX schedule_link_base_unique ON "public"."schedule" ("link_id")
WHERE
    occurrence IS NULL;

-- One shared base schedule per thread (non-occurrence)
CREATE UNIQUE INDEX schedule_thread_base_unique ON "public"."schedule" ("thread_id")
WHERE
    occurrence IS NULL;

CREATE INDEX idx_schedule_thread_id ON "public"."schedule" ("thread_id");

CREATE INDEX idx_schedule_link_id ON "public"."schedule" ("link_id");

CREATE INDEX idx_schedule_at ON "public"."schedule" USING gist ("at");

-- NOTE: no GiST index on the all-day `on` daterange. Agenda lookups join
-- schedule by thread_id/link_id and read lower()/upper() of `on` per row; the
-- range-overlap query that this GiST would serve saw only 2 planner uses in 4
-- months of prod, versus GiST maintenance on every one of ~82k/yr writes to
-- this table (42% of which would otherwise be HOT). Dropped during index
-- cleanup. idx_schedule_at keeps the heavily-used `at` (tstzrange) GiST.

CREATE INDEX idx_schedule_updated_at ON "public"."schedule" ("updated_at");

CREATE INDEX idx_schedule_seq ON "public"."schedule" ("seq");

CREATE TRIGGER set_schedule_updated_at
    BEFORE INSERT OR UPDATE ON "public"."schedule"
    FOR EACH ROW
    EXECUTE FUNCTION update_seq_and_updated_at ();

CREATE TRIGGER set_schedule_created_at
    BEFORE INSERT ON "public"."schedule"
    FOR EACH ROW
    EXECUTE FUNCTION set_created_at ();
