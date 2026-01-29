CREATE POLICY "Authenticated can read their own messages" ON "realtime"."messages"
    FOR SELECT TO authenticated
        USING ((
            SELECT
                realtime.topic ()) = 'sync:' || auth.uid ()::text);

