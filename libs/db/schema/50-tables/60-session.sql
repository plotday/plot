CREATE OR REPLACE FUNCTION public.is_finite (test tstzrange)
    RETURNS boolean
    LANGUAGE 'plpgsql'
    IMMUTABLE
    AS $$
BEGIN
    RETURN NOT (lower_inf(test)
        OR upper_inf(test));
END;
$$;

CREATE TABLE "public"."session" (
    "id" uuid PRIMARY KEY DEFAULT uuidv7 () NOT NULL,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    "archived_at" timestamp with time zone,
    "user_id" uuid NOT NULL REFERENCES public."user" ON DELETE CASCADE,
    "priority_id" uuid REFERENCES priority ON DELETE SET NULL,
    "at" tstzrange NOT NULL CHECK (NOT (lower_inf(at) OR upper_inf(at))),
    "precedence" smallint NOT NULL DEFAULT 0,
    "pomodoro" smallint CHECK (pomodoro IS NULL OR pomodoro > 0),
    "pomodoro_at" timestamp with time zone,
    -- Provenance of the time recorded by this session row:
    --   'active' (default) — the client's foreground tracker via
    --       Session.resume; the user was focused on this priority.
    --   'event'  — server-finalized chunk for a scheduled event the user
    --       attended (or didn't decline). Tied to (schedule_id, occurrence_at)
    --       for idempotency.
    --   'manual' — manual ±15m adjustment from the time-tracking modal.
    --   'skip'   — client-written marker covering the part of a scheduled
    --       event the user opted out of crediting (e.g. they stopped the
    --       in-progress event timer early). Carries (schedule_id,
    --       occurrence_at) so the event-finalizer cron picks it up as a
    --       blocker, naturally clamping the resulting 'event' row to the
    --       time before the stop. Not summed into priority time totals.
    "source" text NOT NULL DEFAULT 'active' CHECK ("source" IN ('active', 'event', 'manual', 'skip')),
    -- For 'event' rows: the scheduled event this session was finalized
    -- from. NULL for 'active'/'manual' rows. ON DELETE SET NULL so that
    -- deleting a calendar event keeps the recorded time but breaks the
    -- idempotency link (no re-creation possible).
    "schedule_id" uuid REFERENCES public."schedule" (id) ON DELETE SET NULL,
    -- For 'event' rows on a recurring schedule: the occurrence start.
    -- Combined with schedule_id, makes the finalizer cron idempotent
    -- (see idx_session_schedule_occurrence below).
    "occurrence_at" timestamp with time zone,
    -- True when the user started this pomodoro themselves (pressed
    -- Start, or adjusted a running auto-start via Add time). False when
    -- the client started it implicitly as a 5-minute distraction handoff
    -- after the user switched priorities mid-session. The resume path
    -- only revives sessions with `explicit = true`; auto-starts are
    -- one-shot reminders.
    "explicit" boolean NOT NULL DEFAULT true,
    "updated_by" integer NOT NULL DEFAULT 0,
    "seq" xid8 NOT NULL DEFAULT pg_current_xact_id()
);

CREATE INDEX idx_session_seq ON "public"."session" ("seq");

CREATE INDEX session_at_idx ON "session" USING spgist (at);

-- Index for foreign key performance
CREATE INDEX idx_session_user_id ON "public"."session" (user_id)
WHERE
    archived_at IS NULL;

-- Composite index serving /sync/sessions: WHERE user_id = $1 AND seq IN [a, b)
-- ORDER BY seq, id LIMIT N. Without this, the seq-cursor pull is a Seq Scan +
-- Sort even though both idx_session_user_id and idx_session_seq exist
-- individually (neither covers the combined predicate + ordering).
CREATE INDEX idx_session_user_seq ON "public"."session" ("user_id", "seq", "id");

-- Idempotency key for the event-finalizer cron: at most one non-archived
-- 'event' session per (user, schedule, occurrence). Partial so it does
-- not constrain 'active'/'manual' rows which have schedule_id IS NULL,
-- and so 'skip' markers (which intentionally share (schedule_id,
-- occurrence_at) with a finalized 'event' row) coexist with the cron's
-- own writes without colliding.
CREATE UNIQUE INDEX idx_session_schedule_occurrence
    ON "public"."session" ("user_id", "schedule_id", "occurrence_at")
    WHERE
        "schedule_id" IS NOT NULL
        AND "archived_at" IS NULL
        AND "source" = 'event';

CREATE TRIGGER set_session_updated_at
    BEFORE INSERT OR UPDATE ON "public"."session"
    FOR EACH ROW
    EXECUTE FUNCTION update_seq_and_updated_at ();

CREATE TRIGGER set_session_created_at
    BEFORE INSERT ON "public"."session"
    FOR EACH ROW
    EXECUTE FUNCTION set_created_at ();

