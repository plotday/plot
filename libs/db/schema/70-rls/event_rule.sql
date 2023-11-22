ALTER TABLE "public"."event_rule" ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can edit their own event overlays" ON "public"."event_rule" AS permissive
    FOR ALL TO authenticated
        USING (is_user_account (auth.uid (), user_id));

