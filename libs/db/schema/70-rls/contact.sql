ALTER TABLE "public"."contact" ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view their contact" ON "public"."contact" AS permissive
    FOR SELECT TO authenticated
        USING (user_id IN (
            SELECT
                id
            FROM
                public.user));

