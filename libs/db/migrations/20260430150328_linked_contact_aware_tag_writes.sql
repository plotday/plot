-- Create "canonical_contact_id" function
CREATE FUNCTION "user"."canonical_contact_id" ("p_contact_id" uuid) RETURNS uuid LANGUAGE sql STABLE AS $$
SELECT COALESCE(
        (SELECT uc_p.contact_id
           FROM user_contact uc_self
           JOIN user_contact uc_p ON uc_p.user_id = uc_self.user_id
            AND uc_p."primary" = TRUE
            AND uc_p.linked = TRUE
            AND uc_p.archived_at IS NULL
          WHERE uc_self.contact_id = p_contact_id
            AND uc_self.linked = TRUE
            AND uc_self.archived_at IS NULL
          LIMIT 1),
        p_contact_id
    );
$$;
-- Create "sibling_contact_ids" function
CREATE FUNCTION "user"."sibling_contact_ids" ("p_contact_id" uuid) RETURNS uuid[] LANGUAGE sql STABLE AS $$
SELECT COALESCE(
        (SELECT array_agg(uc_sib.contact_id)
           FROM user_contact uc_self
           JOIN user_contact uc_sib ON uc_sib.user_id = uc_self.user_id
            AND uc_sib.linked = TRUE
            AND uc_sib.archived_at IS NULL
          WHERE uc_self.contact_id = p_contact_id
            AND uc_self.linked = TRUE
            AND uc_self.archived_at IS NULL),
        ARRAY[p_contact_id]
    );
$$;
-- Modify "update_note_tags" function
CREATE OR REPLACE FUNCTION "user"."update_note_tags" ("user_id" uuid, "p_note_id" uuid, "p_actor_id" uuid, "p_client_id" integer, "p_tag_updates" jsonb) RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    tag_record record;
    tag_id_int integer;
    is_adding boolean;
    current_tag_type tag_type;
    target_actor_id uuid;
    canonical_target_id uuid;
    target_sibling_ids uuid[];
    caller_sibling_ids uuid[];
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
    -- The caller's principal expanded to its linked-contact siblings. For
    -- a regular user this is every contact linked to them; for a twist
    -- caller (p_actor_id is a twist_instance_id) this is just [p_actor_id].
    caller_sibling_ids := "user".sibling_contact_ids(p_actor_id);
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
            -- Resolve the target actor to the canonical (primary) contact_id
            -- and the full set of linked-contact siblings. Linked contacts
            -- are equivalent identities, so writes/clears apply to the set.
            canonical_target_id := "user".canonical_contact_id(target_actor_id);
            target_sibling_ids := "user".sibling_contact_ids(target_actor_id);
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
            -- Validate cross-user targeting: only allow for compute tags 1, 3 (todo, done).
            -- Treat any of the caller's linked contacts as "self" — a target is
            -- another user iff none of its linked-contact siblings overlap the caller's.
            IF NOT (target_sibling_ids && caller_sibling_ids)
               AND (current_tag_type != 'compute' OR tag_id_int NOT IN (1, 3)) THEN
                RAISE EXCEPTION 'Cannot modify this tag for other users (tag_id: %)', tag_id_int;
            END IF;
            IF is_adding THEN
                -- When adding 'done' tag (3), automatically remove 'todo' tag (1)
                -- for every linked-contact sibling of the target actor. This is
                -- how individual completion works for multi-assignee notes.
                IF tag_id_int = 3 THEN
                    UPDATE
                        note_tag
                    SET
                        archived_at = now(),
                        updated_by = p_client_id
                    WHERE
                        note_id = p_note_id
                        AND tag_id = 1
                        AND actor_id = ANY(target_sibling_ids)
                        AND archived_at IS NULL;
                END IF;
                -- Adding a tag - only insert if no row exists yet for any of
                -- the target actor's linked-contact siblings. Always write
                -- against the canonical (primary) id so the live row tracks
                -- the user's current primary contact.
                IF NOT EXISTS (
                    SELECT 1 FROM note_tag
                    WHERE note_id = p_note_id
                      AND tag_id = tag_id_int
                      AND actor_id = ANY(target_sibling_ids)
                      AND archived_at IS NULL
                ) THEN
                    INSERT INTO note_tag (actor_id, note_id, tag_id, updated_at, archived_at, updated_by)
                        VALUES (canonical_target_id, p_note_id, tag_id_int, now(), NULL, p_client_id)
                    ON CONFLICT (actor_id, note_id, tag_id)
                        DO UPDATE SET
                            archived_at = NULL,
                            updated_at = now(),
                            updated_by = p_client_id;
                END IF;
                -- Reply tag propagation: note → thread
                IF tag_id_int = 1019 THEN
                    INSERT INTO thread_tag (actor_id, thread_id, occurrence, tag_id, updated_at, archived_at, updated_by)
                    SELECT canonical_target_id, n.thread_id, NULL, 1019, now(), NULL, p_client_id
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
                    -- For count/compute tags, archive every row for the target
                    -- actor's linked-contact siblings — clearing one alias must
                    -- clear all of them.
                    UPDATE
                        note_tag
                    SET
                        archived_at = now(),
                        updated_by = p_client_id
                    WHERE
                        note_id = p_note_id
                        AND tag_id = tag_id_int
                        AND actor_id = ANY(target_sibling_ids)
                        AND archived_at IS NULL;
                END IF;
                -- Reply tag propagation: remove from thread if no other notes have it
                IF tag_id_int = 1019 THEN
                    IF NOT EXISTS (
                        SELECT 1 FROM note_tag nt
                        JOIN note n2 ON n2.id = nt.note_id
                        WHERE n2.thread_id = (SELECT thread_id FROM note WHERE id = p_note_id)
                        AND nt.tag_id = 1019 AND nt.actor_id = ANY(target_sibling_ids)
                        AND nt.archived_at IS NULL AND nt.note_id != p_note_id
                    ) THEN
                        UPDATE thread_tag SET archived_at = now(), updated_by = p_client_id
                        WHERE thread_id = (SELECT thread_id FROM note WHERE id = p_note_id)
                        AND tag_id = 1019 AND actor_id = ANY(target_sibling_ids) AND archived_at IS NULL;
                    END IF;
                END IF;
            END IF;
        END LOOP;
