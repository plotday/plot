CREATE TABLE "public"."invitee" (
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "event_id" bigint NOT NULL,
    "contact_id" bigint NOT NULL,
    "response" event_response,
    "sequence" integer NOT NULL DEFAULT 1,
    "is_optional" boolean NOT NULL DEFAULT FALSE
);

CREATE UNIQUE INDEX invitee_pkey ON public.invitee USING btree (event_id, contact_id);

ALTER TABLE "public"."invitee"
    ADD CONSTRAINT "invitee_pkey" PRIMARY KEY USING INDEX "invitee_pkey";

ALTER TABLE "public"."invitee"
    ADD CONSTRAINT "invitee_contact_id_fkey" FOREIGN KEY (contact_id) REFERENCES contact (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."invitee" validate CONSTRAINT "invitee_contact_id_fkey";

ALTER TABLE "public"."invitee"
    ADD CONSTRAINT "invitee_event_id_fkey" FOREIGN KEY (event_id) REFERENCES event (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."invitee" validate CONSTRAINT "invitee_event_id_fkey";

CREATE INDEX invitee_event_id_idx ON public.invitee USING btree (event_id);

