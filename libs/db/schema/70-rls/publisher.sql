-- Users can view twist all publishers
CREATE POLICY "Users can view twist publishers" ON "public"."publisher"
    FOR SELECT TO authenticated
        USING (TRUE);

