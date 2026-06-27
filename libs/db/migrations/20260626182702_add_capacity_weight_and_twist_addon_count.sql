-- Modify "team_subscription" table
ALTER TABLE "public"."team_subscription" ADD COLUMN "twist_addon_count" integer NOT NULL DEFAULT 0;
-- Modify "twist" table
ALTER TABLE "public"."twist" ADD COLUMN "capacity_weight" integer NOT NULL DEFAULT 1;
-- Modify "user_subscription" table
ALTER TABLE "public"."user_subscription" ADD COLUMN "twist_addon_count" integer NOT NULL DEFAULT 0;
