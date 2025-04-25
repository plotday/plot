CREATE FUNCTION can_access_priority (_priority_id uuid)
    RETURNS bool
    AS $$
    SELECT
        EXISTS (
            SELECT
                1
            FROM
                public.priority_user cu
                JOIN public.priority c ON c.id = cu.priority_id
            WHERE
                cu.user_id = auth.uid ()
                AND c.path @> (
                    SELECT
                        path
                    FROM
                        public.priority c2
                    WHERE
                        c2.id = _priority_id))
            OR NOT EXISTS (
                SELECT
                    1
                FROM
                    public.priority_user cu
                WHERE
                    cu.priority_id = _priority_id);
$$
LANGUAGE sql
SECURITY DEFINER;

CREATE FUNCTION can_access_priority (_priority_path ltree)
    RETURNS bool
    AS $$
    SELECT
        EXISTS (
            SELECT
                1
            FROM
                public.priority_user cu
                JOIN public.priority c ON c.id = cu.priority_id
            WHERE
                cu.user_id = auth.uid ()
                AND c.path @> (
                    SELECT
                        path
                    FROM
                        public.priority c2
                    WHERE
                        c2.path = _priority_path));
$$
LANGUAGE sql
SECURITY DEFINER;

-- Allow access to priority rows based on user’s access
CREATE POLICY "Users can access their priorities" ON public.priority
    FOR SELECT TO authenticated
        USING (can_access_priority (id));

CREATE POLICY "Users change sharing for their priorities" ON public.priority_user
    FOR ALL TO authenticated
        USING (can_access_priority (priority_id));

CREATE POLICY "Users can create new root priorities" ON public.priority
    FOR INSERT TO authenticated
        WITH CHECK (extensions.nlevel (priority.path) = 1);

CREATE POLICY "Users can create new priorities in their priorities" ON public.priority
    FOR INSERT TO authenticated
        WITH CHECK (can_access_priority (parent_path (priority.path)));

CREATE POLICY "Users can update their priorities" ON public.priority
    FOR UPDATE TO authenticated
        USING (can_access_priority (id))
        WITH CHECK (extensions.nlevel (priority.path) = 1
            OR can_access_priority (parent_path (priority.path)));

CREATE POLICY "Users can read/write their priority settings" ON "public"."priority_settings"
    FOR ALL TO authenticated
        USING (user_id = auth.uid ());

