-- Modify "clear_thread_state" function
CREATE OR REPLACE FUNCTION "user"."clear_thread_state" ("user_id" uuid, "p_thread_id" uuid, "p_read_at" timestamptz DEFAULT now(), "p_bumped_at" timestamptz DEFAULT NULL::timestamp with time zone) RETURNS void LANGUAGE plpgsql SET "search_path" = public, "user" AS $$
#variable_conflict use_column
DECLARE
    v_priority_id uuid;
    v_threshold timestamptz;
BEGIN
    SELECT
        tp.priority_id INTO v_priority_id
    FROM
        thread_priority tp
    WHERE
        tp.thread_id = p_thread_id
        AND tp.user_id = clear_thread_state.user_id;
    IF v_priority_id IS NULL THEN
        RAISE EXCEPTION 'Thread not found';
    END IF;

    -- Freshness threshold for the read guard: the newest content visible to this
    -- user that they did NOT author themselves. A note the user wrote is content
    -- they have obviously seen, so it must not block their own read marker.
    -- Otherwise "read on web, reply, open another device" leaves the thread
    -- unread everywhere: the read marker is captured at open time, the user's own
    -- reply then advances thread.last_note_source_created_at past it, and the
    -- deferred /sync/thread-state push of that now-stale marker gets silently
    -- rejected. We therefore recompute the unscoped component as MAX over notes
    -- the user did not author (mirroring the unscoped filter the
    -- update_thread_on_note_change trigger applies to thread.last_note_source_created_at:
    -- non-draft, non-archived, access_contacts/access_groups both NULL), and keep
    -- the per-user scoped component (thread_state.last_note_source_created_at) as
    -- is. Truncated to ms to match client (JS Date) precision (see PRECISION
    -- BOUNDARY comment above).
    SELECT date_trunc('milliseconds',
               COALESCE(
                   GREATEST(
                       (SELECT MAX(n.source_created_at)
                        FROM note n
                        WHERE n.thread_id = p_thread_id
                          AND n.draft = FALSE
                          AND n.archived_at IS NULL
                          AND n.access_contacts IS NULL
                          AND n.access_groups IS NULL
                          AND n.created_by <> clear_thread_state.user_id),
                       ts.last_note_source_created_at),
                   t.created_at))
        INTO v_threshold
    FROM thread t
    LEFT JOIN thread_state ts
        ON ts.thread_id = t.id AND ts.user_id = clear_thread_state.user_id
    WHERE t.id = p_thread_id;

    INSERT INTO thread_state (user_id, thread_id, read_at, bumped_at)
        VALUES (clear_thread_state.user_id, p_thread_id, p_read_at, p_bumped_at)
    ON CONFLICT (user_id, thread_id)
        DO UPDATE SET
            read_at = CASE
                WHEN thread_state.read_at IS NULL
                    AND p_read_at >= v_threshold
                THEN p_read_at
                ELSE thread_state.read_at
            END,
            bumped_at = CASE WHEN p_bumped_at IS NOT NULL THEN p_bumped_at ELSE thread_state.bumped_at END,
            updated_at = now()
        WHERE
            p_bumped_at IS NOT NULL
            OR (thread_state.read_at IS NULL
                AND p_read_at >= v_threshold);
END;
$$;
