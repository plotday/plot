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
CREATE POLICY "Users can access their activities" ON public.priority
    FOR SELECT TO authenticated
        USING (can_access_priority (id));

CREATE POLICY "Users can see who shares their activities" ON public.priority_user
    FOR SELECT TO authenticated
        USING ((user_id = auth.uid ())
            OR can_access_priority (priority_id));

CREATE POLICY "Users can create new root activities" ON public.priority
    FOR INSERT TO authenticated
        WITH CHECK (nlevel (priority.path) = 1);

CREATE POLICY "Users can create new activities in their activities" ON public.priority
    FOR INSERT TO authenticated
        WITH CHECK (can_access_priority (parent_path (priority.path)));

CREATE POLICY "Users can update their activities" ON public.priority
    FOR UPDATE TO authenticated
        USING (can_access_priority (id))
        WITH CHECK (nlevel (priority.path) = 1
            OR can_access_priority (parent_path (priority.path)));

CREATE POLICY "Users can read/write their priority settings" ON "public"."priority_settings"
    FOR ALL TO authenticated
        USING (user_id = auth.uid ());

-- CREATE OR REPLACE FUNCTION restrict_field_update()
-- RETURNS TRIGGER AS $$
-- BEGIN
--     IF NEW.restricted_field IS DISTINCT FROM OLD.restricted_field THEN
--         RAISE EXCEPTION 'Update to restricted_field is not allowed';
--     END IF;
--     RETURN NEW;
-- END;
-- $$ LANGUAGE plpgsql;
--
-- CREATE TRIGGER check_update
-- BEFORE UPDATE ON my_table
-- FOR EACH ROW
-- EXECUTE FUNCTION restrict_field_update();
-- -- Policy to allow priority creation if user has access to the parent path
-- CREATE POLICY priority_insert_policy ON public.priority
--     FOR INSERT
--         USING ((
--         -- Ensure activities with root paths can be created:
--         nlevel (new.path) = 1)
--             OR EXISTS (
--                 SELECT
--                     1
--                 FROM
--                     public.priority_user cu
--                     JOIN public.priority c ON c.id = cu.priority_id
--                 WHERE
--                     cu.user_id = auth.uid () AND c.path @> new.path));
--
-- -- Allow insert for assigning access rights for specific priority entries
-- CREATE POLICY priority_user_insert_policy ON public.priority_user
--     FOR INSERT
--         USING (EXISTS (
--             SELECT
--                 1
--             FROM
--                 public.priority c
--                 JOIN public.priority_user cu ON cu.priority_id = c.id
--             WHERE
--                 cu.user_id = auth.uid () AND cu.path @> new.path));
--
-- CREATE POLICY "Users can create new root activities" ON "public"."priority" AS permissive
--     FOR INSERT TO authenticated
--         WITH CHECK (nlevel (path) = 1);
--
-- CREATE POLICY "Users can add their activities" ON "public"."priority_user" AS permissive
--     FOR INSERT TO authenticated
--         WITH CHECK (EXISTS (
--             SELECT
--                 1
--             FROM
--                 public.priority c
--             WHERE
--                 c.id = priority_user.priority_id AND c.created_by = priority_user.user_id));
--
-- CREATE POLICY "Users can read their activities" ON "public"."priority" AS permissive
--     FOR SELECT TO authenticated
--         USING (EXISTS (
--             SELECT
--                 1
--             FROM
--                 public.priority_user cu
--             WHERE
--                 cu.user_id = auth.uid () AND cu.priority_id = priority.id));
--
-- CREATE POLICY "Users can only create activities where the parent is root or accessible to them" ON "public"."priority" AS permissive
--     FOR INSERT TO authenticated
--         WITH CHECK (nlevel (path) = 1
--         OR EXISTS (
--             SELECT
--                 1
--             FROM
--                 public.priority c
--                 JOIN public.priority_user cu ON cu.priority_id = c.id
--             WHERE
--                 c.path = parent_path (priority.path) AND cu.user_id = auth.uid ()));
--
-- CREATE POLICY "Users can only edit activities where the parent is root or accessible to them" ON "public"."priority" AS permissive
--     FOR UPDATE TO authenticated
--         WITH CHECK (nlevel (path) = 1
--         OR EXISTS (
--             SELECT
--                 1
--             FROM
--                 public.priority c
--                 JOIN public.priority_user cu ON cu.priority_id = c.id
--             WHERE
--                 c.path = parent_path (priority.path) AND cu.user_id = auth.uid ()));
-- CREATE POLICY "Users can update their activities" ON "public"."priority" AS restrictive
--     FOR UPDATE TO authenticated
--         USING (EXISTS (
--             SELECT
--                 1
--             FROM
--                 public.priority_user cu
--             WHERE
--                 cu.user_id = auth.uid () AND cu.priority_id = priority.id));
--
-- CREATE POLICY "Users can share their activities" ON "public"."priority_user" AS permissive
--     FOR ALL TO authenticated
--         USING (EXISTS (
--             SELECT
--                 1
--             FROM
--                 public.priority c
--             WHERE
--                 c.id = priority_user.priority_id AND c.created_by = auth.uid ()));
--
