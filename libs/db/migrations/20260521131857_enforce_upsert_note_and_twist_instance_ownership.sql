-- Modify "upsert_note" function
CREATE OR REPLACE FUNCTION "user"."upsert_note" ("user_id" uuid, "p_id" uuid, "p_author_id" uuid, "p_created_by" uuid, "p_updated_by" integer, "p_archived_at" timestamptz, "p_thread_id" uuid, "p_draft" boolean, "p_access_contacts" uuid[], "p_content" text, "p_actions" jsonb, "p_mentions" uuid[], "p_re_note_id" uuid, "p_source_created_at" timestamptz, "p_key" text, "p_merged_from_thread_id" uuid DEFAULT NULL::uuid) RETURNS "public"."note" LANGUAGE plpgsql SET "search_path" = public, "user" AS $$
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
        IF p_access_contacts IS NULL THEN
            RAISE EXCEPTION 'Read-only viewers must scope notes via access_contacts';
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
        INSERT INTO note (id, author_id, created_by, updated_by, archived_at, thread_id, draft, access_contacts, content, actions, mentions, re_note_id, source_created_at, key, merged_from_thread_id)
            VALUES (uuidv7(), v_author_id, v_created_by, COALESCE(p_updated_by, 0), p_archived_at, p_thread_id, COALESCE(p_draft, FALSE), p_access_contacts, p_content, p_actions, p_mentions, p_re_note_id, COALESCE(p_source_created_at, now()), p_key, p_merged_from_thread_id)
        ON CONFLICT (thread_id, link_id, key)
            WHERE key IS NOT NULL
            DO UPDATE SET
                author_id = note.author_id,
                created_by = note.created_by,
                updated_by = EXCLUDED.updated_by,
                archived_at = EXCLUDED.archived_at,
                draft = EXCLUDED.draft,
                access_contacts = EXCLUDED.access_contacts,
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
        INSERT INTO note (id, author_id, created_by, updated_by, archived_at, thread_id, draft, access_contacts, content, actions, mentions, re_note_id, source_created_at, key, merged_from_thread_id)
            VALUES (p_id, v_author_id, v_created_by, COALESCE(p_updated_by, 0), p_archived_at, p_thread_id, COALESCE(p_draft, FALSE), p_access_contacts, p_content, p_actions, p_mentions, p_re_note_id, COALESCE(p_source_created_at, now()), p_key, p_merged_from_thread_id)
        ON CONFLICT (id)
            DO UPDATE SET
                author_id = note.author_id,
                created_by = note.created_by,
                updated_by = EXCLUDED.updated_by,
                archived_at = EXCLUDED.archived_at,
                thread_id = EXCLUDED.thread_id,
                draft = EXCLUDED.draft,
                access_contacts = EXCLUDED.access_contacts,
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
-- Modify "upsert_twist_instance" function
CREATE OR REPLACE FUNCTION "user"."upsert_twist_instance" ("user_id" uuid, "p_id" uuid, "p_twist_id" bigint, "p_owner_id" uuid, "p_team_id" bigint, "p_name" text, "p_account_label" text, "p_config" jsonb, "p_archived_at" timestamptz) RETURNS "public"."twist_instance" LANGUAGE plpgsql SET "search_path" = public, "user" AS $$
DECLARE
    v_existing_owner uuid;
    v_row twist_instance;
BEGIN
    -- Twist instances are owned by a user and optionally billed to a team.
    -- The caller can only manage their own instances.
    IF p_owner_id IS DISTINCT FROM user_id THEN
        RAISE EXCEPTION 'owner_id must match user_id';
    END IF;

    -- If a team is specified, the caller must be a member.
    IF p_team_id IS NOT NULL THEN
        IF NOT EXISTS (
            SELECT 1 FROM team_user
            WHERE team_id = p_team_id AND team_user.user_id = upsert_twist_instance.user_id
        ) THEN
            RAISE EXCEPTION 'User is not a member of team %', p_team_id;
        END IF;
    END IF;

    -- If p_id refers to an existing row, the caller must own it. Without
    -- this check the ON CONFLICT UPDATE branch happily clobbers another
    -- user's twist_instance (rename, archive, swap team, replace options)
    -- as long as p_owner_id == user_id — which the attacker trivially
    -- satisfies. Twist instance UUIDs leak via user.link.created_by,
    -- user.channel.twist_instance_id, and other peer-visible columns,
    -- so this is reachable from normal sync traffic.
    IF p_id IS NOT NULL THEN
        SELECT owner_id INTO v_existing_owner FROM twist_instance WHERE id = p_id;
        IF v_existing_owner IS NOT NULL
           AND v_existing_owner IS DISTINCT FROM upsert_twist_instance.user_id
        THEN
            RAISE EXCEPTION 'Twist instance not found';
        END IF;
    END IF;

    INSERT INTO twist_instance (id, twist_id, owner_id, team_id, name, account_label, options, archived_at)
        VALUES (COALESCE(p_id, uuidv7()), p_twist_id, p_owner_id, p_team_id, p_name, p_account_label, COALESCE(p_config, '{}'::jsonb), p_archived_at)
    ON CONFLICT (id)
        DO UPDATE SET
            name = EXCLUDED.name,
            account_label = EXCLUDED.account_label,
            team_id = EXCLUDED.team_id,
            options = EXCLUDED.options,
            archived_at = EXCLUDED.archived_at,
            updated_at = now()
    RETURNING * INTO v_row;

    RETURN v_row;
END;
$$;
