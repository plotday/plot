DROP POLICY "Users can view their own events" ON "public"."event";

CREATE POLICY "Users can edit their own events" ON "public"."event" AS permissive
    FOR ALL TO authenticated
        USING ((calendar_id IN (
            SELECT
                calendar.id
            FROM
                calendar)));

ALTER VIEW gap SET ( security_invoker = TRUE);
ALTER VIEW gap_monthly SET ( security_invoker = TRUE);
ALTER VIEW gap_daily SET ( security_invoker = TRUE);
ALTER VIEW insight SET ( security_invoker = TRUE);
ALTER VIEW insight_weekly SET ( security_invoker = TRUE);
ALTER VIEW "public"."invitation_admin" SET ( security_invoker = FALSE);
ALTER VIEW "public"."event_x" SET ( security_invoker = TRUE);
ALTER VIEW "public"."waitlist_admin" SET ( security_invoker = FALSE);
ALTER VIEW "public"."sync_admin" SET ( security_invoker = FALSE);
