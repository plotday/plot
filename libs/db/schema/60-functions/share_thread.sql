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

-- Add or remove topics from a thread's topic list.
CREATE OR REPLACE FUNCTION public.share_thread_with_topics (
    p_user_id uuid,
    p_thread_id uuid,
    p_add_topic_ids uuid[] DEFAULT ARRAY[]::uuid[],
    p_remove_topic_ids uuid[] DEFAULT ARRAY[]::uuid[]
)
    RETURNS jsonb
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $function$
DECLARE
    v_current_topics uuid[];
    v_new_topics uuid[];
    v_topic RECORD;
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM thread_priority tp
        WHERE tp.thread_id = p_thread_id
          AND tp.user_id = p_user_id
    ) THEN
        RAISE EXCEPTION 'User does not have access to this thread';
    END IF;

    FOR v_topic IN
        SELECT t.id, t.type
        FROM unnest(p_add_topic_ids) AS arr(id)
        JOIN topic t ON t.id = arr.id
        WHERE t.archived_at IS NULL
    LOOP
        IF v_topic.type = 'announce' THEN
            IF NOT EXISTS (
                SELECT 1 FROM topic_admin
                WHERE topic_id = v_topic.id AND user_id = p_user_id
            ) THEN
                RAISE EXCEPTION 'Only admins can add announce topics to threads';
            END IF;
        ELSIF v_topic.type IN ('private', 'team') THEN
            IF NOT EXISTS (
                SELECT 1 FROM topic_admin
                WHERE topic_id = v_topic.id AND user_id = p_user_id
            ) AND NOT EXISTS (
                SELECT 1 FROM topic_member tm
                JOIN user_contact uc ON uc.contact_id = tm.contact_id
                    AND uc.linked = TRUE AND uc.archived_at IS NULL
                WHERE tm.topic_id = v_topic.id AND uc.user_id = p_user_id
            ) THEN
                RAISE EXCEPTION 'User does not have permission to add this topic';
            END IF;
        END IF;
    END LOOP;

    SELECT topics INTO v_current_topics
    FROM thread
    WHERE id = p_thread_id;

    IF v_current_topics IS NULL THEN
        v_current_topics := ARRAY[]::uuid[];
    END IF;

    SELECT COALESCE(array_agg(DISTINCT tid), ARRAY[]::uuid[])
    INTO v_new_topics
    FROM (
        SELECT unnest(v_current_topics) AS tid
        UNION
        SELECT unnest(p_add_topic_ids)
    ) all_topics
    WHERE tid != ALL(COALESCE(p_remove_topic_ids, ARRAY[]::uuid[]));

    UPDATE thread
    SET topics = v_new_topics
    WHERE id = p_thread_id;

    RETURN jsonb_build_object('topics', to_jsonb(v_new_topics));
END;
$function$;