-- Modify "search_notes_and_links" function
CREATE OR REPLACE FUNCTION "public"."search_notes_and_links" ("query_embedding" text, "scope_priority_id" uuid, "requesting_user_id" uuid, "exclude_created_by" uuid DEFAULT NULL::uuid, "similarity_threshold" double precision DEFAULT 0.3, "match_limit" integer DEFAULT 20) RETURNS TABLE ("result_type" text, "result_id" uuid, "thread_id" uuid, "thread_title" text, "priority_id" uuid, "priority_title" text, "content" text, "title" text, "source_url" text, "similarity" double precision) LANGUAGE plpgsql AS $$
BEGIN
    RETURN QUERY
    SELECT * FROM (
        -- Notes
        SELECT 'note'::text, n.id, n.thread_id, t.title, tp.priority_id,
               p.title, n.content, NULL::text, NULL::text,
               (1 - (n.embedding <=> query_embedding::halfvec))::float AS similarity
        FROM note n
        JOIN thread t ON t.id = n.thread_id
        JOIN thread_priority tp ON tp.thread_id = t.id AND tp.user_id = requesting_user_id
        JOIN priority p ON p.id = tp.priority_id
        JOIN priority_child pc ON pc.priority_id = scope_priority_id
                              AND pc.child_id = tp.priority_id
        WHERE n.embedding IS NOT NULL
          AND n.archived_at IS NULL AND n.draft = FALSE
          AND t.archived_at IS NULL
          AND t.contacts && "user".user_contact_ids(requesting_user_id)
          AND (
            n.created_by = requesting_user_id
            OR (n.access_contacts IS NULL AND n.access_groups IS NULL)
            OR (n.access_contacts IS NOT NULL AND n.access_contacts && "user".user_contact_ids(requesting_user_id))
            OR (n.access_groups IS NOT NULL AND n.access_groups && "user".user_group_ids(requesting_user_id))
          )
          AND (exclude_created_by IS NULL OR n.created_by != exclude_created_by)
          AND (1 - (n.embedding <=> query_embedding::halfvec)) >= similarity_threshold

        UNION ALL

        -- Threads (via thread.embedding)
        SELECT 'link'::text, l.id, l.thread_id, t.title, tp.priority_id,
               p.title, l.preview, l.title, l.source_url,
               (1 - (t.embedding <=> query_embedding::halfvec))::float AS similarity
        FROM link l
        JOIN thread t ON t.id = l.thread_id
        JOIN thread_priority tp ON tp.thread_id = t.id AND tp.user_id = requesting_user_id
        JOIN priority p ON p.id = tp.priority_id
        JOIN priority_child pc ON pc.priority_id = scope_priority_id
                              AND pc.child_id = tp.priority_id
        WHERE t.embedding IS NOT NULL AND l.thread_id IS NOT NULL
          AND t.archived_at IS NULL
          AND t.contacts && "user".user_contact_ids(requesting_user_id)
          AND (1 - (t.embedding <=> query_embedding::halfvec)) >= similarity_threshold
    ) combined
    ORDER BY combined.similarity DESC
    LIMIT match_limit;
END;
$$;
-- Modify "sync_twist_for_note" function
CREATE OR REPLACE FUNCTION "public"."sync_twist_for_note" () RETURNS trigger LANGUAGE plpgsql SET "search_path" = public AS $$
DECLARE
    v_create_timestamp timestamptz;
    v_update_timestamp timestamptz;
    v_create_seq xid8;
    v_update_seq xid8;
    v_twist_instance_id uuid;
