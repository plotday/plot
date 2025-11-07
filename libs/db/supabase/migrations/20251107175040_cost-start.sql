ALTER TABLE "public"."cost"
    DROP CONSTRAINT "cost_name_key";

DROP INDEX IF EXISTS "public"."cost_name_key";

ALTER TABLE "public"."cost"
    ADD COLUMN "start" timestamp with time zone NOT NULL;

CREATE UNIQUE INDEX cost_name_start_key ON public.cost USING btree (name, START);

ALTER TABLE "public"."cost"
    ADD CONSTRAINT "cost_name_start_key" UNIQUE USING INDEX "cost_name_start_key";

ALTER VIEW "public"."activity_tags" SET ( security_invoker = TRUE);
ALTER VIEW "public"."activity_children" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_activity_unread" SET ( security_invoker = TRUE);
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
