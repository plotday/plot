-- Function to upsert activities, handling recurrence series conversion
CREATE OR REPLACE FUNCTION public.upsert_activity (p_id uuid, p_user_id uuid, p_updated_by integer, p_deleted_at timestamptz DEFAULT NULL, p_priority_id uuid DEFAULT NULL, p_path ltree DEFAULT NULL, p_draft boolean DEFAULT NULL, p_private boolean DEFAULT NULL, p_do_on date DEFAULT NULL, p_at tstzrange DEFAULT NULL, p_on daterange DEFAULT NULL, p_duration interval DEFAULT NULL, p_done_at timestamptz DEFAULT NULL, p_title text DEFAULT NULL, p_note text DEFAULT NULL, p_order double precision DEFAULT NULL, p_recurrence_rule text DEFAULT NULL, p_recurrence_exdates timestamptz[] DEFAULT NULL, p_recurrence_dates timestamptz[] DEFAULT NULL, p_series uuid DEFAULT NULL, -- This maps to occurrence_root_id
p_occurrence_start timestamptz DEFAULT NULL -- This maps to occurrence_original_start
)
    RETURNS uuid
    LANGUAGE plpgsql
    SECURITY DEFINER
    AS $$
DECLARE
    _activity_id uuid;
    _occurrence_root_id uuid;
    _occurrence_original_start timestamptz;
    _existing_path ltree;
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
        -- Get path from the root recurring activity if not provided
        IF p_path IS NULL THEN
            SELECT
                path INTO _existing_path
            FROM
                activity
            WHERE
                id = _occurrence_root_id;
            p_path := _existing_path;
        END IF;
        -- Insert new exception activity
        INSERT INTO activity (id, updated_by, deleted_at, priority_id, path, draft, private, do_on, at, "on", duration, done_at, title, note, "order", recurrence_rule, recurrence_exdates, recurrence_dates, occurrence_root_id, occurrence_original_start)
            VALUES (_activity_id, p_updated_by, p_deleted_at, COALESCE(p_priority_id, (
                        SELECT
                            priority_id
                        FROM activity
                        WHERE
                            id = _occurrence_root_id)),
                p_path,
                COALESCE(p_draft, FALSE),
                COALESCE(p_private, FALSE),
                p_do_on,
                p_at,
                p_on,
                p_duration,
                p_done_at,
                p_title,
                p_note,
                p_order,
                NULL, -- Exceptions don't have their own recurrence rules
                NULL,
                NULL,
                _occurrence_root_id,
                _occurrence_original_start);
        RETURN _activity_id;
    END IF;
    -- Handle path updates for recurring activity instances
    IF _occurrence_root_id IS NOT NULL AND p_path IS NOT NULL THEN
        -- Update path on the root recurring activity, not the instance
        UPDATE
            activity
        SET
            path = p_path,
            updated_at = now(),
            updated_by = p_updated_by
        WHERE
            id = _occurrence_root_id;
        -- Don't update the path on the exception instance
        p_path := NULL;
    END IF;
    -- Standard upsert for regular activities or existing exception records
    INSERT INTO activity (id, updated_by, deleted_at, priority_id, path, draft, private, do_on, at, "on", duration, done_at, title, note, "order", recurrence_rule, recurrence_exdates, recurrence_dates, occurrence_root_id, occurrence_original_start)
        VALUES (COALESCE(p_id, gen_random_uuid_v7 ()), p_updated_by, p_deleted_at, p_priority_id, p_path, COALESCE(p_draft, FALSE), COALESCE(p_private, FALSE), p_do_on, p_at, p_on, p_duration, p_done_at, p_title, p_note, COALESCE(p_order, public.order_first ()), p_recurrence_rule, p_recurrence_exdates, p_recurrence_dates, _occurrence_root_id, _occurrence_original_start)
    ON CONFLICT (id)
        DO UPDATE SET
            updated_by = EXCLUDED.updated_by,
            updated_at = now(),
            deleted_at = COALESCE(EXCLUDED.deleted_at, activity.deleted_at),
            priority_id = COALESCE(EXCLUDED.priority_id, activity.priority_id),
            path = COALESCE(EXCLUDED.path, activity.path),
            draft = COALESCE(EXCLUDED.draft, activity.draft),
            private = COALESCE(EXCLUDED.private, activity.private),
            do_on = COALESCE(EXCLUDED.do_on, activity.do_on),
            at = COALESCE(EXCLUDED.at, activity.at),
            "on" = COALESCE(EXCLUDED.on, activity.on),
            duration = COALESCE(EXCLUDED.duration, activity.duration),
            done_at = COALESCE(EXCLUDED.done_at, activity.done_at),
            title = COALESCE(EXCLUDED.title, activity.title),
            note = COALESCE(EXCLUDED.note, activity.note),
            "order" = COALESCE(EXCLUDED."order", activity."order"),
            recurrence_rule = COALESCE(EXCLUDED.recurrence_rule, activity.recurrence_rule),
            recurrence_exdates = COALESCE(EXCLUDED.recurrence_exdates, activity.recurrence_exdates),
            recurrence_dates = COALESCE(EXCLUDED.recurrence_dates, activity.recurrence_dates)
        RETURNING
            id INTO _activity_id;
    RETURN _activity_id;
END;
$$;

