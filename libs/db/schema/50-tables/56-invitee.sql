CREATE TABLE "public"."invitee" (
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "event_id" bigint NOT NULL,
    "email" text NOT NULL,
    "response" event_response,
    "is_optional" boolean NOT NULL DEFAULT FALSE
);

CREATE UNIQUE INDEX invitee_pkey ON public.invitee USING btree (event_id, email);

ALTER TABLE "public"."invitee"
    ADD CONSTRAINT "invitee_pkey" PRIMARY KEY USING INDEX "invitee_pkey";

ALTER TABLE "public"."invitee"
    ADD CONSTRAINT "invitee_event_id_fkey" FOREIGN KEY (event_id) REFERENCES event (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."invitee" validate CONSTRAINT "invitee_event_id_fkey";

CREATE INDEX invitee_event_id_idx ON public.invitee USING btree (event_id);

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

