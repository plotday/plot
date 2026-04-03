CREATE TABLE "public"."schedule" (
    "id" uuid PRIMARY KEY DEFAULT uuidv7 () NOT NULL,
    "created_at" timestamptz NOT NULL DEFAULT now(),
    "updated_at" timestamptz NOT NULL DEFAULT now(),
    "archived_at" timestamptz,
    "user_id" uuid REFERENCES public."user" ON DELETE CASCADE,
    "order" double precision,
    "at" tstzrange,
    "on" daterange,
    "recurrence_rule" text,
    "duration" interval,
    "recurrence_exdates" timestamptz[],
    "occurrence" text,
    "reason" text,
    "thread_id" uuid REFERENCES public.thread (id) ON DELETE CASCADE,
    "link_id" uuid REFERENCES public.link (id) ON DELETE CASCADE,
    "outstanding_tasks" boolean NOT NULL DEFAULT FALSE
);

-- Recurring schedules:
--   recurrence_rule + duration define the pattern.
--   recurrence_exdates lists dates excluded from expansion (cancelled/deleted occurrences).
--   Occurrence schedule rows (occurrence IS NOT NULL) are for overrides only
--   (time changes, RSVP differences). Deleted occurrences do NOT get a schedule row —
--   they are represented solely via recurrence_exdates on the base schedule.

-- Exactly one of at/on must be set, or both null for per-user undated schedules
ALTER TABLE "public"."schedule"
    ADD CONSTRAINT schedule_at_xor_on CHECK (
        (at IS NOT NULL AND "on" IS NULL) OR
        (at IS NULL AND "on" IS NOT NULL) OR
        (at IS NULL AND "on" IS NULL AND user_id IS NOT NULL)
    );

-- order requires user_id and vice versa
ALTER TABLE "public"."schedule"
    ADD CONSTRAINT schedule_order_user CHECK (("user_id" IS NULL AND "order" IS NULL) OR ("user_id" IS NOT NULL AND "order" IS NOT NULL));

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

-- One per-user schedule per thread (non-occurrence only)
CREATE UNIQUE INDEX schedule_thread_user_unique ON "public"."schedule" ("thread_id", "user_id")
WHERE
    "user_id" IS NOT NULL
    AND occurrence IS NULL;

-- One per-user schedule per link (non-occurrence only)
CREATE UNIQUE INDEX schedule_link_user_unique ON "public"."schedule" ("link_id", "user_id")
WHERE
    "user_id" IS NOT NULL
    AND occurrence IS NULL;

-- One shared base schedule per link (non-occurrence, shared only)
CREATE UNIQUE INDEX schedule_link_shared_base_unique ON "public"."schedule" ("link_id")
WHERE
    "user_id" IS NULL
    AND occurrence IS NULL;

-- One shared base schedule per thread (non-occurrence, shared only)
CREATE UNIQUE INDEX schedule_thread_shared_base_unique ON "public"."schedule" ("thread_id")
WHERE
    "user_id" IS NULL
    AND occurrence IS NULL;

CREATE INDEX idx_schedule_thread_id ON "public"."schedule" ("thread_id");

CREATE INDEX idx_schedule_link_id ON "public"."schedule" ("link_id");

CREATE INDEX idx_schedule_at ON "public"."schedule" USING gist ("at");

CREATE INDEX idx_schedule_on ON "public"."schedule" USING gist ("on");

CREATE INDEX idx_schedule_user_id ON "public"."schedule" ("user_id")
WHERE
    "user_id" IS NOT NULL;

CREATE INDEX idx_schedule_updated_at ON "public"."schedule" ("updated_at");

CREATE TRIGGER set_schedule_updated_at
    BEFORE INSERT OR UPDATE ON "public"."schedule"
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

CREATE TRIGGER set_schedule_created_at
    BEFORE INSERT ON "public"."schedule"
    FOR EACH ROW
    EXECUTE FUNCTION set_created_at ();
