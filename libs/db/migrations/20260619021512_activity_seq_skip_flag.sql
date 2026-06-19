-- Modify "update_seq_and_updated_at" function
CREATE OR REPLACE FUNCTION "public"."update_seq_and_updated_at" () RETURNS trigger LANGUAGE plpgsql AS $$
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
$$;
