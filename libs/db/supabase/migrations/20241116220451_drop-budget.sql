DROP TRIGGER IF EXISTS "set_budget_updated_at" ON "public"."budget";

DROP POLICY "Users can read/write their budgets" ON "public"."budget";

ALTER TABLE "public"."budget"
    DROP CONSTRAINT "budget_activity_id_fkey";

ALTER TABLE "public"."budget"
    DROP CONSTRAINT "budget_user_id_fkey";

ALTER TABLE "public"."budget"
    DROP CONSTRAINT "budget_week_check";

ALTER TABLE "public"."budget"
    DROP CONSTRAINT "priority_user_activity_week_unique";

DROP FUNCTION IF EXISTS "public"."budget" (activity);

ALTER TABLE "public"."budget"
    DROP CONSTRAINT "budget_pkey";

DROP INDEX IF EXISTS "public"."budget_pkey";

DROP INDEX IF EXISTS "public"."priority_user_activity_week_unique";

DROP TABLE "public"."budget";

DROP TYPE "public"."budget_type";

ALTER VIEW note_x SET ( security_invoker = TRUE);
ALTER VIEW gap SET ( security_invoker = TRUE);
ALTER VIEW gap_monthly SET ( security_invoker = TRUE);
ALTER VIEW gap_daily SET ( security_invoker = TRUE);
ALTER VIEW insight SET ( security_invoker = TRUE);
-- ALTER VIEW insight_weekly SET ( security_invoker = TRUE);
ALTER VIEW "public"."invitation_admin" SET ( security_invoker = FALSE);
ALTER VIEW "public"."event_invitees" SET ( security_invoker = TRUE);
ALTER VIEW "public"."event_x" SET ( security_invoker = TRUE);
ALTER VIEW "public"."waitlist_admin" SET ( security_invoker = FALSE);
ALTER VIEW "public"."activity_x" SET ( security_invoker = TRUE);
ALTER VIEW balance SET ( security_invoker = TRUE);
ALTER VIEW "public"."sync_admin" SET ( security_invoker = FALSE);