BEGIN
    IF TG_OP = 'INSERT' THEN
        SELECT
            MAX(n.created_at), MAX(n.seq) INTO v_create_timestamp, v_create_seq
        FROM
            new_table n
            JOIN thread a ON a.id = n.thread_id
        WHERE
            n.draft = FALSE
            AND a.draft = FALSE;
    ELSE
        SELECT
            MAX(n.updated_at), MAX(n.seq) INTO v_create_timestamp, v_create_seq
        FROM
            new_table n
            JOIN old_table o ON o.id = n.id
            JOIN thread a ON a.id = n.thread_id
        WHERE
            o.draft = TRUE
            AND n.draft = FALSE
            AND a.draft = FALSE;
        SELECT
            MAX(n.updated_at), MAX(n.seq) INTO v_update_timestamp, v_update_seq
        FROM
            new_table n
            JOIN old_table o ON o.id = n.id
            JOIN thread a ON a.id = n.thread_id
        WHERE
            o.draft = FALSE
            AND n.draft = FALSE
            AND a.draft = FALSE
            AND (n.content IS DISTINCT FROM o.content
                OR n.author_id IS DISTINCT FROM o.author_id
                OR n.source_created_at IS DISTINCT FROM o.source_created_at
                OR n.archived_at IS DISTINCT FROM o.archived_at
                OR n.re_note_id IS DISTINCT FROM o.re_note_id
                OR n.mentions IS DISTINCT FROM o.mentions
                OR n.actions IS DISTINCT FROM o.actions
                OR n.draft IS DISTINCT FROM o.draft
                OR n.access_contacts IS DISTINCT FROM o.access_contacts
                OR n.access_groups IS DISTINCT FROM o.access_groups
                OR n.updated_by IS DISTINCT FROM o.updated_by);
    END IF;
    IF v_create_timestamp IS NULL AND v_update_timestamp IS NULL THEN
        RETURN NULL;
    END IF;
    IF v_create_timestamp IS NOT NULL AND v_create_seq IS NULL THEN
        v_create_seq := pg_current_xact_id();
    END IF;
    IF v_update_timestamp IS NOT NULL AND v_update_seq IS NULL THEN
        v_update_seq := pg_current_xact_id();
    END IF;
    IF v_create_timestamp IS NOT NULL THEN
        IF TG_OP = 'INSERT' THEN
            FOR v_twist_instance_id IN SELECT DISTINCT
                pct.id
            FROM
                new_table n
                JOIN twist_instance pct ON pct.id = ANY (n.mentions)
            WHERE
                n.draft = FALSE
                AND pct.archived_at IS NULL
                AND n.created_by != pct.id
            ORDER BY
                id LOOP
                    INSERT INTO twist_instance_sync (twist_instance_id, entity, operation, last_update_at, last_update_seq)
                        VALUES (v_twist_instance_id, 'note', 'create', v_create_timestamp, v_create_seq)
                    ON CONFLICT (twist_instance_id, entity, operation)
                        DO UPDATE SET
                            last_update_at = GREATEST (twist_instance_sync.last_update_at, EXCLUDED.last_update_at),
                            last_update_seq = GREATEST (twist_instance_sync.last_update_seq, EXCLUDED.last_update_seq);
                END LOOP;
        ELSE
            FOR v_twist_instance_id IN SELECT DISTINCT
                pct.id
            FROM
                new_table n
                JOIN old_table o ON o.id = n.id
                JOIN twist_instance pct ON pct.id = ANY (n.mentions)
            WHERE
                o.draft = TRUE
                AND n.draft = FALSE
                AND pct.archived_at IS NULL
                AND n.created_by != pct.id
            ORDER BY
                id LOOP
                    INSERT INTO twist_instance_sync (twist_instance_id, entity, operation, last_update_at, last_update_seq)
                        VALUES (v_twist_instance_id, 'note', 'create', v_create_timestamp, v_create_seq)
                    ON CONFLICT (twist_instance_id, entity, operation)
                        DO UPDATE SET
                            last_update_at = GREATEST (twist_instance_sync.last_update_at, EXCLUDED.last_update_at),
                            last_update_seq = GREATEST (twist_instance_sync.last_update_seq, EXCLUDED.last_update_seq);
                END LOOP;
        END IF;
    END IF;
    IF v_update_timestamp IS NOT NULL THEN
        FOR v_twist_instance_id IN SELECT DISTINCT
            pct.id
        FROM
            new_table n
            JOIN old_table o ON o.id = n.id
            JOIN twist_instance pct ON pct.id = n.created_by
        WHERE
            n.draft = FALSE
            AND o.draft = FALSE
            AND pct.archived_at IS NULL
        ORDER BY
            id LOOP
                INSERT INTO twist_instance_sync (twist_instance_id, entity, operation, last_update_at, last_update_seq)
                    VALUES (v_twist_instance_id, 'note', 'update', v_update_timestamp, v_update_seq)
                ON CONFLICT (twist_instance_id, entity, operation)
                    DO UPDATE SET
                        last_update_at = GREATEST (twist_instance_sync.last_update_at, EXCLUDED.last_update_at),
                        last_update_seq = GREATEST (twist_instance_sync.last_update_seq, EXCLUDED.last_update_seq);
            END LOOP;
    END IF;
    RETURN NULL;
