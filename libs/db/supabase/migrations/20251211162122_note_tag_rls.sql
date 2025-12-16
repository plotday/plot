-- Add RLS policies for note_tag table
CREATE POLICY "Users can view note_tag in their accessible priorities" ON "public"."note_tag"
    FOR SELECT
        USING (actor_id = auth.uid ()
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
        WITH CHECK (actor_id = auth.uid ()
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
        USING (actor_id = auth.uid ()
            OR EXISTS (
                SELECT
                    1
                FROM
                    note n
                    JOIN activity a ON a.id = n.activity_id
                WHERE
                    n.id = note_tag.note_id AND public.user_has_priority_access (auth.uid (), a.priority_id) AND get_tag_type (note_tag.tag_id) = 'toggle'))
                WITH CHECK (note_tag.actor_id = auth.uid ());

ALTER VIEW "public"."user_note" SET ( security_invoker = TRUE);
ALTER VIEW "public"."note_tags" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_note_tags" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_twist" SET ( security_invoker = TRUE);
ALTER VIEW "public"."activity_tags" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_activity_unread" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_activity" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_activity_exception" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_activity_tags" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_priority" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_unread" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_tags" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_child" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_settings_inherited" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_priority_base" SET ( security_invoker = TRUE);
ALTER VIEW "public"."actor" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_child_twist" SET ( security_invoker = TRUE);
