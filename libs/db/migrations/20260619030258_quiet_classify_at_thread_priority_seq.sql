-- Create "thread_priority_seq_and_updated_at" function
CREATE FUNCTION "public"."thread_priority_seq_and_updated_at" () RETURNS trigger LANGUAGE plpgsql AS $$
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
$$;
-- Modify "set_thread_priority_updated_at" trigger
CREATE OR REPLACE TRIGGER "set_thread_priority_updated_at" BEFORE INSERT OR UPDATE ON "public"."thread_priority" FOR EACH ROW EXECUTE FUNCTION "public"."thread_priority_seq_and_updated_at"();
