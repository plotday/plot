ALTER TABLE "public"."label" ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Everyone can view global labels" ON "public"."label" AS permissive
    FOR ALL TO authenticated
        USING (user_id IS NULL);

