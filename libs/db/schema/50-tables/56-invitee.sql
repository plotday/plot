CREATE TABLE "public"."invitee" (
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "event_id" uuid REFERENCES "event" ON DELETE CASCADE,
    "email" text NOT NULL CHECK (is_lower ("email")),
    "response" event_response,
    "is_optional" boolean NOT NULL DEFAULT FALSE,
    CONSTRAINT invitee_event_email_unique UNIQUE (event_id, email)
);

ALTER TABLE "public"."invitee" ENABLE ROW LEVEL SECURITY;

CREATE INDEX invitee_event_id_idx ON public.invitee USING btree (event_id);

ALTER publication supabase_realtime
    ADD TABLE public.invitee;

CREATE OR REPLACE FUNCTION public.contact (invitee)
    RETURNS SETOF contact ROWS 1
    LANGUAGE sql
    STABLE
    AS $function$
    SELECT
        contact.*
    FROM
        contact
    WHERE
        contact.email = $1.email
$function$;

