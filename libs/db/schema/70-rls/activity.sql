CREATE POLICY "Users can edit their activites" ON "public"."activity" AS permissive
    FOR ALL TO authenticated
        USING (user_id = auth.uid ());

