-- Recompute outstanding_tasks on a per-user schedule.
-- Checks notes with active todo tags and links with non-done status.
CREATE OR REPLACE FUNCTION recompute_outstanding_tasks(
    p_thread_id uuid,
    p_user_id uuid
) RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    v_has_outstanding boolean;
BEGIN
    -- Check 1: Notes with active todo tag for any of the user's contacts
    SELECT EXISTS(
        SELECT 1
        FROM note_tag nt
        JOIN note n ON n.id = nt.note_id
        JOIN contact c ON c.id = nt.actor_id
        WHERE n.thread_id = p_thread_id
          AND c.user_id = p_user_id
          AND nt.tag_id = 1  -- Tag.todo
          AND nt.archived_at IS NULL
          AND n.archived_at IS NULL
    ) INTO v_has_outstanding;

    -- Check 2: Links assigned to user (or unassigned) with non-done status
    IF NOT v_has_outstanding THEN
        SELECT EXISTS(
            SELECT 1
            FROM link l
            JOIN contact c ON c.user_id = p_user_id
            JOIN priority_twist pt ON pt.id = l.created_by
            JOIN twist tw ON tw.id = pt.twist_id
            CROSS JOIN LATERAL jsonb_array_elements(tw.permissions -> '_providers') AS provider
            CROSS JOIN LATERAL jsonb_array_elements(provider -> 'linkTypes') AS lt
            CROSS JOIN LATERAL jsonb_array_elements(lt -> 'statuses') AS status_def
            WHERE l.thread_id = p_thread_id
              AND l.status IS NOT NULL
              AND (l.assignee_id IS NULL OR l.assignee_id = c.id)
              AND lt ->> 'type' = l.type
              AND status_def ->> 'status' = l.status
              AND COALESCE((status_def ->> 'done')::boolean, false) = false
        ) INTO v_has_outstanding;
    END IF;

    -- Update the per-user schedule
    UPDATE schedule
    SET outstanding_tasks = v_has_outstanding
    WHERE thread_id = p_thread_id
      AND user_id = p_user_id
      AND occurrence IS NULL;
END;
$$;
