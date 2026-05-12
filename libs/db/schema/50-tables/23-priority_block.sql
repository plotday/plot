-- priority_block — current and future-planned settings for a priority.
--
-- A row says "from `effective_at` onwards, this priority's order is
-- `order_value` and its pending duration is `duration`". The latest row
-- whose `effective_at` <= moment determines current values.
--
-- Two conventions for `effective_at`:
--   * `'epoch'` (1970-01-01 UTC) — the canonical "current" row. Adjusting
--     a priority's order or pending duration upserts onto this single
--     sentinel row keyed by `(priority_id, effective_at)`. There is no
--     timeline of past adjustments — the latest write is the truth.
--   * Future timestamp — a planned change that becomes current when its
--     `effective_at` arrives (the resolver naturally picks it up).
--
-- Falls back to priority.created_at-based ordering when no rows exist.
CREATE TABLE "public"."priority_block" (
    "id" uuid PRIMARY KEY DEFAULT uuidv7 () NOT NULL,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    "created_by" uuid NOT NULL REFERENCES public."user" ON DELETE CASCADE,
    -- Per-user owner. Denormalized from priority.user_id so sync queries
    -- can filter without a join. Defaulted by trigger from the row's
    -- referenced priority (see default_priority_block_user_id below).
    "user_id" uuid NOT NULL REFERENCES public."user" ON DELETE CASCADE,
    "priority_id" uuid NOT NULL REFERENCES public."priority" ON DELETE CASCADE,
    "order_value" double precision NOT NULL,
    -- Inclusive lower bound from which this row's values apply for the
    -- priority. Use `'epoch'` (1970-01-01 UTC) for the canonical
    -- "current" row, or a future timestamp for a planned change. Unique
    -- per priority via idx_priority_block_priority_effective below.
    "effective_at" timestamp with time zone NOT NULL,
    -- Pending planned time for the priority as of `effective_at`. NULL
    -- means "no pending duration" (priority drops out of the agenda
    -- cascade). Updated by:
    --   * user +/- on a block (upserts the epoch row),
    --   * the event finalizer cron after recording an event session,
    --   * the client on active-session close (writing back consumed time).
    "duration" interval,
    "archived_at" timestamp with time zone,
    "updated_by" integer NOT NULL DEFAULT 0,
    "seq" xid8 NOT NULL DEFAULT pg_current_xact_id()
);

CREATE UNIQUE INDEX idx_priority_block_priority_effective
    ON "public"."priority_block" ("priority_id", "effective_at");

CREATE INDEX idx_priority_block_user_id
    ON "public"."priority_block" ("user_id");

CREATE INDEX idx_priority_block_priority_effective_desc
    ON "public"."priority_block" ("priority_id", "effective_at" DESC);

CREATE INDEX idx_priority_block_seq
    ON "public"."priority_block" ("seq");

CREATE TRIGGER set_priority_block_updated_at
    BEFORE INSERT OR UPDATE ON "public"."priority_block"
    FOR EACH ROW
    EXECUTE FUNCTION update_seq_and_updated_at ();

CREATE TRIGGER set_priority_block_created_at
    BEFORE INSERT ON "public"."priority_block"
    FOR EACH ROW
    EXECUTE FUNCTION set_created_at ();

CREATE TRIGGER set_priority_block_created_by
    BEFORE INSERT ON "public"."priority_block"
    FOR EACH ROW
    EXECUTE FUNCTION update_created_by ();

-- Default priority_block.user_id to the priority's owner when the caller
-- doesn't set it. Mirrors default_priority_user_id; runs BEFORE INSERT
-- so existing upsert flows that don't pass user_id still satisfy the
-- NOT NULL constraint.
CREATE OR REPLACE FUNCTION public.default_priority_block_user_id ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF NEW.user_id IS NULL THEN
        SELECT user_id INTO NEW.user_id
        FROM priority
        WHERE id = NEW.priority_id;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER default_priority_block_user_id
    BEFORE INSERT ON "public"."priority_block"
    FOR EACH ROW
    EXECUTE FUNCTION public.default_priority_block_user_id ();
