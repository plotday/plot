-- Share or unshare a thread with contacts.
-- Adds/removes contact_ids from thread.contacts, which fires the
-- file_thread_priority_peers trigger to create thread_priority rows.
-- Also inserts thread_state rows for newly-added users so the thread
-- appears as unread for them.
CREATE OR REPLACE FUNCTION public.share_thread (
    p_user_id uuid,
    p_thread_id uuid,
    p_add_contact_ids uuid[] DEFAULT ARRAY[]::uuid[],
    p_remove_contact_ids uuid[] DEFAULT ARRAY[]::uuid[],
    -- Optional per-contact role assignments. Shape:
    --   [ { "contactId": "<uuid>", "role": "<role_id>" }, ... ]
    -- Applied to thread.contact_meta as { role, addedBy = p_user_id } for
    -- each entry. Entries whose role is the link type's default may be
    -- omitted by the caller (the API layer normalizes this). Entries for
    -- contacts being removed are ignored.
    p_contact_roles jsonb DEFAULT '[]'::jsonb,
    -- Optional role changes on existing contacts. Same shape as
    -- p_contact_roles. Applied after add/remove. Caller is responsible for
    -- ensuring contactIds are already in thread.contacts.
    p_role_changes jsonb DEFAULT '[]'::jsonb
)
    RETURNS jsonb
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $function$
DECLARE
    v_current_contacts uuid[];
    v_new_contacts uuid[];
    v_current_meta jsonb;
    v_new_meta jsonb;
    v_needs_invitation uuid[];
    r RECORD;
    v_role RECORD;
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

    -- Fetch current contacts and meta
    SELECT contacts, contact_meta INTO v_current_contacts, v_current_meta
    FROM thread
    WHERE id = p_thread_id;

    IF v_current_contacts IS NULL THEN
        v_current_contacts := ARRAY[]::uuid[];
    END IF;
    IF v_current_meta IS NULL THEN
        v_current_meta := '{}'::jsonb;
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

    -- Compute new contact_meta:
    --   1. Drop entries for removed contacts.
    --   2. Apply p_contact_roles for added contacts.
    --   3. Apply p_role_changes for existing contacts.
    v_new_meta := v_current_meta;

    -- Strip removed contacts' meta entries
    IF array_length(p_remove_contact_ids, 1) > 0 THEN
        FOR v_role IN SELECT unnest(p_remove_contact_ids) AS cid LOOP
            v_new_meta := v_new_meta - (v_role.cid::text);
        END LOOP;
    END IF;

    -- Apply add-time role assignments
    FOR v_role IN
        SELECT
            (entry->>'contactId')::uuid AS contact_id,
            entry->>'role' AS role
        FROM jsonb_array_elements(COALESCE(p_contact_roles, '[]'::jsonb)) AS entry
        WHERE entry->>'contactId' IS NOT NULL AND entry->>'role' IS NOT NULL
    LOOP
        v_new_meta := v_new_meta || jsonb_build_object(
            v_role.contact_id::text,
            jsonb_build_object('role', v_role.role, 'addedBy', p_user_id::text)
        );
    END LOOP;

    -- Apply role changes on existing contacts. addedBy is preserved from
    -- the existing entry when present, otherwise falls back to caller.
    FOR v_role IN
        SELECT
            (entry->>'contactId')::uuid AS contact_id,
            entry->>'role' AS role
        FROM jsonb_array_elements(COALESCE(p_role_changes, '[]'::jsonb)) AS entry
        WHERE entry->>'contactId' IS NOT NULL AND entry->>'role' IS NOT NULL
    LOOP
        v_new_meta := v_new_meta || jsonb_build_object(
            v_role.contact_id::text,
            jsonb_build_object(
                'role', v_role.role,
                'addedBy', COALESCE(
                    v_new_meta->(v_role.contact_id::text)->>'addedBy',
                    p_user_id::text
                )
            )
        );
    END LOOP;

    -- Update thread — fires file_thread_priority_peers trigger
    UPDATE thread
    SET contacts = v_new_contacts,
        contact_meta = v_new_meta
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
        'contact_meta', v_new_meta,
        'needs_invitation', to_jsonb(v_needs_invitation)
    );
END;
$function$;

-- Add or remove groups from a thread's group list.
CREATE OR REPLACE FUNCTION public.share_thread_with_groups (
    p_user_id uuid,
    p_thread_id uuid,
    p_add_group_ids uuid[] DEFAULT ARRAY[]::uuid[],
    p_remove_group_ids uuid[] DEFAULT ARRAY[]::uuid[]
)
    RETURNS jsonb
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $function$
DECLARE
    v_current_groups uuid[];
    v_new_groups uuid[];
    v_group RECORD;
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM thread_priority tp
        WHERE tp.thread_id = p_thread_id
          AND tp.user_id = p_user_id
    ) THEN
        RAISE EXCEPTION 'User does not have access to this thread';
    END IF;

    FOR v_group IN
        SELECT g.id, g.type
        FROM unnest(p_add_group_ids) AS arr(id)
        JOIN "group" g ON g.id = arr.id
        WHERE g.archived_at IS NULL
    LOOP
        IF v_group.type = 'announce' THEN
            -- Announce groups stay admin-only post (existing inverted role:
            -- everyone receives, only admins broadcast).
            IF NOT EXISTS (
                SELECT 1 FROM group_admin
                WHERE group_id = v_group.id AND user_id = p_user_id
            ) THEN
                RAISE EXCEPTION 'Only admins can add announce groups to threads';
            END IF;
        ELSE
            -- Anyone with picker visibility can address the group. Drives off
            -- the same user.group view that decides whether the chip renders,
            -- so "can see it" and "can post to it" are the same gate. Posting
            -- never grants the poster read access to existing threads — only
            -- members receive what's sent (via file_thread_priority_for_group_members).
            IF NOT EXISTS (
                SELECT 1 FROM "user"."group" ug
                WHERE ug.user_id = p_user_id AND ug.id = v_group.id
            ) THEN
                RAISE EXCEPTION 'User does not have permission to add this group';
            END IF;
        END IF;
    END LOOP;

    SELECT groups INTO v_current_groups
    FROM thread
    WHERE id = p_thread_id;

    IF v_current_groups IS NULL THEN
        v_current_groups := ARRAY[]::uuid[];
    END IF;

    SELECT COALESCE(array_agg(DISTINCT gid), ARRAY[]::uuid[])
    INTO v_new_groups
    FROM (
        SELECT unnest(v_current_groups) AS gid
        UNION
        SELECT unnest(p_add_group_ids)
    ) all_groups
    WHERE gid != ALL(COALESCE(p_remove_group_ids, ARRAY[]::uuid[]));

    UPDATE thread
    SET groups = v_new_groups
    WHERE id = p_thread_id;

    RETURN jsonb_build_object('groups', to_jsonb(v_new_groups));
END;
$function$;