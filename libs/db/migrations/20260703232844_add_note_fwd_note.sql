-- Modify "note" table
ALTER TABLE "public"."note" ADD COLUMN "fwd_note" uuid NULL, ADD CONSTRAINT "note_fwd_note_fkey" FOREIGN KEY ("fwd_note") REFERENCES "public"."note" ("id") ON UPDATE NO ACTION ON DELETE SET NULL;
-- Drop "upsert_note" function
DROP FUNCTION "user"."upsert_note" (uuid, uuid, uuid, uuid, integer, timestamptz, uuid, boolean, uuid[], uuid[], text, jsonb, uuid[], uuid, timestamptz, text, uuid, timestamptz);
-- Create "upsert_note" function
CREATE FUNCTION "user"."upsert_note" ("user_id" uuid, "p_id" uuid, "p_author_id" uuid, "p_created_by" uuid, "p_updated_by" integer, "p_archived_at" timestamptz, "p_thread_id" uuid, "p_draft" boolean, "p_access_contacts" uuid[], "p_access_groups" uuid[], "p_content" text, "p_actions" jsonb, "p_mentions" uuid[], "p_re_note_id" uuid, "p_source_created_at" timestamptz, "p_key" text, "p_merged_from_thread_id" uuid DEFAULT NULL::uuid, "p_send_at" timestamptz DEFAULT NULL::timestamp with time zone, "p_fwd_note" uuid DEFAULT NULL::uuid) RETURNS "public"."note" LANGUAGE plpgsql SET "search_path" = public, "user" AS $$
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

    -- Read-only viewer gate. A user who reaches the thread only via an
    -- announce group (no write access) may post only scoped notes they
    -- author, and the scope is bounded to the thread's contacts plus its
    -- non-announce groups (announce groups where they are not an admin are
    -- excluded). This is the server-side enforcement of the reply rule and
    -- prevents a viewer from broadcasting back to the announce audience.
    IF v_created_by = upsert_note.user_id
       AND NOT "user".user_has_thread_write_access(upsert_note.user_id, p_thread_id)
    THEN
        -- Must be scoped (no public notes).
        IF p_access_contacts IS NULL AND p_access_groups IS NULL THEN
            RAISE EXCEPTION 'Read-only viewers must scope notes via access_contacts or access_groups';
        END IF;

        -- access_contacts ⊆ thread.contacts ∪ caller's own linked contacts.
        IF p_access_contacts IS NOT NULL AND EXISTS (
            SELECT 1
            FROM unnest(p_access_contacts) AS c(id)
            WHERE c.id <> ALL (
                COALESCE((SELECT contacts FROM thread WHERE id = p_thread_id), ARRAY[]::uuid[])
                || "user".user_contact_ids(upsert_note.user_id)
            )
        ) THEN
            RAISE EXCEPTION 'Read-only viewers may only scope notes to thread contacts';
        END IF;

        -- access_groups ⊆ thread.groups, excluding announce groups where the
        -- caller is not an admin; reject non-existent or archived groups.
        IF p_access_groups IS NOT NULL AND EXISTS (
            SELECT 1
            FROM unnest(p_access_groups) AS g(id)
            LEFT JOIN "group" gr ON gr.id = g.id
            WHERE
                gr.id IS NULL                       -- non-existent group
                OR gr.archived_at IS NOT NULL       -- archived group
                OR g.id <> ALL (COALESCE((SELECT groups FROM thread WHERE id = p_thread_id), ARRAY[]::uuid[]))
                OR (
                    gr.type = 'announce'
                    AND NOT EXISTS (
                        SELECT 1 FROM group_admin ga
                        WHERE ga.group_id = g.id AND ga.user_id = upsert_note.user_id
                    )
                )
        ) THEN
            RAISE EXCEPTION 'Read-only viewers may only scope notes to non-announce thread groups';
        END IF;

        -- May not edit another author's note.
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
        INSERT INTO note (id, author_id, created_by, updated_by, archived_at, thread_id, draft, access_contacts, access_groups, content, actions, mentions, re_note_id, fwd_note, source_created_at, key, merged_from_thread_id, send_at)
            VALUES (uuidv7(), v_author_id, v_created_by, COALESCE(p_updated_by, 0), p_archived_at, p_thread_id, COALESCE(p_draft, FALSE), p_access_contacts, p_access_groups, p_content, p_actions, p_mentions, p_re_note_id, p_fwd_note, COALESCE(p_source_created_at, now()), p_key, p_merged_from_thread_id, p_send_at)
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
                fwd_note = EXCLUDED.fwd_note,
                source_created_at = EXCLUDED.source_created_at,
                key = EXCLUDED.key,
                merged_from_thread_id = EXCLUDED.merged_from_thread_id,
                -- Never let an upsert CLEAR a hold: clients cancel a schedule
                -- by archiving the note, and release is the sweep's job. An
                -- old client editing a held note omits send_at — COALESCE
                -- keeps the hold instead of firing the note immediately.
                send_at = COALESCE(EXCLUDED.send_at, note.send_at),
                updated_at = now()
        RETURNING * INTO v_row;
    ELSE
        INSERT INTO note (id, author_id, created_by, updated_by, archived_at, thread_id, draft, access_contacts, access_groups, content, actions, mentions, re_note_id, fwd_note, source_created_at, key, merged_from_thread_id, send_at)
            VALUES (p_id, v_author_id, v_created_by, COALESCE(p_updated_by, 0), p_archived_at, p_thread_id, COALESCE(p_draft, FALSE), p_access_contacts, p_access_groups, p_content, p_actions, p_mentions, p_re_note_id, p_fwd_note, COALESCE(p_source_created_at, now()), p_key, p_merged_from_thread_id, p_send_at)
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
                fwd_note = EXCLUDED.fwd_note,
                source_created_at = EXCLUDED.source_created_at,
                key = COALESCE(EXCLUDED.key, note.key),
                merged_from_thread_id = EXCLUDED.merged_from_thread_id,
                -- COALESCE: see the keyed path above — an upsert may set or
                -- keep a hold but never clear one.
                send_at = COALESCE(EXCLUDED.send_at, note.send_at),
                updated_at = now()
        RETURNING * INTO v_row;
    END IF;

    RETURN v_row;
END;
$$;
