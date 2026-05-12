-- Create "upsert_session" function
CREATE FUNCTION "user"."upsert_session" ("user_id" uuid, "p_id" uuid, "p_priority_id" uuid, "p_at" tstzrange, "p_precedence" smallint, "p_pomodoro" smallint, "p_pomodoro_at" timestamptz, "p_archived_at" timestamptz, "p_updated_by" integer, "p_source" text DEFAULT 'active', "p_schedule_id" uuid DEFAULT NULL::uuid, "p_occurrence_at" timestamptz DEFAULT NULL::timestamp with time zone) RETURNS "public"."session" LANGUAGE plpgsql SET "search_path" = public, "user" AS $$
DECLARE
    v_row session;
BEGIN
    IF p_priority_id IS NOT NULL THEN
        PERFORM "user".assert_priority_access(user_id, p_priority_id);
    END IF;

    IF p_id IS NOT NULL AND EXISTS (
        SELECT
            1
        FROM
            session s
        WHERE
            s.id = p_id
            AND s.user_id <> upsert_session.user_id) THEN
        RAISE EXCEPTION 'Cannot modify another user''s session';
    END IF;

    INSERT INTO session (id, user_id, priority_id, at, precedence, pomodoro, pomodoro_at, archived_at, updated_by, source, schedule_id, occurrence_at)
        VALUES (
            COALESCE(p_id, uuidv7()),
            user_id,
            p_priority_id,
            p_at,
            COALESCE(p_precedence, 0),
            p_pomodoro,
            p_pomodoro_at,
            p_archived_at,
            COALESCE(p_updated_by, 0),
            COALESCE(p_source, 'active'),
            p_schedule_id,
            p_occurrence_at
        )
    ON CONFLICT (id)
        DO UPDATE SET
            priority_id = EXCLUDED.priority_id,
            at = EXCLUDED.at,
            precedence = EXCLUDED.precedence,
            pomodoro = EXCLUDED.pomodoro,
            pomodoro_at = EXCLUDED.pomodoro_at,
            archived_at = EXCLUDED.archived_at,
            updated_by = EXCLUDED.updated_by,
            -- Source/schedule_id/occurrence_at are immutable per session row;
            -- COALESCE so a partial update from the client doesn't clobber them.
            source = COALESCE(EXCLUDED.source, session.source),
            schedule_id = COALESCE(EXCLUDED.schedule_id, session.schedule_id),
            occurrence_at = COALESCE(EXCLUDED.occurrence_at, session.occurrence_at),
            updated_at = now()
    RETURNING * INTO v_row;

    RETURN v_row;
END;
$$;
-- Drop "upsert_session" function
DROP FUNCTION "user"."upsert_session" (uuid, uuid, uuid, tstzrange, smallint, smallint, timestamptz, timestamptz, integer);
