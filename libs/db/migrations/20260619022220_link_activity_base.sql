-- Create "update_thread_activity_from_link" function
CREATE FUNCTION "public"."update_thread_activity_from_link" () RETURNS trigger LANGUAGE plpgsql SET "search_path" = public AS $$
BEGIN
    IF NEW.thread_id IS NOT NULL AND NEW.source_created_at IS NOT NULL THEN
        PERFORM set_config('plot.skip_activity_seq', 'on', TRUE);
        UPDATE thread
        SET activity_base = GREATEST(COALESCE(activity_base, created_at), NEW.source_created_at)
        WHERE id = NEW.thread_id
          AND (activity_base IS NULL OR activity_base < NEW.source_created_at);
        PERFORM set_config('plot.skip_activity_seq', 'off', TRUE);
    END IF;
    RETURN NEW;
END;
$$;
-- Create trigger "update_thread_activity_from_link_ins"
CREATE TRIGGER "update_thread_activity_from_link_ins" AFTER INSERT ON "public"."link" FOR EACH ROW EXECUTE FUNCTION "public"."update_thread_activity_from_link"();
-- Create trigger "update_thread_activity_from_link_upd"
CREATE TRIGGER "update_thread_activity_from_link_upd" AFTER UPDATE OF "source_created_at", "thread_id" ON "public"."link" FOR EACH ROW WHEN ((old.source_created_at IS DISTINCT FROM new.source_created_at) OR (old.thread_id IS DISTINCT FROM new.thread_id)) EXECUTE FUNCTION "public"."update_thread_activity_from_link"();
