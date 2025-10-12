-- Users can view agent all publishers
CREATE POLICY "Users can view agent publishers" ON "public"."publisher"
    FOR SELECT TO authenticated
        USING (TRUE);

