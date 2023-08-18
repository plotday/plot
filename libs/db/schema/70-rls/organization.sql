ALTER TABLE "public"."organization" ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Everyone can view all organizations" ON "public"."organization" AS permissive
    FOR SELECT TO authenticated
        USING (TRUE);

