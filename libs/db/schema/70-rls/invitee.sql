CREATE POLICY "Users can edit their invitees for their events" ON "public"."invitee" AS permissive
    FOR ALL TO authenticated
        USING (event_id IN (
            SELECT
                id
            FROM
                public.event));