END;
$$;
-- Modify "update_thread_tags" function
CREATE OR REPLACE FUNCTION "user"."update_thread_tags" ("user_id" uuid, "p_thread_id" uuid, "p_actor_id" uuid, "p_client_id" integer, "p_tag_updates" jsonb, "p_occurrence" text DEFAULT NULL::text) RETURNS void LANGUAGE plpgsql AS $$
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
$$;
-- Modify "upsert_note_tag" function
CREATE OR REPLACE FUNCTION "user"."upsert_note_tag" ("user_id" uuid, "p_actor_id" uuid, "p_note_id" uuid, "p_tag_id" integer, "p_updated_by" integer DEFAULT 0, "p_archived_at" timestamptz DEFAULT NULL::timestamp with time zone) RETURNS "public"."note_tag" LANGUAGE plpgsql SET "search_path" = public, "user" AS $$
DECLARE
    v_priority_id uuid;
    v_tag_type tag_type;
    v_canonical_actor_id uuid;
    v_actor_sibling_ids uuid[];
    v_caller_sibling_ids uuid[];
    v_row note_tag;
BEGIN
    SELECT
        tp.priority_id INTO v_priority_id
    FROM
        note n
        JOIN thread_priority tp ON tp.thread_id = n.thread_id
            AND tp.user_id = upsert_note_tag.user_id
    WHERE
        n.id = p_note_id;
    IF v_priority_id IS NULL THEN
        IF NOT EXISTS (SELECT 1 FROM note WHERE id = p_note_id) THEN
            RAISE EXCEPTION 'Note not found';
        END IF;
        RAISE EXCEPTION 'User does not have access to this note';
    END IF;
    PERFORM "user".assert_priority_access(user_id, v_priority_id);

    v_tag_type := get_tag_type(p_tag_id);
    IF v_tag_type = 'compute' THEN
        RAISE EXCEPTION 'Cannot add computed tag (tag_id: %)', p_tag_id;
    END IF;
    -- Resolve actor to canonical primary id and full linked-contact sibling
    -- set. Linked contacts are equivalent identities.
    v_canonical_actor_id := "user".canonical_contact_id(p_actor_id);
    v_actor_sibling_ids := "user".sibling_contact_ids(p_actor_id);
    v_caller_sibling_ids := "user".user_contact_ids(user_id);
    IF v_tag_type = 'count' AND NOT (v_actor_sibling_ids && v_caller_sibling_ids) THEN
        RAISE EXCEPTION 'Cannot modify count tags for other users (tag_id: %)', p_tag_id;
    END IF;

    -- Archive any sibling-aliased rows so a single canonical row remains.
    IF p_archived_at IS NULL AND array_length(v_actor_sibling_ids, 1) > 1 THEN
        UPDATE note_tag
        SET archived_at = now(),
            updated_by = COALESCE(p_updated_by, 0)
        WHERE note_id = p_note_id
          AND tag_id = p_tag_id
          AND actor_id = ANY(v_actor_sibling_ids)
          AND actor_id != v_canonical_actor_id
          AND archived_at IS NULL;
    END IF;

    INSERT INTO note_tag (actor_id, note_id, tag_id, updated_by, archived_at)
        VALUES (v_canonical_actor_id, p_note_id, p_tag_id, COALESCE(p_updated_by, 0), p_archived_at)
    ON CONFLICT (actor_id, note_id, tag_id)
        DO UPDATE SET
            archived_at = EXCLUDED.archived_at,
            updated_by = EXCLUDED.updated_by,
            updated_at = now()
    RETURNING * INTO v_row;

    RETURN v_row;
