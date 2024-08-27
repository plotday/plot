CREATE FUNCTION can_access_context (_context_id uuid)
    RETURNS bool
    AS $$
    SELECT
        EXISTS (
            SELECT
                1
            FROM
                public.context_user cu
                JOIN public.context c ON c.id = cu.context_id
            WHERE
                cu.user_id = auth.uid ()
                AND c.path @> (
                    SELECT
                        path
                    FROM
                        public.context c2
                    WHERE
                        c2.id = _context_id))
            OR NOT EXISTS (
                SELECT
                    1
                FROM
                    public.context_user cu
                WHERE
                    cu.context_id = _context_id);
$$
LANGUAGE sql
SECURITY DEFINER;

CREATE FUNCTION can_access_context (_context_path ltree)
    RETURNS bool
    AS $$
    SELECT
        EXISTS (
            SELECT
                1
            FROM
                public.context_user cu
                JOIN public.context c ON c.id = cu.context_id
            WHERE
                cu.user_id = auth.uid ()
                AND c.path @> (
                    SELECT
                        path
                    FROM
                        public.context c2
                    WHERE
                        c2.path = _context_path));
$$
LANGUAGE sql
SECURITY DEFINER;

-- Allow access to context rows based on user’s access
CREATE POLICY "Users can access their contexts" ON public.context
    FOR SELECT TO authenticated
        USING (can_access_context (id));

CREATE POLICY "Users can see who shares their contexts" ON public.context_user
    FOR SELECT TO authenticated
        USING ((user_id = auth.uid ())
            OR can_access_context (context_id));

CREATE POLICY "Users can create new root contexts" ON public.context
    FOR INSERT TO authenticated
        WITH CHECK (nlevel (context.path) = 1);

CREATE POLICY "Users can create new contexts in their contexts" ON public.context
    FOR INSERT TO authenticated
        WITH CHECK (can_access_context (parent_path (context.path)));

CREATE POLICY "Users can update their contexts" ON public.context
    FOR UPDATE TO authenticated
        USING (can_access_context (id))
        WITH CHECK (nlevel (context.path) = 1
            OR can_access_context (parent_path (context.path)));

CREATE POLICY "Users can read/write their context settings" ON "public"."context_settings"
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
-- -- Policy to allow context creation if user has access to the parent path
-- CREATE POLICY context_insert_policy ON public.context
--     FOR INSERT
--         USING ((
--         -- Ensure contexts with root paths can be created:
--         nlevel (new.path) = 1)
--             OR EXISTS (
--                 SELECT
--                     1
--                 FROM
--                     public.context_user cu
--                     JOIN public.context c ON c.id = cu.context_id
--                 WHERE
--                     cu.user_id = auth.uid () AND c.path @> new.path));
--
-- -- Allow insert for assigning access rights for specific context entries
-- CREATE POLICY context_user_insert_policy ON public.context_user
--     FOR INSERT
--         USING (EXISTS (
--             SELECT
--                 1
--             FROM
--                 public.context c
--                 JOIN public.context_user cu ON cu.context_id = c.id
--             WHERE
--                 cu.user_id = auth.uid () AND cu.path @> new.path));
--
-- CREATE POLICY "Users can create new root contexts" ON "public"."context" AS permissive
--     FOR INSERT TO authenticated
--         WITH CHECK (nlevel (path) = 1);
--
-- CREATE POLICY "Users can add their contexts" ON "public"."context_user" AS permissive
--     FOR INSERT TO authenticated
--         WITH CHECK (EXISTS (
--             SELECT
--                 1
--             FROM
--                 public.context c
--             WHERE
--                 c.id = context_user.context_id AND c.created_by = context_user.user_id));
--
-- CREATE POLICY "Users can read their contexts" ON "public"."context" AS permissive
--     FOR SELECT TO authenticated
--         USING (EXISTS (
--             SELECT
--                 1
--             FROM
--                 public.context_user cu
--             WHERE
--                 cu.user_id = auth.uid () AND cu.context_id = context.id));
--
-- CREATE POLICY "Users can only create contexts where the parent is root or accessible to them" ON "public"."context" AS permissive
--     FOR INSERT TO authenticated
--         WITH CHECK (nlevel (path) = 1
--         OR EXISTS (
--             SELECT
--                 1
--             FROM
--                 public.context c
--                 JOIN public.context_user cu ON cu.context_id = c.id
--             WHERE
--                 c.path = parent_path (context.path) AND cu.user_id = auth.uid ()));
--
-- CREATE POLICY "Users can only edit contexts where the parent is root or accessible to them" ON "public"."context" AS permissive
--     FOR UPDATE TO authenticated
--         WITH CHECK (nlevel (path) = 1
--         OR EXISTS (
--             SELECT
--                 1
--             FROM
--                 public.context c
--                 JOIN public.context_user cu ON cu.context_id = c.id
--             WHERE
--                 c.path = parent_path (context.path) AND cu.user_id = auth.uid ()));
-- CREATE POLICY "Users can update their contexts" ON "public"."context" AS restrictive
--     FOR UPDATE TO authenticated
--         USING (EXISTS (
--             SELECT
--                 1
--             FROM
--                 public.context_user cu
--             WHERE
--                 cu.user_id = auth.uid () AND cu.context_id = context.id));
--
-- CREATE POLICY "Users can share their contexts" ON "public"."context_user" AS permissive
--     FOR ALL TO authenticated
--         USING (EXISTS (
--             SELECT
--                 1
--             FROM
--                 public.context c
--             WHERE
--                 c.id = context_user.context_id AND c.created_by = auth.uid ()));
--
