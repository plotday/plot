-- priority_block — temporal overrides for the order value of a priority.
--
-- A row says "from `effective_at` onwards, this priority sorts at
-- `order_value`". Used to render priority blocks in the agenda. Multiple
-- rows per priority form a timeline; the latest row whose
-- `effective_at` <= moment determines the order at that moment.
--
-- When the user reorders a block in the do-now slot, all rows for the
-- priority with effective_at < now are deleted and a fresh row is
-- inserted at effective_at = now. When the user reorders a block in a
-- future gap, a row is upserted at effective_at = gap.start so the new
-- order takes effect from that moment forward.
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
    -- Inclusive lower bound from which order_value applies for the
    -- priority. Unique per priority (a priority cannot have two
    -- competing orders at the same instant).
    "effective_at" timestamp with time zone NOT NULL,
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
