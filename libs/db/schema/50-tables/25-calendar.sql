CREATE TABLE "public"."calendar" (
    "id" bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY NOT NULL,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    "deleted_at" timestamp with time zone,
    "account_id" bigint NOT NULL REFERENCES "account" ON DELETE CASCADE,
    "priority_id" uuid REFERENCES "priority" ON DELETE CASCADE,
    "provider_id" text NOT NULL,
    "synced_dates" tstzrange,
    "sync_state" text,
    "watch_id" text,
    "watch_secret" text,
    "watch_expires_at" timestamp with time zone,
    "sequence" numeric NOT NULL DEFAULT '1' ::numeric,
    "full_sync_at" timestamp with time zone,
    "synced_at" timestamp with time zone,
    "sync_error" text,
    "full_sync_started_at" timestamp with time zone,
    "name" text,
    "enabled" boolean NOT NULL DEFAULT FALSE,
    "ready" boolean NOT NULL DEFAULT FALSE,
    CONSTRAINT calendar_account_provider_id_unique UNIQUE (account_id, provider_id),
    CONSTRAINT calendar_priority_required_when_enabled CHECK (NOT enabled OR priority_id IS NOT NULL)
);

ALTER TABLE "public"."calendar" ENABLE ROW LEVEL SECURITY;

CREATE INDEX calendar_account_id_idx ON public.calendar USING btree (account_id);

CREATE OR REPLACE FUNCTION public.calendars (account)
    RETURNS SETOF calendar
    LANGUAGE sql
    STABLE
    AS $function$
    SELECT
        calendar.*
    FROM
        calendar
    WHERE
        calendar.account_id = $1.id
$function$;

CREATE TRIGGER set_calendar_updated_at
    BEFORE UPDATE ON "public"."calendar"
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

CREATE OR REPLACE FUNCTION public.notify_user_for_calendar ()
    RETURNS TRIGGER
    SECURITY DEFINER
    LANGUAGE plpgsql
    AS $$
BEGIN
    PERFORM
        realtime.send (jsonb_build_object('table', 'calendar'), -- JSONB Payload
            'sync', -- Event name
            'user:' || (SELECT user_id FROM account WHERE id = OLD.account_id)::text, -- Topic
            FALSE -- Public / Private flag
);
    RETURN NULL;
END;
$$;

CREATE TRIGGER handle_calendar_changes
    AFTER INSERT OR UPDATE ON public.calendar
    FOR EACH ROW
    EXECUTE FUNCTION notify_user_for_calendar ();

