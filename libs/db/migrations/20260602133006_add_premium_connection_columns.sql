-- Modify "team_subscription" table
ALTER TABLE "public"."team_subscription" ADD COLUMN "premium_connection_addons" integer NOT NULL DEFAULT 0;
-- Modify "twist" table
ALTER TABLE "public"."twist" ADD COLUMN "premium" boolean NOT NULL DEFAULT false;
-- Modify "user_subscription" table
ALTER TABLE "public"."user_subscription" ADD COLUMN "premium_connection_addons" integer NOT NULL DEFAULT 0;
