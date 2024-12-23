CREATE TABLE "public"."event" (
    "id" uuid PRIMARY KEY DEFAULT gen_random_uuid_v7 () NOT NULL,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    "deleted_at" timestamp with time zone,
    "draft" boolean NOT NULL DEFAULT FALSE,
    "user_id" uuid NOT NULL REFERENCES auth.users ON DELETE CASCADE,
    "calendar_id" bigint REFERENCES calendar ON DELETE CASCADE,
    "provider_id" text NOT NULL DEFAULT gen_random_uuid () ::text,
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
    CONSTRAINT event_calendar_provider_id_unique UNIQUE (calendar_id, provider_id)
);

ALTER TABLE "public"."event" ENABLE ROW LEVEL SECURITY;

ALTER publication supabase_realtime
    ADD TABLE public.event;

CREATE INDEX event_at_idx ON event USING spgist (at);

CREATE TRIGGER set_event_updated_at
    BEFORE UPDATE ON "public"."event"
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

