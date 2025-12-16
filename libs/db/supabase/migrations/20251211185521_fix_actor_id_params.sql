-- Fix tag RLS policies to use user_contact_id() instead of auth.uid()
DROP POLICY IF EXISTS "Users can view activity_tag in their accessible priorities" ON "public"."activity_tag";
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

DROP POLICY IF EXISTS "Users can insert activity_tag for activities in their accessible priorities" ON "public"."activity_tag";
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

DROP POLICY IF EXISTS "Users can update activity_tag for activities in their accessible priorities" ON "public"."activity_tag";
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

DROP POLICY IF EXISTS "Users can view note_tag in their accessible priorities" ON "public"."note_tag";
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

DROP POLICY IF EXISTS "Users can insert note_tag for notes in their accessible priorities" ON "public"."note_tag";
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

DROP POLICY IF EXISTS "Users can update note_tag for notes in their accessible priorities" ON "public"."note_tag";
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

-- Rename function parameters from p_user_id to p_actor_id for clarity
DROP FUNCTION IF EXISTS public.update_activity_tags(uuid, uuid, integer, jsonb);
CREATE OR REPLACE FUNCTION public.update_activity_tags (p_activity_id uuid, p_actor_id uuid, p_client_id integer, p_tag_updates jsonb)
    RETURNS void
    LANGUAGE plpgsql
    SECURITY DEFINER
    AS $function$
DECLARE
    tag_record record;
    tag_id_int integer;
    is_adding boolean;
    current_tag_type tag_type;
BEGIN
    IF p_activity_id IS NULL THEN
        RAISE EXCEPTION 'p_activity_id must be provided';
    END IF;
    FOR tag_record IN
    SELECT
        key,
        value
    FROM
        jsonb_each(p_tag_updates)
        LOOP
            tag_id_int := tag_record.key::integer;
            is_adding := tag_record.value::boolean;
            current_tag_type := get_tag_type (tag_id_int);
            IF is_adding THEN
                INSERT INTO activity_tag (actor_id, activity_id, occurrence, tag_id, updated_at, archived_at, updated_by)
                    VALUES (p_actor_id, p_activity_id, NULL, tag_id_int, now(), NULL, p_client_id)
                ON CONFLICT (actor_id, activity_id, occurrence, tag_id)
                    DO UPDATE SET
                        archived_at = NULL,
                        updated_at = now(),
                        updated_by = p_client_id;
            ELSE
                IF current_tag_type = 'toggle' THEN
                    UPDATE
                        activity_tag
                    SET
                        archived_at = now(),
                        updated_by = p_client_id
                    WHERE
                        activity_id = p_activity_id
                        AND tag_id = tag_id_int
                        AND archived_at IS NULL;
                ELSE
                    UPDATE
                        activity_tag
                    SET
                        archived_at = now(),
                        updated_by = p_client_id
                    WHERE
                        activity_id = p_activity_id
                        AND tag_id = tag_id_int
                        AND actor_id = p_actor_id
                        AND archived_at IS NULL;
                END IF;
            END IF;
        END LOOP;
END;
$function$;

DROP FUNCTION IF EXISTS public.update_note_tags(uuid, uuid, integer, jsonb);
CREATE OR REPLACE FUNCTION public.update_note_tags (p_note_id uuid, p_actor_id uuid, p_client_id integer, p_tag_updates jsonb)
    RETURNS void
    LANGUAGE plpgsql
    SECURITY DEFINER
    AS $function$
DECLARE
    tag_record record;
    tag_id_int integer;
    is_adding boolean;
    current_tag_type tag_type;
BEGIN
    IF p_note_id IS NULL THEN
        RAISE EXCEPTION 'p_note_id must be provided';
    END IF;
    FOR tag_record IN
    SELECT
        key,
        value
    FROM
        jsonb_each(p_tag_updates)
        LOOP
            tag_id_int := tag_record.key::integer;
            is_adding := tag_record.value::boolean;
            current_tag_type := get_tag_type (tag_id_int);
            IF is_adding THEN
                INSERT INTO note_tag (actor_id, note_id, tag_id, updated_at, archived_at, updated_by)
                    VALUES (p_actor_id, p_note_id, tag_id_int, now(), NULL, p_client_id)
                ON CONFLICT (actor_id, note_id, tag_id)
                    DO UPDATE SET
                        archived_at = NULL,
                        updated_at = now(),
                        updated_by = p_client_id;
            ELSE
                IF current_tag_type = 'toggle' THEN
                    UPDATE
                        note_tag
                    SET
                        archived_at = now(),
                        updated_by = p_client_id
                    WHERE
                        note_id = p_note_id
                        AND tag_id = tag_id_int
                        AND archived_at IS NULL;
                ELSE
                    UPDATE
                        note_tag
                    SET
                        archived_at = now(),
                        updated_by = p_client_id
                    WHERE
                        note_id = p_note_id
                        AND tag_id = tag_id_int
                        AND actor_id = p_actor_id
                        AND archived_at IS NULL;
                END IF;
            END IF;
        END LOOP;
END;
$function$;

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