END;
$$;
-- Create "upsert_note" function
CREATE FUNCTION "user"."upsert_note" ("user_id" uuid, "p_id" uuid, "p_author_id" uuid, "p_created_by" uuid, "p_updated_by" integer, "p_archived_at" timestamptz, "p_thread_id" uuid, "p_draft" boolean, "p_access_contacts" uuid[], "p_access_groups" uuid[], "p_content" text, "p_actions" jsonb, "p_mentions" uuid[], "p_re_note_id" uuid, "p_source_created_at" timestamptz, "p_key" text, "p_merged_from_thread_id" uuid DEFAULT NULL::uuid) RETURNS "public"."note" LANGUAGE plpgsql SET "search_path" = public, "user" AS $$
DECLARE
    v_priority_id uuid;
    v_created_by uuid;
    v_author_id uuid;
    v_existing_thread_id uuid;
    v_row note;
BEGIN
    -- If p_id refers to an existing note, verify the caller has access to
    -- its CURRENT thread before allowing the upsert. Without this, anyone
    -- who learns a note's UUID (e.g. via user.note_redacted after losing
    -- visibility) could move the note onto a thread they own and rewrite
    -- its content / archived_at while bypassing the original thread's
    -- access controls. The user.note_redacted view exposes note ids and
    -- thread_ids for notes that became invisible, so this attack vector
    -- is reachable from normal sync traffic.
    IF p_id IS NOT NULL THEN
        SELECT thread_id INTO v_existing_thread_id FROM note WHERE id = p_id;
        IF v_existing_thread_id IS NOT NULL THEN
            IF NOT EXISTS (
                SELECT 1 FROM thread_priority tp
                WHERE tp.thread_id = v_existing_thread_id
                  AND tp.user_id = upsert_note.user_id
            ) THEN
                RAISE EXCEPTION 'Note not found';
            END IF;
        END IF;
    END IF;

    SELECT
        tp.priority_id INTO v_priority_id
    FROM
        thread_priority tp
    WHERE
        tp.thread_id = p_thread_id
        AND tp.user_id = upsert_note.user_id;
    IF v_priority_id IS NULL THEN
        RAISE EXCEPTION 'Thread not found';
    END IF;

    -- Visibility is established by the thread_priority lookup above. The
    -- read-only viewer gate below uses user_has_thread_write_access(), which
    -- accepts write access via contacts OR non-announce group membership OR
    -- admin of an announce group, and forces announce-only viewers down the
    -- access_contacts path. Don't add a stricter contacts-only check here —
    -- it silently strands notes from users whose write access comes via
    -- group membership rather than direct contact in thread.contacts.

    v_created_by := COALESCE(p_created_by, user_id);
    -- When the user creates directly (not via twist), force author to their contact ID.
    -- This prevents impersonation: clients cannot spoof author_id.
    -- When a twist creates (created_by != user_id), trust the provided author_id.
    IF v_created_by = user_id THEN
        v_author_id := COALESCE("user".user_contact_id(user_id), user_id);
    ELSE
        v_author_id := COALESCE(p_author_id, v_created_by);
    END IF;

    -- Read-only viewer gate. When the writer is a user (not a twist) and
    -- lacks write access to the thread (i.e. only sees it via an announce
    -- group), they may only post private notes that they author and may not
    -- edit other authors' notes.
    IF v_created_by = upsert_note.user_id
       AND NOT "user".user_has_thread_write_access(upsert_note.user_id, p_thread_id)
    THEN
        IF p_access_contacts IS NULL AND p_access_groups IS NULL THEN
            RAISE EXCEPTION 'Read-only viewers must scope notes via access_contacts or access_groups';
        END IF;
        IF p_id IS NOT NULL AND EXISTS (
            SELECT 1 FROM note
            WHERE id = p_id
              AND author_id IS DISTINCT FROM v_author_id
        ) THEN
            RAISE EXCEPTION 'User cannot edit another author''s note';
        END IF;
    END IF;

    IF v_created_by IS DISTINCT FROM user_id THEN
        IF NOT EXISTS (
            SELECT
                1
            FROM
                twist_instance pt
            WHERE
                pt.id = v_created_by
                AND pt.owner_id = upsert_note.user_id) THEN
            RAISE EXCEPTION 'created_by must be user or owned twist_instance';
        END IF;
    END IF;

    IF p_id IS NULL THEN
        INSERT INTO note (id, author_id, created_by, updated_by, archived_at, thread_id, draft, access_contacts, access_groups, content, actions, mentions, re_note_id, source_created_at, key, merged_from_thread_id)
            VALUES (uuidv7(), v_author_id, v_created_by, COALESCE(p_updated_by, 0), p_archived_at, p_thread_id, COALESCE(p_draft, FALSE), p_access_contacts, p_access_groups, p_content, p_actions, p_mentions, p_re_note_id, COALESCE(p_source_created_at, now()), p_key, p_merged_from_thread_id)
        ON CONFLICT (thread_id, link_id, key)
            WHERE key IS NOT NULL
            DO UPDATE SET
                author_id = note.author_id,
                created_by = note.created_by,
                updated_by = EXCLUDED.updated_by,
                archived_at = EXCLUDED.archived_at,
                draft = EXCLUDED.draft,
                access_contacts = EXCLUDED.access_contacts,
                access_groups = EXCLUDED.access_groups,
                content = EXCLUDED.content,
                actions = EXCLUDED.actions,
                mentions = EXCLUDED.mentions,
                re_note_id = EXCLUDED.re_note_id,
                source_created_at = EXCLUDED.source_created_at,
                key = EXCLUDED.key,
                merged_from_thread_id = EXCLUDED.merged_from_thread_id,
                updated_at = now()
        RETURNING * INTO v_row;
    ELSE
        INSERT INTO note (id, author_id, created_by, updated_by, archived_at, thread_id, draft, access_contacts, access_groups, content, actions, mentions, re_note_id, source_created_at, key, merged_from_thread_id)
            VALUES (p_id, v_author_id, v_created_by, COALESCE(p_updated_by, 0), p_archived_at, p_thread_id, COALESCE(p_draft, FALSE), p_access_contacts, p_access_groups, p_content, p_actions, p_mentions, p_re_note_id, COALESCE(p_source_created_at, now()), p_key, p_merged_from_thread_id)
        ON CONFLICT (id)
            DO UPDATE SET
                author_id = note.author_id,
                created_by = note.created_by,
                updated_by = EXCLUDED.updated_by,
                archived_at = EXCLUDED.archived_at,
                thread_id = EXCLUDED.thread_id,
                draft = EXCLUDED.draft,
                access_contacts = EXCLUDED.access_contacts,
                access_groups = EXCLUDED.access_groups,
                content = EXCLUDED.content,
                actions = EXCLUDED.actions,
                mentions = EXCLUDED.mentions,
                re_note_id = EXCLUDED.re_note_id,
                source_created_at = EXCLUDED.source_created_at,
                key = COALESCE(EXCLUDED.key, note.key),
                merged_from_thread_id = EXCLUDED.merged_from_thread_id,
                updated_at = now()
        RETURNING * INTO v_row;
    END IF;

    RETURN v_row;
END;
$$;
-- Drop "upsert_note" function
DROP FUNCTION "user"."upsert_note" (uuid, uuid, uuid, uuid, integer, timestamptz, uuid, boolean, uuid[], text, jsonb, uuid[], uuid, timestamptz, text, uuid);
