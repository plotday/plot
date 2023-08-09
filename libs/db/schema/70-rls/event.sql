ALTER TABLE "public"."event" ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view their own events" ON "public"."event" AS permissive
    FOR SELECT TO authenticated
        USING ((calendar_id IN (
            SELECT
                calendar.id
            FROM
                calendar)));

