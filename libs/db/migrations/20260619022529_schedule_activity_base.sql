-- Create "update_thread_activity_from_schedule" function
CREATE FUNCTION "public"."update_thread_activity_from_schedule" () RETURNS trigger LANGUAGE plpgsql SET "search_path" = public AS $$
DECLARE
    v_thread_id uuid;
    v_end       timestamptz;
BEGIN
    IF NEW.occurrence IS NOT NULL OR NEW.recurrence_rule IS NOT NULL
       OR NEW.archived_at IS NOT NULL THEN
        RETURN NEW;
    END IF;
    v_end := COALESCE(upper(NEW.at), upper(NEW."on")::timestamptz);
    IF v_end IS NULL OR v_end > now() THEN
        RETURN NEW;  -- unbounded or future: client owns ordering
    END IF;
    v_thread_id := NEW.thread_id;
    IF v_thread_id IS NULL AND NEW.link_id IS NOT NULL THEN
        SELECT l.thread_id INTO v_thread_id FROM link l WHERE l.id = NEW.link_id;
    END IF;
    IF v_thread_id IS NULL THEN
        RETURN NEW;
    END IF;
    PERFORM set_config('plot.skip_activity_seq', 'on', TRUE);
    UPDATE thread
    SET activity_base = GREATEST(COALESCE(activity_base, created_at), v_end)
    WHERE id = v_thread_id
      AND (activity_base IS NULL OR activity_base < v_end);
    PERFORM set_config('plot.skip_activity_seq', 'off', TRUE);
    RETURN NEW;
END;
$$;
-- Create trigger "update_thread_activity_from_schedule_ins"
CREATE TRIGGER "update_thread_activity_from_schedule_ins" AFTER INSERT ON "public"."schedule" FOR EACH ROW EXECUTE FUNCTION "public"."update_thread_activity_from_schedule"();
-- Create trigger "update_thread_activity_from_schedule_upd"
CREATE TRIGGER "update_thread_activity_from_schedule_upd" AFTER UPDATE OF "archived_at", "at", "on" ON "public"."schedule" FOR EACH ROW EXECUTE FUNCTION "public"."update_thread_activity_from_schedule"();
