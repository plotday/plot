-- Drop "ensure_link_assignee_priority_contact_trigger" trigger
DROP TRIGGER "ensure_link_assignee_priority_contact_trigger" ON "public"."link";
-- Drop "ensure_priority_user_contact_trigger" trigger
DROP TRIGGER "ensure_priority_user_contact_trigger" ON "public"."priority_user";
-- Modify "redeem_invitation_token" function
CREATE OR REPLACE FUNCTION "public"."redeem_invitation_token" ("p_user_id" uuid, "p_token" text) RETURNS jsonb LANGUAGE plpgsql SET "search_path" = public AS $$
DECLARE
    v_contact_id uuid;
    v_contact_user_id uuid;
    v_redeemed_by uuid;
BEGIN
    -- Find contact_invitation with this token
    SELECT
        ci.contact_id,
        ci.redeemed_by,
        c.user_id INTO v_contact_id,
        v_redeemed_by,
        v_contact_user_id
    FROM
        public.contact_invitation ci
        JOIN public.contact c ON c.id = ci.contact_id
    WHERE
        ci.token = p_token;
    IF v_contact_id IS NULL THEN
        RETURN jsonb_build_object('success', FALSE, 'error', 'invalid_token');
    END IF;
    -- Check if already redeemed
    IF v_redeemed_by IS NOT NULL THEN
        IF v_redeemed_by = p_user_id THEN
            -- Same user re-clicking - return success (idempotent)
            RETURN jsonb_build_object('success', TRUE, 'already_redeemed', TRUE, 'contact_id', v_contact_id);
        ELSE
            -- Different user attempting to use redeemed token
            RETURN jsonb_build_object('success', FALSE, 'error', 'already_redeemed_by_different_user');
        END IF;
    END IF;
    -- Check if contact already linked to a DIFFERENT user
    IF v_contact_user_id IS NOT NULL AND v_contact_user_id != p_user_id THEN
        RETURN jsonb_build_object('success', FALSE, 'error', 'contact_linked_to_other_user');
    END IF;
    -- Link contact to user (if not already linked)
    UPDATE
        public.contact
    SET
        user_id = p_user_id
    WHERE
        id = v_contact_id
        AND (user_id IS NULL
            OR user_id = p_user_id);
    -- Mark invitation as redeemed instead of deleting
    UPDATE
        public.contact_invitation
    SET
        redeemed_at = now(),
        redeemed_by = p_user_id
    WHERE
        contact_id = v_contact_id;
    RETURN jsonb_build_object('success', TRUE, 'already_redeemed', FALSE, 'contact_id', v_contact_id);
END;
$$;
-- Modify "sync_user_for_contact" function
CREATE OR REPLACE FUNCTION "public"."sync_user_for_contact" () RETURNS trigger LANGUAGE plpgsql SET "search_path" = public AS $$
DECLARE
    v_max_updated_at timestamptz;
    v_user_id uuid;
BEGIN
    SELECT
        MAX(updated_at) INTO v_max_updated_at
    FROM
        new_table;
    -- Contact changes affect all users who have visibility of this contact via user_contact
    FOR v_user_id IN SELECT DISTINCT
        uc.user_id
    FROM
        new_table n
        JOIN user_contact uc ON uc.contact_id = n.id
    WHERE
        uc.archived_at IS NULL
    ORDER BY
        uc.user_id LOOP
            INSERT INTO user_sync (user_id, entity, last_update_at)
                VALUES (v_user_id, 'actor', v_max_updated_at)
            ON CONFLICT (user_id, entity)
                DO UPDATE SET
                    last_update_at = GREATEST (user_sync.last_update_at, EXCLUDED.last_update_at);
        END LOOP;
    RETURN NULL;
END;
$$;
-- Modify "sync_user_for_priority_user" function
CREATE OR REPLACE FUNCTION "public"."sync_user_for_priority_user" () RETURNS trigger LANGUAGE plpgsql SET "search_path" = public AS $$
DECLARE
    v_max_updated_at timestamptz;
    v_user_id uuid;
BEGIN
    SELECT
        MAX(updated_at) INTO v_max_updated_at
    FROM
        new_table;
    -- Sync priority entity so user's accessible priorities update
    FOR v_user_id IN SELECT DISTINCT
        upe.user_id
    FROM
        new_table n
        JOIN "user".priority_expanded upe ON upe.priority_id = n.priority_id
    WHERE
        upe.archived_at IS NULL
    ORDER BY
        upe.user_id LOOP
            INSERT INTO user_sync (user_id, entity, last_update_at)
                VALUES (v_user_id, 'priority', v_max_updated_at)
            ON CONFLICT (user_id, entity)
                DO UPDATE SET
                    last_update_at = GREATEST (user_sync.last_update_at, EXCLUDED.last_update_at);
        END LOOP;
    RETURN NULL;
