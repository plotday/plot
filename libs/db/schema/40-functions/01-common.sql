CREATE OR REPLACE FUNCTION update_updated_at ()
    RETURNS TRIGGER
    AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$
LANGUAGE plpgsql;

-- For synced tables: writes both `updated_at` (kept for backwards compat with
-- old clients during expand-contract rollout) and `seq` (the new monotonic
-- sync cursor). `seq` is `pg_current_xact_id()`, the writing transaction's
-- xid8. Sync queries gate on `seq < pg_snapshot_xmin(...)` to avoid the
-- long-transaction cursor-skip race that `now()` alone has — see
-- workers/api/src/app/sync/helpers.ts (seqSinceCursor). Every table whose
-- BEFORE INSERT/UPDATE trigger runs this function MUST declare
-- `seq xid8 NOT NULL DEFAULT pg_current_xact_id()`.
CREATE OR REPLACE FUNCTION update_seq_and_updated_at ()
    RETURNS TRIGGER
    AS $$
BEGIN
    -- Activity-only maintenance (thread.activity_base / thread_priority.activity_at)
    -- sets plot.skip_activity_seq = 'on' so these writes do NOT advance the sync
    -- cursor: the Flutter app strips activity_at and recomputes feed ordering
    -- locally, so re-emitting the row would be wasted sync + index churn. The
    -- flag is transaction-local and defaults unset, so every other writer is
    -- unaffected. Only meaningful on UPDATE (INSERT has no OLD to preserve).
    IF TG_OP = 'UPDATE'
       AND current_setting('plot.skip_activity_seq', TRUE) = 'on' THEN
        NEW.updated_at = OLD.updated_at;
        NEW.seq = OLD.seq;
        RETURN NEW;
    END IF;
    NEW.updated_at = now();
    NEW.seq = pg_current_xact_id();
    RETURN NEW;
END;
$$
LANGUAGE plpgsql;

-- thread_priority-specific variant of update_seq_and_updated_at. It keeps that
-- function's plot.skip_activity_seq suppression (the activity_at fan-out) AND
-- adds a second suppression: a write that changes ONLY the internal classify_at
-- column — the classify worker's "same result" settle (SET classify_at = NULL)
-- and the reclassify / channel-default / topic markers (SET classify_at = now())
-- — must NOT advance the sync cursor. classify_at is never surfaced by any
-- user.* view, so a bumped seq would make the seq-cursor candidate prefilter
-- (idx_thread_priority_user_seq) re-emit the row through the expensive
-- user.thread view for no visible change. Preserve the prior seq/updated_at in
-- both cases; bump as usual otherwise (and on INSERT). Pairs with
-- sync_user_for_thread_priority_update (the AFTER user_sync guard). Comparing
-- to_jsonb(NEW) vs to_jsonb(OLD) with classify_at/seq/updated_at removed is
-- self-maintaining and safe-by-default: a future column (e.g. activity_at) is
-- compared unless explicitly excluded, so a real, non-suppressed change to it
-- still bumps the cursor.
CREATE OR REPLACE FUNCTION thread_priority_seq_and_updated_at ()
    RETURNS TRIGGER
    AS $$
BEGIN
    -- Activity-only maintenance suppresses the cursor (mirrors
    -- update_seq_and_updated_at; the activity_at fan-out sets the flag).
    IF TG_OP = 'UPDATE'
       AND current_setting('plot.skip_activity_seq', TRUE) = 'on' THEN
        NEW.updated_at = OLD.updated_at;
        NEW.seq = OLD.seq;
        RETURN NEW;
    END IF;
    -- classify_at-only write: internal, no view effect — stay quiet.
    IF TG_OP = 'UPDATE'
       AND to_jsonb(NEW) - 'classify_at' - 'seq' - 'updated_at'
           IS NOT DISTINCT FROM to_jsonb(OLD) - 'classify_at' - 'seq' - 'updated_at' THEN
        NEW.updated_at = OLD.updated_at;
        NEW.seq = OLD.seq;
        RETURN NEW;
    END IF;
    NEW.updated_at = now();
    NEW.seq = pg_current_xact_id();
    RETURN NEW;
END;
$$
LANGUAGE plpgsql;

-- Same as update_seq_and_updated_at, for tables that don't have an updated_at
-- column (e.g. twist_instance_connection — driven by per-field lifecycle
-- timestamps). Only writes seq.
CREATE OR REPLACE FUNCTION update_seq ()
    RETURNS TRIGGER
    AS $$
BEGIN
    NEW.seq = pg_current_xact_id();
    RETURN NEW;
END;
$$
LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION public.set_created_at ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $function$
BEGIN
    NEW.created_at = now();
    RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION update_created_by ()
    RETURNS TRIGGER
    AS $$
BEGIN
    NEW.created_by = NEW.created_by;
    RETURN NEW;
END;
$$
LANGUAGE plpgsql;

