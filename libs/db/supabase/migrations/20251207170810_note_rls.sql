DROP FUNCTION IF EXISTS "public"."upsert_activity" (p_id uuid, p_user_id uuid, p_updated_by integer, p_archived_at timestamp with time zone, p_priority_id uuid, p_draft boolean, p_private boolean, p_at tstzrange, p_on daterange, p_duration interval, p_done_at timestamp with time zone, p_title text, p_preview text, p_order double precision, p_recurrence_rule text, p_recurrence_exdates timestamp with time zone[], p_recurrence_dates timestamp with time zone[], p_series uuid, p_occurrence_start timestamp with time zone);

SET check_function_bodies = OFF;

CREATE OR REPLACE FUNCTION public.upsert_activity (p_id uuid, p_user_id uuid, p_updated_by integer, p_archived_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_priority_id uuid DEFAULT NULL::uuid, p_draft boolean DEFAULT NULL::boolean, p_private boolean DEFAULT NULL::boolean, p_at tstzrange DEFAULT NULL::tstzrange, p_on daterange DEFAULT NULL::dateRANGE, p_duration interval DEFAULT NULL::interval, p_done_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_title text DEFAULT NULL::text, p_preview text DEFAULT NULL::text, p_assignee_id uuid DEFAULT NULL::uuid, p_order double precision DEFAULT NULL::double precision, p_recurrence_rule text DEFAULT NULL::text, p_recurrence_exdates timestamp with time zone[] DEFAULT NULL::timestamp with time zone[], p_recurrence_dates timestamp with time zone[] DEFAULT NULL::timestamp with time zone[], p_series uuid DEFAULT NULL::uuid, p_occurrence_start timestamp with time zone DEFAULT NULL::timestamp with time zone)
    RETURNS uuid
    LANGUAGE plpgsql
    SECURITY DEFINER
    AS $function$
DECLARE
    _activity_id uuid;
    _occurrence_root_id uuid;
    _occurrence_original_start timestamptz;
BEGIN
    -- Convert series field to occurrence_root_id
    _occurrence_root_id := p_series;
    _occurrence_original_start := p_occurrence_start;
    -- Check if this is an update to an existing activity
    IF p_id IS NOT NULL THEN
        SELECT
            id INTO _activity_id
        FROM
            activity
        WHERE
            id = p_id;
    END IF;
    -- If updating a synthetic recurrence instance (generated ID), create a new exception record
    IF _activity_id IS NULL AND _occurrence_root_id IS NOT NULL AND _occurrence_original_start IS NOT NULL THEN
        -- This is a new exception for a recurring activity
        _activity_id := gen_random_uuid_v7 ();
        -- Insert new exception activity
        INSERT INTO activity (id, updated_by, archived_at, priority_id, draft, private, at, "on", duration, done_at, title, preview, assignee_id, "order", recurrence_rule, recurrence_exdates, recurrence_dates, occurrence_root_id, occurrence_original_start)
            VALUES (_activity_id, p_updated_by, p_archived_at, COALESCE(p_priority_id, (
                        SELECT
                            priority_id
                        FROM activity
                        WHERE
                            id = _occurrence_root_id)),
                COALESCE(p_draft, FALSE),
                COALESCE(p_private, FALSE),
                p_at,
                p_on,
                p_duration,
                p_done_at,
                p_title,
                p_preview,
                p_assignee_id,
                p_order,
                NULL, -- Exceptions don't have their own recurrence rules
                NULL,
                NULL,
                _occurrence_root_id,
                _occurrence_original_start);
        RETURN _activity_id;
    END IF;
    -- Standard upsert for regular activities or existing exception records
    INSERT INTO activity (id, updated_by, archived_at, priority_id, draft, private, at, "on", duration, done_at, title, preview, assignee_id, "order", recurrence_rule, recurrence_exdates, recurrence_dates, occurrence_root_id, occurrence_original_start)
        VALUES (COALESCE(p_id, gen_random_uuid_v7 ()), p_updated_by, p_archived_at, p_priority_id, COALESCE(p_draft, FALSE), COALESCE(p_private, FALSE), p_at, p_on, p_duration, p_done_at, p_title, p_preview, p_assignee_id, COALESCE(p_order, public.order_first ()), p_recurrence_rule, p_recurrence_exdates, p_recurrence_dates, _occurrence_root_id, _occurrence_original_start)
    ON CONFLICT (id)
        DO UPDATE SET
            updated_by = EXCLUDED.updated_by,
            updated_at = now(),
            archived_at = COALESCE(EXCLUDED.archived_at, activity.archived_at),
            priority_id = COALESCE(EXCLUDED.priority_id, activity.priority_id),
            draft = COALESCE(EXCLUDED.draft, activity.draft),
            private = COALESCE(EXCLUDED.private, activity.private),
            at = COALESCE(EXCLUDED.at, activity.at),
            "on" = COALESCE(EXCLUDED.on, activity.on),
            duration = COALESCE(EXCLUDED.duration, activity.duration),
            done_at = COALESCE(EXCLUDED.done_at, activity.done_at),
            title = COALESCE(EXCLUDED.title, activity.title),
            preview = COALESCE(EXCLUDED.preview, activity.preview),
            assignee_id = COALESCE(EXCLUDED.assignee_id, activity.assignee_id),
            "order" = COALESCE(EXCLUDED."order", activity."order"),
            recurrence_rule = COALESCE(EXCLUDED.recurrence_rule, activity.recurrence_rule),
            recurrence_exdates = COALESCE(EXCLUDED.recurrence_exdates, activity.recurrence_exdates),
            recurrence_dates = COALESCE(EXCLUDED.recurrence_dates, activity.recurrence_dates)
        RETURNING
            id INTO _activity_id;
    RETURN _activity_id;
END;
$function$;

CREATE POLICY "Users can insert notes for accessible activities" ON "public"."note" AS permissive
    FOR INSERT TO public
        WITH CHECK (((author_id = user_contact_id ()) AND (EXISTS (
            SELECT
                1
            FROM
                activity
            WHERE ((activity.id = note.activity_id) AND user_has_priority_access (auth.uid (), activity.priority_id))))));

CREATE POLICY "Users can update notes for accessible activities" ON "public"."note" AS permissive
    FOR UPDATE TO public
        USING ((EXISTS (
            SELECT
                1
            FROM
                activity
            WHERE ((activity.id = note.activity_id) AND user_has_priority_access (auth.uid (), activity.priority_id)))))
        WITH CHECK ((EXISTS (
            SELECT
                1
            FROM
                activity
            WHERE ((activity.id = note.activity_id) AND user_has_priority_access (auth.uid (), activity.priority_id)))));

CREATE POLICY "Users can view notes for accessible activities" ON "public"."note" AS permissive
    FOR SELECT TO public
        USING ((EXISTS (
            SELECT
                1
            FROM
                activity
            WHERE ((activity.id = note.activity_id) AND user_has_priority_access (auth.uid (), activity.priority_id)))));

ALTER VIEW "public"."activity_tags" SET ( security_invoker = TRUE);
ALTER VIEW "public"."notes" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_activity_unread" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_activity" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_activity_exception" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_activity_tags" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_active_actions" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_priority" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_unread" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_tags" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_child" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_settings_inherited" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_priority_base" SET ( security_invoker = TRUE);
ALTER VIEW "public"."actor" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_child_twist" SET ( security_invoker = TRUE);
