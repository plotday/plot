-- Upsert thread association with access control
-- Validates user has access to both parent and child thread priorities
-- Handles "move" case: if child already associated elsewhere, archives old association
CREATE OR REPLACE FUNCTION "user".upsert_thread_association (
    user_id uuid,
    p_association jsonb
)
    RETURNS thread_association
    LANGUAGE plpgsql
    SET search_path TO 'public', 'user'
    AS $function$
DECLARE
    v_id uuid;
    v_parent_thread_id uuid;
    v_child_thread_id uuid;
    v_parent_priority_id uuid;
    v_child_priority_id uuid;
    v_existing_id uuid;
    v_result thread_association;
BEGIN
    -- Extract fields
    v_id := (p_association ->> 'id')::uuid;
    v_parent_thread_id := (p_association ->> 'parent_thread_id')::uuid;
    v_child_thread_id := (p_association ->> 'child_thread_id')::uuid;

    -- Resolve parent/child from existing association if updating
    IF v_parent_thread_id IS NULL AND v_child_thread_id IS NULL AND v_id IS NOT NULL THEN
        SELECT
            ta.parent_thread_id, ta.child_thread_id
            INTO v_parent_thread_id, v_child_thread_id
        FROM
            thread_association ta
        WHERE
            ta.id = v_id;
    END IF;

    -- Must have both parent and child
    IF v_parent_thread_id IS NULL THEN
        RAISE EXCEPTION 'parent_thread_id must be provided';
    END IF;
    IF v_child_thread_id IS NULL THEN
        RAISE EXCEPTION 'child_thread_id must be provided';
    END IF;

    -- Cannot associate a thread with itself
    IF v_parent_thread_id = v_child_thread_id THEN
        RAISE EXCEPTION 'Cannot associate a thread with itself';
    END IF;

    -- Check access to parent thread via thread_priority
    SELECT tp.priority_id INTO v_parent_priority_id
    FROM thread_priority tp
    WHERE tp.thread_id = v_parent_thread_id
      AND tp.user_id = upsert_thread_association.user_id;

    IF v_parent_priority_id IS NULL THEN
        IF NOT EXISTS (SELECT 1 FROM thread WHERE id = v_parent_thread_id) THEN
            RAISE EXCEPTION 'Parent thread not found';
        END IF;
        RAISE EXCEPTION 'User does not have access to parent thread';
    END IF;
    IF NOT user_has_priority_access(upsert_thread_association.user_id, v_parent_priority_id) THEN
        RAISE EXCEPTION 'User does not have access to parent thread priority';
    END IF;

    -- Check access to child thread via thread_priority
    SELECT tp.priority_id INTO v_child_priority_id
    FROM thread_priority tp
    WHERE tp.thread_id = v_child_thread_id
      AND tp.user_id = upsert_thread_association.user_id;

    IF v_child_priority_id IS NULL THEN
        IF NOT EXISTS (SELECT 1 FROM thread WHERE id = v_child_thread_id) THEN
            RAISE EXCEPTION 'Child thread not found';
        END IF;
        RAISE EXCEPTION 'User does not have access to child thread';
    END IF;

    -- Resolve existing association ID based on unique constraints
    -- Try to find an existing active association for this child (a child
    -- can only be actively associated with one parent at a time)
    IF v_id IS NULL THEN
        SELECT ta.id INTO v_existing_id
        FROM thread_association ta
        WHERE ta.parent_thread_id = v_parent_thread_id
          AND ta.child_thread_id = v_child_thread_id
          AND ta.archived_at IS NULL;

        IF v_existing_id IS NOT NULL THEN
            v_id := v_existing_id;
        END IF;
    END IF;

    -- Archive any existing active association for this child with a different parent
    -- (handles the "move to different event" case)
    UPDATE thread_association
    SET archived_at = now()
    WHERE child_thread_id = v_child_thread_id
      AND archived_at IS NULL
      AND (v_id IS NULL OR id != v_id)
      AND parent_thread_id != v_parent_thread_id;

    -- Generate id if not provided
    IF v_id IS NULL THEN
        v_id := uuidv7();
    END IF;

    -- Perform the upsert
    INSERT INTO thread_association (id, parent_thread_id, child_thread_id, "order", archived_at)
        VALUES (
            v_id,
            v_parent_thread_id,
            v_child_thread_id,
            COALESCE((p_association ->> 'order')::double precision, public.order_first()),
            (p_association ->> 'archived_at')::timestamptz
        )
    ON CONFLICT (id)
        DO UPDATE SET
            "order" = CASE WHEN p_association ? 'order' THEN
                (p_association ->> 'order')::double precision
            ELSE
                thread_association."order"
            END,
            archived_at = CASE WHEN p_association ? 'archived_at' THEN
                (p_association ->> 'archived_at')::timestamptz
            ELSE
                thread_association.archived_at
            END
    RETURNING * INTO v_result;

    RETURN v_result;
END;
$function$;
