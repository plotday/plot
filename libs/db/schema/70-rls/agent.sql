CREATE POLICY "Allow all users to view agents" ON "public"."agent"
    FOR SELECT TO authenticated
    USING (true);

CREATE POLICY "Users can edit agents in their accessible priorities" ON "public"."priority_agent"
    FOR ALL TO authenticated
        USING (EXISTS (
            SELECT
                1
            FROM
                priority_user pu
                JOIN priority p ON pu.priority_id = p.id OR (p.path <@ (
                        SELECT
                            path
                        FROM
                            priority
                    WHERE
                        id = pu.priority_id))
                    WHERE
                        pu.user_id = auth.uid () AND pu.deleted_at IS NULL AND priority_agent.priority_id = p.id));