END;
$$;
-- Modify "upsert_thread_tag" function
CREATE OR REPLACE FUNCTION "user"."upsert_thread_tag" ("user_id" uuid, "p_actor_id" uuid, "p_thread_id" uuid, "p_tag_id" integer, "p_occurrence" text DEFAULT NULL::text, "p_updated_by" integer DEFAULT 0, "p_archived_at" timestamptz DEFAULT NULL::timestamp with time zone) RETURNS "public"."thread_tag" LANGUAGE plpgsql SET "search_path" = public, "user" AS $$
DECLARE
    v_priority_id uuid;
    v_tag_type tag_type;
    v_canonical_actor_id uuid;
    v_actor_sibling_ids uuid[];
    v_caller_sibling_ids uuid[];
    v_row thread_tag;
BEGIN
    SELECT
        tp.priority_id INTO v_priority_id
    FROM
        thread_priority tp
    WHERE
        tp.thread_id = p_thread_id
        AND tp.user_id = upsert_thread_tag.user_id;
    IF v_priority_id IS NULL THEN
        RAISE EXCEPTION 'Thread not found';
    END IF;
    PERFORM "user".assert_priority_access(upsert_thread_tag.user_id, v_priority_id);

    v_tag_type := get_tag_type(p_tag_id);
    IF v_tag_type = 'compute' THEN
        RAISE EXCEPTION 'Cannot add computed tag (tag_id: %)', p_tag_id;
    END IF;
    -- Viewer enforcement: viewers can only modify count tags
    IF v_tag_type != 'count' AND "user".get_effective_role(user_id, v_priority_id) = 'viewer' THEN
        RAISE EXCEPTION 'Viewer members can only modify count tags';
    END IF;
    -- Resolve actor to canonical primary id and full linked-contact sibling
    -- set. Linked contacts are equivalent identities for ownership and
    -- storage of tag rows.
    v_canonical_actor_id := "user".canonical_contact_id(p_actor_id);
    v_actor_sibling_ids := "user".sibling_contact_ids(p_actor_id);
    v_caller_sibling_ids := "user".user_contact_ids(user_id);
    IF v_tag_type = 'count' AND NOT (v_actor_sibling_ids && v_caller_sibling_ids) THEN
        RAISE EXCEPTION 'Cannot modify count tags for other users (tag_id: %)', p_tag_id;
    END IF;

    -- Archive any sibling-aliased rows so a single canonical row remains.
    -- This collapses prior writes against a non-primary linked contact id
    -- (e.g. before primary flipped) into the current primary.
    IF p_archived_at IS NULL AND array_length(v_actor_sibling_ids, 1) > 1 THEN
        UPDATE thread_tag
        SET archived_at = now(),
            updated_by = COALESCE(p_updated_by, 0)
        WHERE thread_id = p_thread_id
          AND tag_id = p_tag_id
          AND (occurrence IS NOT DISTINCT FROM p_occurrence)
          AND actor_id = ANY(v_actor_sibling_ids)
          AND actor_id != v_canonical_actor_id
          AND archived_at IS NULL;
    END IF;

    INSERT INTO thread_tag (actor_id, thread_id, occurrence, tag_id, updated_by, archived_at)
        VALUES (v_canonical_actor_id, p_thread_id, p_occurrence, p_tag_id, COALESCE(p_updated_by, 0), p_archived_at)
    ON CONFLICT (actor_id, thread_id, occurrence, tag_id)
        DO UPDATE SET
            archived_at = EXCLUDED.archived_at,
            updated_by = EXCLUDED.updated_by,
            updated_at = now()
    RETURNING * INTO v_row;

    RETURN v_row;
END;
$$;
