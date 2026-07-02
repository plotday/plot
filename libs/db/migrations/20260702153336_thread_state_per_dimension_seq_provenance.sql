-- Modify "thread_state" table
ALTER TABLE "public"."thread_state" ADD COLUMN "read_seq" xid8 NULL, ADD COLUMN "todo_seq" xid8 NULL, ADD COLUMN "read_source" uuid NULL, ADD COLUMN "todo_source" uuid NULL;
-- Create "thread_state_seq_and_updated_at" function
CREATE FUNCTION "public"."thread_state_seq_and_updated_at" () RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    v_source uuid;
BEGIN
    v_source := NULLIF(current_setting('plot.write_source_twist_instance', TRUE), '')::uuid;

    -- Activity-only maintenance suppresses the cursor (mirrors
    -- update_seq_and_updated_at). Preserve ALL per-dimension bookkeeping too.
    IF TG_OP = 'UPDATE'
       AND current_setting('plot.skip_activity_seq', TRUE) = 'on' THEN
        NEW.updated_at = OLD.updated_at;
        NEW.seq = OLD.seq;
        NEW.read_seq = OLD.read_seq;
        NEW.read_source = OLD.read_source;
        NEW.todo_seq = OLD.todo_seq;
        NEW.todo_source = OLD.todo_source;
        RETURN NEW;
    END IF;

    NEW.updated_at = now();
    NEW.seq = pg_current_xact_id();

    IF TG_OP = 'UPDATE' THEN
        IF NEW.read_at IS DISTINCT FROM OLD.read_at THEN
            NEW.read_seq = pg_current_xact_id();
            NEW.read_source = v_source;
        ELSE
            NEW.read_seq = OLD.read_seq;
            NEW.read_source = OLD.read_source;
        END IF;

        IF NEW.active IS DISTINCT FROM OLD.active
           OR NEW."on" IS DISTINCT FROM OLD."on"
           OR NEW."at" IS DISTINCT FROM OLD."at" THEN
            NEW.todo_seq = pg_current_xact_id();
            NEW.todo_source = v_source;
        ELSE
            NEW.todo_seq = OLD.todo_seq;
            NEW.todo_source = OLD.todo_source;
        END IF;
    ELSE
        -- INSERT: both dimensions are newly established by this writer.
        NEW.read_seq = pg_current_xact_id();
        NEW.read_source = v_source;
        NEW.todo_seq = pg_current_xact_id();
        NEW.todo_source = v_source;
    END IF;

    RETURN NEW;
END;
$$;
-- Modify "set_thread_state_updated_at" trigger
CREATE OR REPLACE TRIGGER "set_thread_state_updated_at" BEFORE INSERT OR UPDATE ON "public"."thread_state" FOR EACH ROW EXECUTE FUNCTION "public"."thread_state_seq_and_updated_at"();
