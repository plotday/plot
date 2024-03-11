CREATE POLICY "Users can read all embeddings" ON "public"."event" AS permissive
    FOR SELECT TO authenticated
        USING (TRUE);

