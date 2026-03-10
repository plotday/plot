CREATE OR REPLACE FUNCTION "user".update_thread_tags (user_id uuid, p_thread_id uuid, p_actor_id uuid, p_client_id integer, p_tag_updates jsonb, p_occurrence text DEFAULT NULL::text)
    RETURNS void
    LANGUAGE plpgsql
    AS $function$
DECLARE
    tag_record record;
    tag_id_int integer;
    is_adding boolean;
    current_tag_type tag_type;
    v_priority_id uuid;
    v_effective_role text;
BEGIN
    -- Validate that thread_id is provided
    IF p_thread_id IS NULL THEN
        RAISE EXCEPTION 'p_thread_id must be provided';
    END IF;
    -- Validate access to the thread's priority
    SELECT
        a.priority_id INTO v_priority_id
    FROM
        thread a
    WHERE
        a.id = p_thread_id;
    IF v_priority_id IS NULL THEN
        RAISE EXCEPTION 'Thread not found';
    END IF;
    IF NOT "user".has_priority_access (user_id, v_priority_id) THEN
        RAISE EXCEPTION 'User does not have access to this thread';
    END IF;
    v_effective_role := "user".get_effective_role(user_id, v_priority_id);
    -- Iterate through the tag updates JSON object
    FOR tag_record IN
    SELECT
        key,
        value
    FROM
        jsonb_each(p_tag_updates)
        LOOP
            -- Convert key to integer and value to boolean
            tag_id_int := tag_record.key::integer;
            is_adding := tag_record.value::boolean;
            -- Get tag type using the get_tag_type function
            current_tag_type := get_tag_type (tag_id_int);
            -- Viewer enforcement: viewers can only modify count tags
            IF v_effective_role = 'viewer' AND current_tag_type != 'count' THEN
                RAISE EXCEPTION 'Viewer members can only modify count tags (tag_id: %)', tag_id_int;
            END IF;
            -- Prevent insertion of computed tags (tag_id 1-99)
            -- Computed tags should only exist as calculated values
            IF current_tag_type = 'compute' THEN
                RAISE EXCEPTION 'Cannot add computed tag (tag_id: %) - these tags are calculated from thread state', tag_id_int;
            END IF;
            -- For count tags, enforce that users can only modify their own tags
            -- p_actor_id should match the authenticated user's contact_id
            -- Note: RLS policies already enforce this, but we validate explicitly for clarity
            IF current_tag_type = 'count' THEN
                -- Validate p_actor_id matches current user's contact_id
                IF p_actor_id != "user".user_contact_id (user_id) THEN
                    RAISE EXCEPTION 'Cannot modify count tags for other users (tag_id: %)', tag_id_int;
                END IF;
            END IF;
            IF is_adding THEN
                -- Adding a tag - use upsert to create or reactivate
                INSERT INTO thread_tag (actor_id, thread_id, occurrence, tag_id, updated_at, archived_at, updated_by)
                    VALUES (p_actor_id, p_thread_id, p_occurrence, tag_id_int, now(), NULL, p_client_id)
                ON CONFLICT (actor_id, thread_id, occurrence, tag_id)
                    DO UPDATE SET
                        archived_at = NULL,
                        updated_at = now(),
                        updated_by = p_client_id;
                -- Ensure priority_contact exists if actor is a contact
                -- This allows contacts to be visible via RLS when tagged on threads
                IF EXISTS (
                    SELECT
                        1
                    FROM
                        contact
                    WHERE
                        id = p_actor_id) THEN
                INSERT INTO priority_contact (priority_id, contact_id)
                SELECT
                    a.priority_id,
                    p_actor_id
                FROM
                    thread a
                WHERE
                    a.id = p_thread_id
                ON CONFLICT (priority_id,
                    contact_id)
                    DO NOTHING;
            END IF;
        ELSE
            -- Removing a tag - use update to soft delete existing records
            IF current_tag_type = 'toggle' THEN
                -- For toggle tags, remove all users' tags
                UPDATE
                    thread_tag
                SET
                    archived_at = now(),
                    updated_by = p_client_id
                WHERE
                    thread_id = p_thread_id
                    AND tag_id = tag_id_int
                    AND (occurrence IS NOT DISTINCT FROM p_occurrence)
                    AND archived_at IS NULL;
            ELSE
                -- For count/compute tags, only remove current actor's tag
                UPDATE
                    thread_tag
                SET
                    archived_at = now(),
                    updated_by = p_client_id
                WHERE
                    thread_id = p_thread_id
                    AND tag_id = tag_id_int
                    AND actor_id = p_actor_id
                    AND (occurrence IS NOT DISTINCT FROM p_occurrence)
                    AND archived_at IS NULL;
            END IF;
        END IF;
END LOOP;
END;
$function$;
