-- Modify "share_thread" function
CREATE OR REPLACE FUNCTION "public"."share_thread" ("p_user_id" uuid, "p_thread_id" uuid, "p_add_contact_ids" uuid[] DEFAULT ARRAY[]::uuid[], "p_remove_contact_ids" uuid[] DEFAULT ARRAY[]::uuid[]) RETURNS jsonb LANGUAGE plpgsql SET "search_path" = public AS $$
DECLARE
    v_current_contacts uuid[];
    v_new_contacts uuid[];
    v_needs_invitation uuid[];
    r RECORD;
BEGIN
    -- Validate caller has access to this thread
    IF NOT EXISTS (
        SELECT 1
        FROM thread_priority tp
        WHERE tp.thread_id = p_thread_id
          AND tp.user_id = p_user_id
    ) THEN
        RAISE EXCEPTION 'User does not have access to this thread';
    END IF;

    -- Fetch current contacts
    SELECT contacts INTO v_current_contacts
    FROM thread
    WHERE id = p_thread_id;

    IF v_current_contacts IS NULL THEN
        v_current_contacts := ARRAY[]::uuid[];
    END IF;

    -- Compute new contacts: (current + add) - remove, deduplicated
    SELECT COALESCE(array_agg(DISTINCT cid), ARRAY[]::uuid[])
    INTO v_new_contacts
    FROM (
        SELECT unnest(v_current_contacts) AS cid
        UNION
        SELECT unnest(p_add_contact_ids)
    ) all_contacts
    WHERE cid != ALL(COALESCE(p_remove_contact_ids, ARRAY[]::uuid[]));

    -- Update thread.contacts — fires file_thread_priority_peers trigger
    UPDATE thread
    SET contacts = v_new_contacts
    WHERE id = p_thread_id;

    -- For each newly-added contact linked to a user, create thread_state
    -- so the thread appears as unread for them. The default booleans
    -- (active/task/to_read = FALSE) and importance (50) come from the
    -- table defaults.
    FOR r IN
        SELECT DISTINCT uc.user_id AS peer_user_id
        FROM unnest(p_add_contact_ids) AS arr(contact_id)
        JOIN user_contact uc
          ON uc.contact_id = arr.contact_id
         AND uc.linked = TRUE
         AND uc.archived_at IS NULL
        WHERE uc.user_id IS DISTINCT FROM p_user_id
    LOOP
        -- Assign a deterministic state_order on insert. NULL state_order
        -- makes the Flutter Doing/unread-cluster drag-reorder land at the
        -- end of the null-order group instead of where the user released
        -- it (see Thread.order's doc for the full failure mode). Format
        -- mirrors Flutter's Order.first(): `-millisecondsSinceEpoch +
        -- random()` so new rows sort near the top of their cluster in
        -- ascending order.
        INSERT INTO thread_state (user_id, thread_id, "order")
        VALUES (
            r.peer_user_id,
            p_thread_id,
            (-EXTRACT(EPOCH FROM clock_timestamp()) * 1000) + random()
        )
        ON CONFLICT (user_id, thread_id) DO NOTHING;
    END LOOP;

    -- Collect contact_ids that need invitation emails (not linked to any user)
    SELECT COALESCE(array_agg(arr.contact_id), ARRAY[]::uuid[])
    INTO v_needs_invitation
    FROM unnest(p_add_contact_ids) AS arr(contact_id)
    WHERE NOT EXISTS (
        SELECT 1
        FROM user_contact uc
        WHERE uc.contact_id = arr.contact_id
          AND uc.linked = TRUE
          AND uc.archived_at IS NULL
    );

    RETURN jsonb_build_object(
        'contacts', to_jsonb(v_new_contacts),
        'needs_invitation', to_jsonb(v_needs_invitation)
    );
END;
$$;

-- Backfill state_order for thread_state rows where order IS NULL. NULL
-- order makes drag-reorder in the Flutter unread cluster land at the
-- tail of the null-order group rather than where the user released
-- it (Thread.order falls back to Order.lowerBound, and Order.between
-- (lowerBound, lowerBound) returns a value strictly greater than any
-- still-null neighbour). The new value preserves the previous visual
-- order (rows with no state_order sorted by thread_id ASC within the
-- unread cluster) by giving earlier ids smaller (more negative)
-- orders, while staying strictly above any real, recently-assigned
-- order (which are around -1.7e12; lowerBound is -1.0e13). Writes
-- bump thread_state.updated_at via the existing trigger so clients
-- re-sync the new values.
UPDATE public.thread_state ts
SET "order" = -1e13 + sub.rn * 0.001
FROM (
    SELECT
        thread_id,
        user_id,
        ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY thread_id) AS rn
    FROM public.thread_state
    WHERE "order" IS NULL
) sub
WHERE ts.thread_id = sub.thread_id
  AND ts.user_id = sub.user_id
  AND ts."order" IS NULL;
