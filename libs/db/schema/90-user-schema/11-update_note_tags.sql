CREATE OR REPLACE FUNCTION "user".update_note_tags (user_id uuid, p_note_id uuid, p_actor_id uuid, p_client_id integer, p_tag_updates jsonb)
    RETURNS void
    LANGUAGE plpgsql
    AS $function$
DECLARE
    tag_record record;
    tag_id_int integer;
    is_adding boolean;
    current_tag_type tag_type;
    target_actor_id uuid;
    v_priority_id uuid;
    v_effective_role text;
BEGIN
    -- Validate that note_id is provided
    IF p_note_id IS NULL THEN
        RAISE EXCEPTION 'p_note_id must be provided';
    END IF;
    -- Validate access to the note's thread via thread_priority
    SELECT
        tp.priority_id INTO v_priority_id
    FROM
        note n
        JOIN thread_priority tp ON tp.thread_id = n.thread_id
            AND tp.user_id = update_note_tags.user_id
    WHERE
        n.id = p_note_id;
    IF v_priority_id IS NULL THEN
        IF NOT EXISTS (SELECT 1 FROM note WHERE id = p_note_id) THEN
            RAISE EXCEPTION 'Note not found';
        END IF;
        RAISE EXCEPTION 'User does not have access to this note';
    END IF;
    IF NOT user_has_priority_access(update_note_tags.user_id, v_priority_id) THEN
        RAISE EXCEPTION 'User does not have access to this priority';
    END IF;
    -- All users are members in the per-user model
    v_effective_role := 'member';
    -- Iterate through the tag updates JSON object
    FOR tag_record IN
    SELECT
        key,
        value
    FROM
        jsonb_each(p_tag_updates)
        LOOP
            -- Parse key: "tagId" or "tagId:actorId"
            IF position(':' in tag_record.key) > 0 THEN
                tag_id_int := split_part(tag_record.key, ':', 1)::integer;
                target_actor_id := split_part(tag_record.key, ':', 2)::uuid;
            ELSE
                tag_id_int := tag_record.key::integer;
                target_actor_id := p_actor_id;
            END IF;
            is_adding := tag_record.value::boolean;
            -- Get tag type using the get_tag_type function
            current_tag_type := get_tag_type (tag_id_int);
            -- Viewer enforcement: viewers can only modify count tags
            IF v_effective_role = 'viewer' AND current_tag_type != 'count' THEN
                RAISE EXCEPTION 'Viewer members can only modify count tags (tag_id: %)', tag_id_int;
            END IF;
            -- Validate computed tags for notes
            -- Notes can have 'todo' (1) and 'done' (3) tags for per-user assignment/completion
            -- But not 'archived' (4), 'attachment' (5), 'link' (6) - those are computed
            IF current_tag_type = 'compute' AND tag_id_int NOT IN (1, 3) THEN
                RAISE EXCEPTION 'Cannot add computed tag (tag_id: %) - this tag is calculated from note state', tag_id_int;
            END IF;
            -- Validate cross-user targeting: only allow for compute tags 1, 3 (todo, done)
            IF target_actor_id != p_actor_id AND (current_tag_type != 'compute' OR tag_id_int NOT IN (1, 3)) THEN
                RAISE EXCEPTION 'Cannot modify this tag for other users (tag_id: %)', tag_id_int;
            END IF;
            IF is_adding THEN
                -- When adding 'done' tag (3), automatically remove 'todo' tag (1) for this actor
                -- This is how individual completion works for multi-assignee notes
                IF tag_id_int = 3 THEN
                    UPDATE
                        note_tag
                    SET
                        archived_at = now(),
                        updated_by = p_client_id
                    WHERE
                        note_id = p_note_id
                        AND tag_id = 1
                        AND actor_id = target_actor_id
                        AND archived_at IS NULL;
                END IF;
                -- Adding a tag - use upsert to create or reactivate
                INSERT INTO note_tag (actor_id, note_id, tag_id, updated_at, archived_at, updated_by)
                    VALUES (target_actor_id, p_note_id, tag_id_int, now(), NULL, p_client_id)
                ON CONFLICT (actor_id, note_id, tag_id)
                    DO UPDATE SET
                        archived_at = NULL,
                        updated_at = now(),
                        updated_by = p_client_id;
                -- Reply tag propagation: note → thread
                IF tag_id_int = 1019 THEN
                    INSERT INTO thread_tag (actor_id, thread_id, occurrence, tag_id, updated_at, archived_at, updated_by)
                    SELECT target_actor_id, n.thread_id, NULL, 1019, now(), NULL, p_client_id
                    FROM note n WHERE n.id = p_note_id
                    ON CONFLICT (actor_id, thread_id, occurrence, tag_id)
                    DO UPDATE SET archived_at = NULL, updated_at = now(), updated_by = p_client_id;
                END IF;
            ELSE
                -- Removing a tag - use update to soft delete existing records
                IF current_tag_type = 'toggle' THEN
                    -- For toggle tags, remove all users' tags
                    UPDATE
                        note_tag
                    SET
                        archived_at = now(),
                        updated_by = p_client_id
                    WHERE
                        note_id = p_note_id
                        AND tag_id = tag_id_int
                        AND archived_at IS NULL;
                ELSE
                    -- For count/compute tags, only remove target actor's tag
                    UPDATE
                        note_tag
                    SET
                        archived_at = now(),
                        updated_by = p_client_id
                    WHERE
                        note_id = p_note_id
                        AND tag_id = tag_id_int
                        AND actor_id = target_actor_id
                        AND archived_at IS NULL;
                END IF;
                -- Reply tag propagation: remove from thread if no other notes have it
                IF tag_id_int = 1019 THEN
                    IF NOT EXISTS (
                        SELECT 1 FROM note_tag nt
                        JOIN note n2 ON n2.id = nt.note_id
                        WHERE n2.thread_id = (SELECT thread_id FROM note WHERE id = p_note_id)
                        AND nt.tag_id = 1019 AND nt.actor_id = target_actor_id
                        AND nt.archived_at IS NULL AND nt.note_id != p_note_id
                    ) THEN
                        UPDATE thread_tag SET archived_at = now(), updated_by = p_client_id
                        WHERE thread_id = (SELECT thread_id FROM note WHERE id = p_note_id)
                        AND tag_id = 1019 AND actor_id = target_actor_id AND archived_at IS NULL;
                    END IF;
                END IF;
            END IF;
        END LOOP;
END;
$function$;
