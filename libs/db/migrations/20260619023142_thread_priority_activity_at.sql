-- Create "fanout_activity_at_to_thread_priority" function
CREATE FUNCTION "public"."fanout_activity_at_to_thread_priority" () RETURNS trigger LANGUAGE plpgsql SET "search_path" = public AS $$
BEGIN
    IF NEW.activity_base IS NOT NULL THEN
        PERFORM set_config('plot.skip_activity_seq', 'on', TRUE);
        UPDATE thread_priority
        SET activity_at = GREATEST(COALESCE(activity_at, '-infinity'::timestamptz), NEW.activity_base)
        WHERE thread_id = NEW.id
          AND (activity_at IS NULL OR activity_at < NEW.activity_base);
        PERFORM set_config('plot.skip_activity_seq', 'off', TRUE);
    END IF;
    RETURN NULL;
END;
$$;
-- Create trigger "fanout_activity_at_trigger"
CREATE TRIGGER "fanout_activity_at_trigger" AFTER UPDATE OF "activity_base" ON "public"."thread" FOR EACH ROW WHEN (new.activity_base IS DISTINCT FROM old.activity_base) EXECUTE FUNCTION "public"."fanout_activity_at_to_thread_priority"();
-- Modify "thread_priority" table
ALTER TABLE "public"."thread_priority" ADD COLUMN "activity_at" timestamptz NULL;
-- Create index "idx_thread_priority_user_activity" to table: "thread_priority"
CREATE INDEX "idx_thread_priority_user_activity" ON "public"."thread_priority" ("user_id", "activity_at" DESC);
-- Create index "idx_thread_priority_user_priority_activity" to table: "thread_priority"
CREATE INDEX "idx_thread_priority_user_priority_activity" ON "public"."thread_priority" ("user_id", "priority_id", "activity_at" DESC);
-- Create "seed_thread_priority_activity_at" function
CREATE FUNCTION "public"."seed_thread_priority_activity_at" () RETURNS trigger LANGUAGE plpgsql SET "search_path" = public AS $$
BEGIN
    IF NEW.activity_at IS NULL THEN
        SELECT GREATEST(
                   COALESCE(a.activity_base, a.created_at),
                   COALESCE(ts.bumped_at, '-infinity'::timestamptz))
          INTO NEW.activity_at
          FROM thread a
          LEFT JOIN thread_state ts
                 ON ts.thread_id = a.id AND ts.user_id = NEW.user_id
         WHERE a.id = NEW.thread_id;
    END IF;
    RETURN NEW;
END;
$$;
-- Create trigger "seed_thread_priority_activity_at_trigger"
CREATE TRIGGER "seed_thread_priority_activity_at_trigger" BEFORE INSERT ON "public"."thread_priority" FOR EACH ROW EXECUTE FUNCTION "public"."seed_thread_priority_activity_at"();
-- Create "update_tp_activity_from_thread_state" function
CREATE FUNCTION "public"."update_tp_activity_from_thread_state" () RETURNS trigger LANGUAGE plpgsql SET "search_path" = public AS $$
BEGIN
    IF NEW.bumped_at IS NOT NULL THEN
        PERFORM set_config('plot.skip_activity_seq', 'on', TRUE);
        UPDATE thread_priority
        SET activity_at = GREATEST(COALESCE(activity_at, '-infinity'::timestamptz), NEW.bumped_at)
        WHERE thread_id = NEW.thread_id
          AND user_id = NEW.user_id
          AND (activity_at IS NULL OR activity_at < NEW.bumped_at);
        PERFORM set_config('plot.skip_activity_seq', 'off', TRUE);
    END IF;
    RETURN NULL;
END;
$$;
-- Create trigger "update_tp_activity_from_thread_state_ins"
CREATE TRIGGER "update_tp_activity_from_thread_state_ins" AFTER INSERT ON "public"."thread_state" FOR EACH ROW EXECUTE FUNCTION "public"."update_tp_activity_from_thread_state"();
-- Create trigger "update_tp_activity_from_thread_state_upd"
CREATE TRIGGER "update_tp_activity_from_thread_state_upd" AFTER UPDATE OF "bumped_at" ON "public"."thread_state" FOR EACH ROW WHEN (new.bumped_at IS DISTINCT FROM old.bumped_at) EXECUTE FUNCTION "public"."update_tp_activity_from_thread_state"();
