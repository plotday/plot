CREATE FUNCTION can_access_activity (_activity_id uuid)
    RETURNS bool
    AS $$
    SELECT
        EXISTS (
            SELECT
                1
            FROM
                public.activity_user cu
                JOIN public.activity c ON c.id = cu.activity_id
            WHERE
                cu.user_id = auth.uid ()
                AND c.path @> (
                    SELECT
                        path
                    FROM
                        public.activity c2
                    WHERE
                        c2.id = _activity_id))
            OR NOT EXISTS (
                SELECT
                    1
                FROM
                    public.activity_user cu
                WHERE
                    cu.activity_id = _activity_id);
$$
LANGUAGE sql
SECURITY DEFINER;

CREATE FUNCTION can_access_activity (_activity_path ltree)
    RETURNS bool
    AS $$
    SELECT
        EXISTS (
            SELECT
                1
            FROM
                public.activity_user cu
                JOIN public.activity c ON c.id = cu.activity_id
            WHERE
                cu.user_id = auth.uid ()
                AND c.path @> (
                    SELECT
                        path
                    FROM
                        public.activity c2
                    WHERE
                        c2.path = _activity_path));
$$
LANGUAGE sql
SECURITY DEFINER;

-- Allow access to activity rows based on user’s access
CREATE POLICY "Users can access their activities" ON public.activity
    FOR SELECT TO authenticated
        USING (can_access_activity (id));

CREATE POLICY "Users can see who shares their activities" ON public.activity_user
    FOR SELECT TO authenticated
        USING ((user_id = auth.uid ())
            OR can_access_activity (activity_id));

CREATE POLICY "Users can create new root activities" ON public.activity
    FOR INSERT TO authenticated
        WITH CHECK (nlevel (activity.path) = 1);

CREATE POLICY "Users can create new activities in their activities" ON public.activity
    FOR INSERT TO authenticated
        WITH CHECK (can_access_activity (parent_path (activity.path)));

CREATE POLICY "Users can update their activities" ON public.activity
    FOR UPDATE TO authenticated
        USING (can_access_activity (id))
        WITH CHECK (nlevel (activity.path) = 1
            OR can_access_activity (parent_path (activity.path)));

CREATE POLICY "Users can read/write their activity settings" ON "public"."activity_settings"
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
-- -- Policy to allow activity creation if user has access to the parent path
-- CREATE POLICY activity_insert_policy ON public.activity
--     FOR INSERT
--         USING ((
--         -- Ensure activities with root paths can be created:
--         nlevel (new.path) = 1)
--             OR EXISTS (
--                 SELECT
--                     1
--                 FROM
--                     public.activity_user cu
--                     JOIN public.activity c ON c.id = cu.activity_id
--                 WHERE
--                     cu.user_id = auth.uid () AND c.path @> new.path));
--
-- -- Allow insert for assigning access rights for specific activity entries
-- CREATE POLICY activity_user_insert_policy ON public.activity_user
--     FOR INSERT
--         USING (EXISTS (
--             SELECT
--                 1
--             FROM
--                 public.activity c
--                 JOIN public.activity_user cu ON cu.activity_id = c.id
--             WHERE
--                 cu.user_id = auth.uid () AND cu.path @> new.path));
--
-- CREATE POLICY "Users can create new root activities" ON "public"."activity" AS permissive
--     FOR INSERT TO authenticated
--         WITH CHECK (nlevel (path) = 1);
--
-- CREATE POLICY "Users can add their activities" ON "public"."activity_user" AS permissive
--     FOR INSERT TO authenticated
--         WITH CHECK (EXISTS (
--             SELECT
--                 1
--             FROM
--                 public.activity c
--             WHERE
--                 c.id = activity_user.activity_id AND c.created_by = activity_user.user_id));
--
-- CREATE POLICY "Users can read their activities" ON "public"."activity" AS permissive
--     FOR SELECT TO authenticated
--         USING (EXISTS (
--             SELECT
--                 1
--             FROM
--                 public.activity_user cu
--             WHERE
--                 cu.user_id = auth.uid () AND cu.activity_id = activity.id));
--
-- CREATE POLICY "Users can only create activities where the parent is root or accessible to them" ON "public"."activity" AS permissive
--     FOR INSERT TO authenticated
--         WITH CHECK (nlevel (path) = 1
--         OR EXISTS (
--             SELECT
--                 1
--             FROM
--                 public.activity c
--                 JOIN public.activity_user cu ON cu.activity_id = c.id
--             WHERE
--                 c.path = parent_path (activity.path) AND cu.user_id = auth.uid ()));
--
-- CREATE POLICY "Users can only edit activities where the parent is root or accessible to them" ON "public"."activity" AS permissive
--     FOR UPDATE TO authenticated
--         WITH CHECK (nlevel (path) = 1
--         OR EXISTS (
--             SELECT
--                 1
--             FROM
--                 public.activity c
--                 JOIN public.activity_user cu ON cu.activity_id = c.id
--             WHERE
--                 c.path = parent_path (activity.path) AND cu.user_id = auth.uid ()));
-- CREATE POLICY "Users can update their activities" ON "public"."activity" AS restrictive
--     FOR UPDATE TO authenticated
--         USING (EXISTS (
--             SELECT
--                 1
--             FROM
--                 public.activity_user cu
--             WHERE
--                 cu.user_id = auth.uid () AND cu.activity_id = activity.id));
--
-- CREATE POLICY "Users can share their activities" ON "public"."activity_user" AS permissive
--     FOR ALL TO authenticated
--         USING (EXISTS (
--             SELECT
--                 1
--             FROM
--                 public.activity c
--             WHERE
--                 c.id = activity_user.activity_id AND c.created_by = auth.uid ()));
--
