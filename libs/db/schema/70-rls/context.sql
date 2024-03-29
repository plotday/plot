CREATE POLICY "Users can read/write their contexts" ON "public"."context" AS permissive
    FOR ALL TO authenticated
        USING (user_id = auth.uid ());

