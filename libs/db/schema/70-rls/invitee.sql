ALTER TABLE "public"."invitee" ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view their invitees for their events" ON "public"."invitee" AS permissive
    FOR SELECT TO authenticated
        USING (event_id IN (
            SELECT
                id
            FROM
                public.event));

