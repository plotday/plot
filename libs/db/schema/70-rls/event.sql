CREATE POLICY "Users can edit their own events" ON "public"."event" AS permissive
    FOR ALL TO authenticated
        USING (calendar_id IN (
            SELECT
                calendar.id
            FROM
                calendar));

