ALTER TABLE "public"."event"
    ADD COLUMN "optional" boolean NOT NULL DEFAULT FALSE;

ALTER TABLE "public"."event"
    ADD COLUMN "response" event_response;

