DROP TRIGGER IF EXISTS "upsert_note_x" ON "public"."note_x";

DROP FUNCTION IF EXISTS "public"."handle_note_x_upsert" ();

CREATE POLICY "Users can edit their activites" ON "public"."activity" AS permissive
    FOR ALL TO authenticated
        USING ((user_id = auth.uid ()));

ALTER VIEW note_x SET ( security_invoker = TRUE);
ALTER VIEW gap SET ( security_invoker = TRUE);
ALTER VIEW gap_monthly SET ( security_invoker = TRUE);
ALTER VIEW gap_daily SET ( security_invoker = TRUE);
ALTER VIEW insight SET ( security_invoker = TRUE);
ALTER VIEW "admin"."sync" SET ( security_invoker = FALSE);
ALTER VIEW "admin"."invitation" SET ( security_invoker = FALSE);
ALTER VIEW activity_x SET ( security_invoker = TRUE);
ALTER VIEW "public"."event_invitees" SET ( security_invoker = TRUE);
ALTER VIEW "public"."event_x" SET ( security_invoker = TRUE);
ALTER VIEW "admin"."user" SET ( security_invoker = FALSE);
ALTER VIEW balance_without_children SET ( security_invoker = TRUE);
ALTER VIEW balance SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_x" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_children" SET ( security_invoker = TRUE);
