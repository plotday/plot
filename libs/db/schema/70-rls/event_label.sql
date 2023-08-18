ALTER TABLE "public"."event_label" ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view their own labels" ON "public"."event_label" AS permissive
    FOR ALL TO authenticated
        USING (event_id IN (
            SELECT
                id
            FROM
                event));

