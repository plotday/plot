-- Share or unshare a thread with contacts.
-- Adds/removes contact_ids from thread.contacts, which fires the
-- file_thread_priority_peers trigger to create thread_priority rows.
-- Also inserts thread_unread rows for newly-added users so the thread
-- appears as unread for them.
CREATE OR REPLACE FUNCTION public.share_thread (
    p_user_id uuid,
    p_thread_id uuid,
    p_add_contact_ids uuid[] DEFAULT ARRAY[]::uuid[],
    p_remove_contact_ids uuid[] DEFAULT ARRAY[]::uuid[]
)
    RETURNS jsonb
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $function$
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

    -- For each newly-added contact linked to a user, create thread_unread
    -- so the thread appears as unread for them.
    FOR r IN
        SELECT DISTINCT uc.user_id AS peer_user_id
        FROM unnest(p_add_contact_ids) AS arr(contact_id)
        JOIN user_contact uc
          ON uc.contact_id = arr.contact_id
         AND uc.linked = TRUE
         AND uc.archived_at IS NULL
        WHERE uc.user_id IS DISTINCT FROM p_user_id
    LOOP
        INSERT INTO thread_unread (user_id, thread_id, urgency, importance)
        VALUES (r.peer_user_id, p_thread_id, 'inform-updates', 50)
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