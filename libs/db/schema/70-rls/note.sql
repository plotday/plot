CREATE POLICY "Users can edit their notes" ON "public"."note" AS permissive
    FOR ALL TO authenticated
        USING (user_id = auth.uid ());

