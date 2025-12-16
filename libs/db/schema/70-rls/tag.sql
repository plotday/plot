-- activity_tag RLS policies
CREATE POLICY "Users can view activity_tag in their accessible priorities" ON "public"."activity_tag"
    FOR SELECT
        USING (actor_id = user_contact_id ()
            OR EXISTS (
                SELECT
                    1
                FROM
                    activity a
                WHERE
                    a.id = activity_tag.activity_id AND public.user_has_priority_access (auth.uid (), a.priority_id)));

CREATE POLICY "Users can insert activity_tag for activities in their accessible priorities" ON "public"."activity_tag"
    FOR INSERT
        WITH CHECK (actor_id = user_contact_id ()
        AND EXISTS (
            SELECT
                1
            FROM
                activity a
            WHERE
                a.id = activity_tag.activity_id AND public.user_has_priority_access (auth.uid (), a.priority_id)));

REVOKE UPDATE ON TABLE public.activity_tag FROM authenticated;

GRANT UPDATE (updated_at, updated_by, archived_at) ON TABLE public.activity_tag TO authenticated;

CREATE POLICY "Users can update activity_tag for activities in their accessible priorities" ON "public"."activity_tag"
    FOR UPDATE
        USING (actor_id = user_contact_id ()
            OR EXISTS (
                SELECT
                    1
                FROM
                    activity a
                WHERE
                    a.id = activity_tag.activity_id AND public.user_has_priority_access (auth.uid (), a.priority_id) AND get_tag_type (activity_tag.tag_id) = 'toggle'))
                WITH CHECK (activity_tag.actor_id = user_contact_id ());

-- note_tag RLS policies
CREATE POLICY "Users can view note_tag in their accessible priorities" ON "public"."note_tag"
    FOR SELECT
        USING (actor_id = user_contact_id ()
            OR EXISTS (
                SELECT
                    1
                FROM
                    note n
                    JOIN activity a ON a.id = n.activity_id
                WHERE
                    n.id = note_tag.note_id AND public.user_has_priority_access (auth.uid (), a.priority_id)));

CREATE POLICY "Users can insert note_tag for notes in their accessible priorities" ON "public"."note_tag"
    FOR INSERT
        WITH CHECK (actor_id = user_contact_id ()
        AND EXISTS (
            SELECT
                1
            FROM
                note n
                JOIN activity a ON a.id = n.activity_id
            WHERE
                n.id = note_tag.note_id AND public.user_has_priority_access (auth.uid (), a.priority_id)));

REVOKE UPDATE ON TABLE public.note_tag FROM authenticated;

GRANT UPDATE (updated_at, updated_by, archived_at) ON TABLE public.note_tag TO authenticated;

CREATE POLICY "Users can update note_tag for notes in their accessible priorities" ON "public"."note_tag"
    FOR UPDATE
        USING (actor_id = user_contact_id ()
            OR EXISTS (
                SELECT
                    1
                FROM
                    note n
                    JOIN activity a ON a.id = n.activity_id
                WHERE
                    n.id = note_tag.note_id AND public.user_has_priority_access (auth.uid (), a.priority_id) AND get_tag_type (note_tag.tag_id) = 'toggle'))
                WITH CHECK (note_tag.actor_id = user_contact_id ());

