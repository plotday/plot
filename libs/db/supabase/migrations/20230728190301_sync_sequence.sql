ALTER TABLE "public"."calendar"
    ADD COLUMN "sequence" numeric NOT NULL DEFAULT '1'::numeric;

ALTER TABLE "public"."raw_event"
    ADD COLUMN "sequence" numeric NOT NULL DEFAULT '1'::numeric;