END;
$$;
-- Modify "update_thread_tags" function
CREATE OR REPLACE FUNCTION "user"."update_thread_tags" ("user_id" uuid, "p_thread_id" uuid, "p_actor_id" uuid, "p_client_id" integer, "p_tag_updates" jsonb, "p_occurrence" text DEFAULT NULL::text) RETURNS void LANGUAGE plpgsql AS $$
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
            -- For count tags, enforce that users can only modify their own tags
            -- p_actor_id should match the authenticated user's contact_id
            -- Note: RLS policies already enforce this, but we validate explicitly for clarity
            IF current_tag_type = 'count' THEN
                -- Validate p_actor_id matches one of the user's linked contacts
                IF NOT (p_actor_id = ANY("user".user_contact_ids (user_id))) THEN
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
            -- Reply tag propagation: thread → notes
            IF tag_id_int = 1019 THEN
                UPDATE note_tag SET archived_at = now(), updated_by = p_client_id
                WHERE note_id IN (SELECT id FROM note WHERE thread_id = p_thread_id)
                AND tag_id = 1019 AND actor_id = p_actor_id AND archived_at IS NULL;
            END IF;
        END IF;
END LOOP;
END;
$$;
-- Modify "upsert_schedule_contacts" function
CREATE OR REPLACE FUNCTION "user"."upsert_schedule_contacts" ("user_id" uuid, "p_schedule_id" uuid, "p_contacts" jsonb) RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    v_contact jsonb;
    v_contact_id uuid;
    v_status text;
    v_role text;
    v_archived boolean;
    v_priority_id uuid;
BEGIN
    -- Validate user has access to the schedule's thread via thread_priority
    SELECT tp.priority_id INTO v_priority_id
    FROM schedule s
    LEFT JOIN thread_priority tp ON tp.thread_id = COALESCE(s.thread_id, (SELECT l.thread_id FROM link l WHERE l.id = s.link_id))
      AND tp.user_id = upsert_schedule_contacts.user_id
    WHERE s.id = p_schedule_id;

    IF v_priority_id IS NULL THEN
        IF NOT EXISTS (SELECT 1 FROM schedule WHERE id = p_schedule_id) THEN
            RAISE EXCEPTION 'Schedule not found';
        END IF;
        RAISE EXCEPTION 'User does not have access to this schedule';
    END IF;

    IF NOT user_has_priority_access(upsert_schedule_contacts.user_id, v_priority_id) THEN
        RAISE EXCEPTION 'User does not have access to this priority';
    END IF;

    FOR v_contact IN SELECT * FROM jsonb_array_elements(p_contacts)
    LOOP
        v_contact_id := (v_contact ->> 'contact_id')::uuid;
        v_status := v_contact ->> 'status';
        v_role := v_contact ->> 'role';
        v_archived := COALESCE((v_contact ->> 'archived')::boolean, false);

        INSERT INTO schedule_contact (schedule_id, contact_id, status, role, archived_at)
        VALUES (
            p_schedule_id,
            v_contact_id,
            v_status,
            COALESCE(v_role, 'required'),
            CASE WHEN v_archived THEN now() ELSE NULL END
        )
        ON CONFLICT (schedule_id, contact_id)
        DO UPDATE SET
            status = CASE
                WHEN v_contact ? 'status' THEN EXCLUDED.status
                ELSE schedule_contact.status
            END,
            role = CASE
                WHEN v_contact ? 'role' THEN EXCLUDED.role
                ELSE schedule_contact.role
            END,
            archived_at = CASE
                WHEN v_archived THEN COALESCE(schedule_contact.archived_at, now())
                ELSE NULL
            END;

    END LOOP;
END;
$$;
-- Drop "upsert_priority_member" function
DROP FUNCTION "user"."upsert_priority_member";
-- Drop "priority_member" view
DROP VIEW "public"."priority_member";
-- Modify "priority_actor" view
CREATE OR REPLACE VIEW "user"."priority_actor" (
  "user_id",
  "priority_path",
  "actor_id",
  "depth",
  "created_at",
  "updated_at",
  "archived_at"
) AS SELECT user_id,
    priority_path,
    actor_id,
    depth,
    created_at,
    updated_at,
    archived_at
   FROM ( SELECT DISTINCT ON (uc.user_id, p.path, uc.contact_id) uc.user_id,
            p.path AS priority_path,
            uc.contact_id AS actor_id,
            0 AS depth,
            LEAST(COALESCE(uc.created_at, c.created_at), COALESCE(c.created_at, uc.created_at)) AS created_at,
            GREATEST(uc.updated_at, c.updated_at) AS updated_at,
            c.archived_at
           FROM public.user_contact uc
             JOIN public.contact c ON c.id = uc.contact_id
             JOIN public.priority p ON p.user_id = uc.user_id AND p.archived_at IS NULL
          WHERE uc.archived_at IS NULL AND (c.user_id IS NULL OR c."primary" = true)
        UNION ALL
         SELECT p.user_id,
            p.path AS priority_path,
            pt.id AS actor_id,
            0 AS depth,
            pt.created_at,
            pt.updated_at,
            pt.archived_at
           FROM public.priority p
             JOIN public.twist_instance pt ON pt.owner_id = p.user_id
          WHERE p.archived_at IS NULL) actors;
-- Drop "priority_contact" table
DROP TABLE "public"."priority_contact";
-- Drop "ensure_link_assignee_priority_contact" function
DROP FUNCTION "public"."ensure_link_assignee_priority_contact";
-- Drop "ensure_priority_user_contact" function
DROP FUNCTION "public"."ensure_priority_user_contact";
-- Drop "share_priority" function
DROP FUNCTION "public"."share_priority";
-- Drop "sync_user_for_priority_contact" function
DROP FUNCTION "public"."sync_user_for_priority_contact";
