ALTER TABLE "public"."cost"
    DROP CONSTRAINT "cost_type_key";

DROP INDEX IF EXISTS "public"."cost_type_key";

ALTER TABLE "public"."cost"
    DROP COLUMN "type";

ALTER TABLE "public"."cost"
    ADD COLUMN "name" text NOT NULL;

ALTER TABLE "public"."usage"
    DROP COLUMN "hour";

ALTER TABLE "public"."usage"
    ADD COLUMN "date" timestamp with time zone NOT NULL;

ALTER VIEW "public"."activity_tags" SET ( security_invoker = TRUE);
ALTER VIEW "public"."activity_children" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_activity" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_activity_exception" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_activity_tags" SET ( security_invoker = TRUE);
ALTER VIEW "admin"."invitation" SET ( security_invoker = FALSE);
ALTER VIEW "public"."priority_tags" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_child" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_settings_inherited" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_priority" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_child_agent" SET ( security_invoker = TRUE);
ALTER VIEW "public"."actor" SET ( security_invoker = TRUE);
