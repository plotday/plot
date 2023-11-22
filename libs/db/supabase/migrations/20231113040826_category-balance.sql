ALTER TABLE "public"."category"
    ADD COLUMN "balance" integer;

ALTER TABLE "public"."category"
    ADD COLUMN "balance_granted_at" timestamp with time zone;

ALTER TABLE "public"."category"
    ADD COLUMN "balance_weekly_grant" integer;

ALTER TABLE "public"."category"
    ADD COLUMN "priority" text NOT NULL DEFAULT 'O'::text;

