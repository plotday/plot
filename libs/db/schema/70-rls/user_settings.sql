-- Users can read/write their own settings
CREATE POLICY "Users can read/write their settings" ON "public"."user_settings"
    FOR ALL TO authenticated
        USING (user_id = (select auth.uid ()));
