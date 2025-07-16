CREATE TABLE "public"."event" (
    "id" uuid PRIMARY KEY DEFAULT gen_random_uuid_v7 () NOT NULL,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    "deleted_at" timestamp with time zone,
    "draft" boolean NOT NULL DEFAULT FALSE,
    -- Either calendar_id or user_id must be set, but not both.
    -- Events with calend_id null aren't published to a calendar.
    "user_id" uuid REFERENCES auth.users ON DELETE CASCADE,
    "calendar_id" bigint REFERENCES calendar ON DELETE CASCADE,
    -- provider_id is only set if calendar_id is set.
    "provider_id" text DEFAULT gen_random_uuid () ::text,
    "series" text,
    "name" text,
    "status" event_status NOT NULL DEFAULT 'confirmed' ::event_status,
    "response" event_response,
    "visibility" event_visibility NOT NULL DEFAULT 'normal' ::event_visibility,
    "availability" event_availability NOT NULL DEFAULT 'busy' ::event_availability,
    "at" tstzrange NOT NULL,
    "provider_link" text,
    "summary" text,
    "description" text,
    "conferencing_url" text,
    "organizer_email" text,
    "sequence" integer NOT NULL DEFAULT 1,
    "optional" boolean NOT NULL DEFAULT FALSE,
    "invitees_hidden" boolean NOT NULL DEFAULT FALSE,
    "updated_by" integer NOT NULL DEFAULT 0,
    CONSTRAINT event_calendar_provider_id_unique UNIQUE (calendar_id, provider_id),
    CONSTRAINT event_user_or_calendar CHECK ((user_id IS NOT NULL AND calendar_id IS NULL) OR (user_id IS NULL AND calendar_id IS NOT NULL)),
    CONSTRAINT event_provider_id_only_with_calendar CHECK ((calendar_id IS NULL AND provider_id IS NULL) OR (calendar_id IS NOT NULL AND provider_id IS NOT NULL))
);

ALTER TABLE "public"."event" ENABLE ROW LEVEL SECURITY;

CREATE INDEX event_at_idx ON event USING spgist (at);

CREATE TRIGGER set_event_updated_at
    BEFORE UPDATE ON "public"."event"
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

CREATE OR REPLACE FUNCTION public.notify_user_for_event ()
    RETURNS TRIGGER
    SECURITY DEFINER
    LANGUAGE plpgsql
    AS $$
BEGIN
    PERFORM
        realtime.send (jsonb_build_object('table', 'event', 'updated_by', COALESCE(NEW.updated_by, OLD.updated_by)), -- JSONB Payload
            'sync', -- Event name
            'user:' || COALESCE(NEW.user_id, OLD.user_id)::text, -- Topic
            FALSE -- Public / Private flag
);
    RETURN NULL;
END;
$$;

CREATE TRIGGER handle_event_changes
    AFTER INSERT OR UPDATE ON public.event
    FOR EACH ROW
    EXECUTE FUNCTION notify_user_for_event ();

