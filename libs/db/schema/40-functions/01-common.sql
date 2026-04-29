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

