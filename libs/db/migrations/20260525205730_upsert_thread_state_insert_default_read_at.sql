-- Fix `upsert_thread_state` INSERT branch so it respects `p_set_read_at`.
--
-- Before this migration the INSERT branch unconditionally used `p_read_at`
-- (which defaults to NULL). That made any payload like `{active: true}`
-- create a thread_state row with read_at = NULL whenever the row didn't
-- already exist, which the `user.thread` view then flipped to
-- `unread = true`. The previous migration (20260525202855) added the
-- ON CONFLICT guard but missed the INSERT branch — visible when the user
-- clicked "To do" on a thread that they themselves authored (no peer
-- trigger fired, so no thread_state row existed yet).
--
-- After this migration: if the caller did not opt in to writing `read_at`
-- (`p_set_read_at = false`, the default), the INSERT defaults to `now()`
-- so the new row reads as acknowledged. Callers that explicitly want a
-- fresh row marked unread (e.g. `markThreadUnreadForOthers`) pass
-- `p_set_read_at: true` with `p_read_at` omitted (= NULL).

CREATE OR REPLACE FUNCTION "user".upsert_thread_state (
    user_id uuid,
    p_thread_id uuid,
    p_active boolean DEFAULT FALSE,
    p_task boolean DEFAULT FALSE,
    p_to_read boolean DEFAULT FALSE,
    p_urgent boolean DEFAULT FALSE,
    p_importance smallint DEFAULT 50,
    p_read_at timestamptz DEFAULT NULL::timestamptz,
    p_bumped_at timestamptz DEFAULT NULL::timestamptz,
    p_note_created_at timestamptz DEFAULT NULL::timestamptz,
    p_order double precision DEFAULT NULL,
    p_on daterange DEFAULT NULL,
    p_at tstzrange DEFAULT NULL,
    p_set_active boolean DEFAULT FALSE,
    p_set_task boolean DEFAULT FALSE,
    p_set_to_read boolean DEFAULT FALSE,
    p_set_urgent boolean DEFAULT FALSE,
    p_set_importance boolean DEFAULT FALSE,
    p_set_read_at boolean DEFAULT FALSE,
    p_set_order boolean DEFAULT FALSE,
    p_set_on boolean DEFAULT FALSE,
    p_set_at boolean DEFAULT FALSE
)
    RETURNS thread_state
    LANGUAGE plpgsql
    SET search_path TO 'public', 'user'
    AS $function$
#variable_conflict use_column
DECLARE
    v_priority_id uuid;
    v_row thread_state;
BEGIN
    SELECT
        tp.priority_id INTO v_priority_id
    FROM
        thread_priority tp
    WHERE
        tp.thread_id = p_thread_id
        AND tp.user_id = upsert_thread_state.user_id;
    IF v_priority_id IS NULL THEN
        RAISE EXCEPTION 'Thread not found';
    END IF;

    INSERT INTO thread_state (user_id, thread_id, active, task, to_read, urgent, importance, read_at, bumped_at, "order", "on", "at")
        VALUES (
            upsert_thread_state.user_id,
            p_thread_id,
            COALESCE(p_active, FALSE),
            COALESCE(p_task, FALSE),
            COALESCE(p_to_read, FALSE),
            COALESCE(p_urgent, FALSE),
            COALESCE(p_importance, 50),
            -- If the caller didn't opt in to writing read_at, default to now()
            -- so a brand-new row doesn't accidentally signal "unread". Without
            -- this guard a payload like {active: true} on a thread with no
            -- prior thread_state row would insert read_at=NULL and the
            -- user.thread view would flip unread=true.
            CASE WHEN p_set_read_at THEN p_read_at ELSE now() END,
            p_bumped_at,
            p_order,
            p_on,
            p_at
        )
    ON CONFLICT (user_id, thread_id)
        DO UPDATE SET
            active = CASE WHEN p_set_active THEN EXCLUDED.active ELSE thread_state.active END,
            task = CASE WHEN p_set_task THEN EXCLUDED.task ELSE thread_state.task END,
            to_read = CASE WHEN p_set_to_read THEN EXCLUDED.to_read ELSE thread_state.to_read END,
            urgent = CASE WHEN p_set_urgent THEN EXCLUDED.urgent ELSE thread_state.urgent END,
            importance = CASE WHEN p_set_importance THEN EXCLUDED.importance ELSE thread_state.importance END,
            "order" = CASE WHEN p_set_order THEN EXCLUDED."order" ELSE thread_state."order" END,
            "on" = CASE WHEN p_set_on THEN EXCLUDED."on" ELSE thread_state."on" END,
            "at" = CASE WHEN p_set_at THEN EXCLUDED."at" ELSE thread_state."at" END,
            read_at = CASE
                -- Caller didn't opt in to writing read_at → preserve existing.
                WHEN NOT p_set_read_at THEN thread_state.read_at
                -- Race condition: user read after the note was created → preserve their read
                -- Truncate to ms precision (see PRECISION BOUNDARY comment above)
                WHEN p_note_created_at IS NOT NULL
                    AND thread_state.read_at IS NOT NULL
                    AND thread_state.read_at >= date_trunc('milliseconds', p_note_created_at)
                THEN thread_state.read_at
                -- Caller opted in: use their value (NULL = mark unread)
                ELSE EXCLUDED.read_at
            END,
            bumped_at = CASE WHEN p_bumped_at IS NOT NULL THEN p_bumped_at ELSE thread_state.bumped_at END,
            updated_at = now()
    RETURNING * INTO v_row;

    RETURN v_row;
END;
$function$;
