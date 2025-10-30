ALTER TABLE "public"."usage"
    DROP CONSTRAINT "usage_priority_agent_id_date_cost_id_key";

DROP INDEX IF EXISTS "public"."usage_priority_agent_id_date_cost_id_key";

ALTER TABLE "public"."usage"
    DROP COLUMN "date";

ALTER TABLE "public"."usage"
    ADD COLUMN "hour" timestamp with time zone NOT NULL;

CREATE UNIQUE INDEX cost_name_key ON public.cost USING btree (name);

CREATE UNIQUE INDEX usage_priority_agent_id_hour_cost_id_key ON public.usage USING btree (priority_agent_id, hour, cost_id);

ALTER TABLE "public"."cost"
    ADD CONSTRAINT "cost_name_key" UNIQUE USING INDEX "cost_name_key";

ALTER TABLE "public"."usage"
    ADD CONSTRAINT "usage_hour_check" CHECK ((((EXTRACT(hour FROM hour) % (2)::numeric) = (0)::numeric) AND (EXTRACT(minute FROM hour) = (0)::numeric) AND (EXTRACT(second FROM hour) = (0)::numeric))) NOT valid;

ALTER TABLE "public"."usage" validate CONSTRAINT "usage_hour_check";

ALTER TABLE "public"."usage"
    ADD CONSTRAINT "usage_priority_agent_id_hour_cost_id_key" UNIQUE USING INDEX "usage_priority_agent_id_hour_cost_id_key";

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
