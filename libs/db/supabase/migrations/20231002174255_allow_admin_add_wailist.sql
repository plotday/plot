DROP POLICY "internal_admin can view all users" ON "public"."invitation";

CREATE POLICY "internal_admin can edit all users" ON "public"."user" AS permissive
    FOR ALL TO internal_admin
        USING (TRUE);

ALTER VIEW gap SET ( security_invoker = TRUE);
ALTER VIEW gap_monthly SET ( security_invoker = TRUE);
ALTER VIEW gap_daily SET ( security_invoker = TRUE);
ALTER VIEW "public"."invitation_admin" SET ( security_invoker = FALSE);
ALTER VIEW "public"."event_x" SET ( security_invoker = TRUE);
ALTER VIEW "public"."waitlist_admin" SET ( security_invoker = FALSE);
ALTER VIEW expenditure SET ( security_invoker = TRUE);
ALTER VIEW expenditure_monthly SET ( security_invoker = TRUE);
ALTER VIEW expenditure_rolling SET ( security_invoker = TRUE);
ALTER VIEW prep_monthly SET ( security_invoker = TRUE);
ALTER VIEW "public"."sync_admin" SET ( security_invoker = FALSE);
