DROP TRIGGER IF EXISTS "handle_calendar_changes" ON "public"."calendar";

DROP TRIGGER IF EXISTS "set_calendar_updated_at" ON "public"."calendar";

DROP POLICY "Users can view their own calendars" ON "public"."calendar";

ALTER TABLE "public"."calendar"
    DROP CONSTRAINT "calendar_account_id_fkey";

ALTER TABLE "public"."calendar"
    DROP CONSTRAINT "calendar_account_provider_id_unique";

ALTER TABLE "public"."calendar"
    DROP CONSTRAINT "calendar_priority_id_fkey";

ALTER TABLE "public"."calendar"
    DROP CONSTRAINT "calendar_priority_required_when_enabled";

DROP VIEW IF EXISTS "public"."calendar_x";

DROP FUNCTION IF EXISTS "public"."calendars" (account);

DROP FUNCTION IF EXISTS "public"."notify_user_for_calendar" ();

ALTER TABLE "public"."calendar"
    DROP CONSTRAINT "calendar_pkey";

DROP INDEX IF EXISTS "public"."calendar_account_id_idx";

DROP INDEX IF EXISTS "public"."calendar_account_provider_id_unique";

DROP INDEX IF EXISTS "public"."calendar_pkey";

DROP TABLE "public"."calendar";

ALTER VIEW "public"."activity_tags" SET ( security_invoker = TRUE);
ALTER VIEW "public"."activity_children" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_activity" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_activity_exception" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_activity_tags" SET ( security_invoker = TRUE);
ALTER VIEW "admin"."invitation" SET ( security_invoker = FALSE);
ALTER VIEW "public"."priority_tags" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_child" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_priority" SET ( security_invoker = TRUE);
ALTER VIEW "public"."agent_x" SET ( security_invoker = TRUE);
