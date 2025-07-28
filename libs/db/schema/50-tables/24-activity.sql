CREATE TABLE "public"."activity" (
    "id" uuid PRIMARY KEY DEFAULT gen_random_uuid_v7 () NOT NULL,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    "created_by" uuid NOT NULL, -- References either auth.users or priority_agent (if it starts with 0xab07ab07)
    "deleted_at" timestamp with time zone,
    "priority_id" uuid NOT NULL REFERENCES public.priority ON DELETE CASCADE,
    "path" ltree NOT NULL DEFAULT generate_path (NULL),
    "order" double precision NOT NULL DEFAULT public.order_first (),
    "draft" boolean NOT NULL DEFAULT FALSE,
    "private" boolean NOT NULL DEFAULT FALSE,
    "pinned" boolean NOT NULL DEFAULT FALSE,
    "do_at" date,
    "done_at" timestamp with time zone,
    "title" text,
    "note" text,
    "event_series" text,
    "updated_by" integer NOT NULL DEFAULT 0
);

CREATE INDEX idx_activity_priority_id ON "public"."activity" ("priority_id");

CREATE INDEX idx_activity_path ON "public"."activity" USING gist ("path");

CREATE INDEX idx_activity_do_at ON "public"."activity" ("do_at");

CREATE INDEX idx_activity_done_at ON "public"."activity" ("done_at");

ALTER TABLE "public"."activity" ENABLE ROW LEVEL SECURITY;

CREATE TRIGGER set_activity_updated_at
    BEFORE UPDATE ON "public"."activity"
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

CREATE TRIGGER set_activity_created_by
    BEFORE INSERT ON "public"."activity"
    FOR EACH ROW
    EXECUTE FUNCTION update_created_by ();

CREATE OR REPLACE FUNCTION public.notify_user_for_activity ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SECURITY DEFINER
    AS $function$
DECLARE
    target_priority_id uuid;
    user_to_notify uuid;
BEGIN
    -- Get the priority_id from the activity
    target_priority_id := COALESCE(NEW.priority_id, OLD.priority_id);
    -- Notify all users who have access to this priority
    FOR user_to_notify IN
    SELECT
        user_id
    FROM
        public.get_users_with_priority_access (target_priority_id)
        LOOP
            PERFORM
                realtime.send (jsonb_build_object('table', 'activity', 'updated_by', COALESCE(NEW.updated_by, OLD.updated_by)), -- JSONB Payload
                    'sync', -- Event name
                    'user:' || user_to_notify::text, -- Topic
                    FALSE -- Public / Private flag
);
        END LOOP;
    RETURN NULL;
END;
$function$;

CREATE TRIGGER handle_activity_changes
    AFTER INSERT OR UPDATE ON public.activity
    FOR EACH ROW
    EXECUTE FUNCTION notify_user_for_activity ();

CREATE TRIGGER activity_change_api_call
    AFTER INSERT ON public.activity
    FOR EACH ROW
    EXECUTE FUNCTION public.notify_internal_api_for_activity ();


