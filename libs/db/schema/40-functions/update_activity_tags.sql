CREATE OR REPLACE FUNCTION public.update_activity_tags (p_activity_id uuid, p_actor_id uuid, p_client_id integer, p_tag_updates jsonb, p_occurrence text DEFAULT NULL)
    RETURNS void
    LANGUAGE plpgsql
    SECURITY DEFINER
    AS $function$
DECLARE
    tag_record record;
    tag_id_int integer;
    is_adding boolean;
    current_tag_type tag_type;
BEGIN
    -- Validate that activity_id is provided
    IF p_activity_id IS NULL THEN
        RAISE EXCEPTION 'p_activity_id must be provided';
    END IF;
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
            -- Prevent insertion of computed tags (tag_id 1-99)
            -- Computed tags should only exist as calculated values
            IF current_tag_type = 'compute' THEN
                RAISE EXCEPTION 'Cannot add computed tag (tag_id: %) - these tags are calculated from activity state', tag_id_int;
            END IF;
            IF is_adding THEN
                -- Adding a tag - use upsert to create or reactivate
                INSERT INTO activity_tag (actor_id, activity_id, occurrence, tag_id, updated_at, archived_at, updated_by)
                    VALUES (p_actor_id, p_activity_id, p_occurrence, tag_id_int, now(), NULL, p_client_id)
                ON CONFLICT (actor_id, activity_id, occurrence, tag_id)
                    DO UPDATE SET
                        archived_at = NULL,
                        updated_at = now(),
                        updated_by = p_client_id;
                -- Ensure priority_contact exists if actor is a contact
                -- This allows contacts to be visible via RLS when tagged on activities
                IF EXISTS (
                    SELECT
                        1
                    FROM
                        contact
                    WHERE
                        id = p_actor_id) THEN
                INSERT INTO priority_contact (priority_id, contact_id, archived_at)
                SELECT
                    a.priority_id,
                    p_actor_id,
                    NULL
                FROM
                    activity a
                WHERE
                    a.id = p_activity_id
                ON CONFLICT (priority_id,
                    contact_id)
                    DO UPDATE SET
                        archived_at = NULL;
            END IF;
        ELSE
            -- Removing a tag - use update to soft delete existing records
            IF current_tag_type = 'toggle' THEN
                -- For toggle tags, remove all users' tags
                UPDATE
                    activity_tag
                SET
                    archived_at = now(),
                    updated_by = p_client_id
                WHERE
                    activity_id = p_activity_id
                    AND tag_id = tag_id_int
                    AND (occurrence IS NOT DISTINCT FROM p_occurrence)
                    AND archived_at IS NULL;
            ELSE
                -- For count/compute tags, only remove current actor's tag
                UPDATE
                    activity_tag
                SET
                    archived_at = now(),
                    updated_by = p_client_id
                WHERE
                    activity_id = p_activity_id
                    AND tag_id = tag_id_int
                    AND actor_id = p_actor_id
                    AND (occurrence IS NOT DISTINCT FROM p_occurrence)
                    AND archived_at IS NULL;
            END IF;
        END IF;
END LOOP;
END;
$function$;

