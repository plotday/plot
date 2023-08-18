ALTER TABLE "public"."domain" ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Everyone can view all domains" ON "public"."domain" AS permissive
    FOR SELECT TO authenticated
        USING (TRUE);

