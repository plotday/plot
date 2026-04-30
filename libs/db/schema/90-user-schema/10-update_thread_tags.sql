CREATE OR REPLACE FUNCTION "user".update_thread_tags (user_id uuid, p_thread_id uuid, p_actor_id uuid, p_client_id integer, p_tag_updates jsonb, p_occurrence text DEFAULT NULL::text)
    RETURNS void
    LANGUAGE plpgsql
    AS $function$
DECLARE
    tag_record record;
    tag_id_int integer;
    is_adding boolean;
    current_tag_type tag_type;
    canonical_actor_id uuid;
    actor_sibling_ids uuid[];
    caller_sibling_ids uuid[];
    v_priority_id uuid;
    v_effective_role text;
BEGIN
    -- Validate that thread_id is provided
    IF p_thread_id IS NULL THEN
        RAISE EXCEPTION 'p_thread_id must be provided';
    END IF;
    -- Validate access to the thread via thread_priority
    SELECT
        tp.priority_id INTO v_priority_id
    FROM
        thread_priority tp
    WHERE
        tp.thread_id = p_thread_id
        AND tp.user_id = update_thread_tags.user_id;
    IF v_priority_id IS NULL THEN
        IF NOT EXISTS (SELECT 1 FROM thread WHERE id = p_thread_id) THEN
            RAISE EXCEPTION 'Thread not found';
        END IF;
        RAISE EXCEPTION 'User does not have access to this thread';
    END IF;
    IF NOT user_has_priority_access(update_thread_tags.user_id, v_priority_id) THEN
        RAISE EXCEPTION 'User does not have access to this priority';
    END IF;
    -- All users are members in the per-user model
    v_effective_role := 'member';
    -- Resolve the actor to the canonical primary id and the full set of
    -- linked-contact siblings. update_thread_tags doesn't accept per-tag
    -- target actors, so this is a single resolution for all updates.
    canonical_actor_id := "user".canonical_contact_id(p_actor_id);
    actor_sibling_ids := "user".sibling_contact_ids(p_actor_id);
    -- The caller user's linked-contact set. Used to authorize count-tag
    -- writes — the actor (after sibling expansion) must overlap.
    caller_sibling_ids := "user".user_contact_ids(update_thread_tags.user_id);
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
            -- Exception: 'done' (3) acts as a toggle tag on threads
            IF current_tag_type = 'compute' AND tag_id_int != 3 THEN
                RAISE EXCEPTION 'Cannot add computed tag (tag_id: %) - these tags are calculated from thread state', tag_id_int;
            END IF;
            -- For count tags, enforce that users can only modify their own tags.
            -- Linked contacts are equivalent identities, so any overlap with
            -- the caller's sibling set counts as self.
            IF current_tag_type = 'count' THEN
                IF NOT (actor_sibling_ids && caller_sibling_ids) THEN
                    RAISE EXCEPTION 'Cannot modify count tags for other users (tag_id: %)', tag_id_int;
                END IF;
            END IF;
            IF is_adding THEN
                -- Adding a tag - only insert if no row exists yet for any of
                -- the actor's linked-contact siblings. Always write against the
                -- canonical (primary) id.
                IF NOT EXISTS (
                    SELECT 1 FROM thread_tag
                    WHERE thread_id = p_thread_id
                      AND tag_id = tag_id_int
                      AND (occurrence IS NOT DISTINCT FROM p_occurrence)
                      AND actor_id = ANY(actor_sibling_ids)
                      AND archived_at IS NULL
                ) THEN
                    INSERT INTO thread_tag (actor_id, thread_id, occurrence, tag_id, updated_at, archived_at, updated_by)
                        VALUES (canonical_actor_id, p_thread_id, p_occurrence, tag_id_int, now(), NULL, p_client_id)
                    ON CONFLICT (actor_id, thread_id, occurrence, tag_id)
                        DO UPDATE SET
                            archived_at = NULL,
                            updated_at = now(),
                            updated_by = p_client_id;
                END IF;
        ELSE
            -- Removing a tag - use update to soft delete existing records
            IF current_tag_type = 'toggle' OR tag_id_int = 3 THEN
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
                -- For count/compute tags, archive every row for the actor's
                -- linked-contact siblings — clearing one alias clears all.
                UPDATE
                    thread_tag
                SET
                    archived_at = now(),
                    updated_by = p_client_id
                WHERE
                    thread_id = p_thread_id
                    AND tag_id = tag_id_int
                    AND actor_id = ANY(actor_sibling_ids)
                    AND (occurrence IS NOT DISTINCT FROM p_occurrence)
                    AND archived_at IS NULL;
            END IF;
            -- Reply tag propagation: thread → notes
            IF tag_id_int = 1019 THEN
                UPDATE note_tag SET archived_at = now(), updated_by = p_client_id
                WHERE note_id IN (SELECT id FROM note WHERE thread_id = p_thread_id)
                AND tag_id = 1019 AND actor_id = ANY(actor_sibling_ids) AND archived_at IS NULL;
            END IF;
        END IF;
END LOOP;
END;
$function$;
