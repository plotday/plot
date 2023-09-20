CREATE POLICY "Users can update their invitees for their events" ON "public"."invitee" AS permissive
    FOR UPDATE TO authenticated
        USING ((event_id IN (
            SELECT
                event.id
            FROM
                event)));

