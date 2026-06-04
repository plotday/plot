-- Modify "update_thread_on_note_change" function
CREATE OR REPLACE FUNCTION "public"."update_thread_on_note_change" () RETURNS trigger LANGUAGE plpgsql SET "search_path" = public AS $$
BEGIN
    -- Only act on visible, non-draft notes.
    IF NEW.draft = FALSE AND NEW.archived_at IS NULL THEN
        PERFORM pg_advisory_xact_lock(hashtext(NEW.thread_id::text));

        IF NEW.access_contacts IS NULL AND NEW.access_groups IS NULL THEN
            -- UNSCOPED note: everyone who can see the thread can see it.
            -- Bump the shared last_note_* columns exactly as before so the
            -- thread re-emits / re-sorts for all recipients.
            UPDATE thread
            SET last_note_created_at = GREATEST (last_note_created_at, NEW.created_at),
                last_note_source_created_at = GREATEST (last_note_source_created_at, NEW.source_created_at),
                last_note_seq = GREATEST (last_note_seq, NEW.seq),
                updated_by = NEW.updated_by
            WHERE id = NEW.thread_id
              AND (last_note_created_at IS NULL
                  OR last_note_created_at < NEW.created_at
                  OR last_note_source_created_at IS NULL
                  OR last_note_source_created_at < NEW.source_created_at
                  OR last_note_seq < NEW.seq);
        ELSE
            -- SCOPED note: do NOT touch the shared last_note_* columns (that
            -- would re-emit the thread for the whole audience, leaking the
            -- existence of a private reply). Instead bump thread_state for
            -- exactly the users who can see this note, so the thread
            -- re-emits / re-sorts / unreads only for them. The author's row
            -- is bumped but kept read; other visible users get read_at = NULL.
            INSERT INTO thread_state (user_id, thread_id, read_at, bumped_at)
            SELECT v.user_id,
                   NEW.thread_id,
                   CASE WHEN v.user_id = NEW.created_by THEN now() ELSE NULL END,
                   now()
            FROM (
                SELECT tp.user_id
                FROM thread_priority tp
                WHERE tp.thread_id = NEW.thread_id
                  AND tp.revoked_at IS NULL
                  AND (
                      tp.user_id = NEW.created_by
                      OR (NEW.access_contacts IS NOT NULL
                          AND NEW.access_contacts && "user".user_contact_ids(tp.user_id))
                      OR (NEW.access_groups IS NOT NULL
                          AND NEW.access_groups && "user".user_group_ids(tp.user_id))
                  )
            ) v
            ON CONFLICT (user_id, thread_id) DO UPDATE
            SET bumped_at = now(),
                -- A non-author visible user must see the thread as unread
                -- again; never clobber the author's own read state.
                read_at = CASE
                    WHEN thread_state.user_id = NEW.created_by THEN thread_state.read_at
                    ELSE NULL
                END,
                updated_at = now();
        END IF;
    END IF;
    RETURN COALESCE(NEW, OLD);
END;
$$;
-- Modify "upsert_note" function
CREATE OR REPLACE FUNCTION "user"."upsert_note" ("user_id" uuid, "p_id" uuid, "p_author_id" uuid, "p_created_by" uuid, "p_updated_by" integer, "p_archived_at" timestamptz, "p_thread_id" uuid, "p_draft" boolean, "p_access_contacts" uuid[], "p_access_groups" uuid[], "p_content" text, "p_actions" jsonb, "p_mentions" uuid[], "p_re_note_id" uuid, "p_source_created_at" timestamptz, "p_key" text, "p_merged_from_thread_id" uuid DEFAULT NULL::uuid) RETURNS "public"."note" LANGUAGE plpgsql SET "search_path" = public, "user" AS $$
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

-- ---------------------------------------------------------------------------
-- Data migration: address the seven global onboarding threads to the author
-- (as a contact) + Plot Team (non-announce group) so read-only recipients'
-- replies reach Plot Team + author only. Idempotent.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_team uuid;
    v_keys text[] := ARRAY['welcome','priorities','connections',
                           'getting-around','twists','notifications','clean-up'];
BEGIN
    SELECT id INTO v_team FROM "group" WHERE key = '@plot.team' AND archived_at IS NULL LIMIT 1;

    -- Snapshot existing thread_state keys for these threads so we can keep
    -- Plot Team dormant: any thread_state rows the group-file trigger newly
    -- creates below are removed, leaving only pre-existing (read) rows.
    CREATE TEMP TABLE _pre_ts ON COMMIT DROP AS
        SELECT ts.user_id, ts.thread_id
        FROM thread_state ts
        JOIN thread t ON t.id = ts.thread_id
        WHERE t.key = ANY(v_keys);

    -- 1. Add each thread's own note author (the Kris contact) to contacts.
    UPDATE thread t
    SET contacts = (
        SELECT COALESCE(array_agg(DISTINCT x), ARRAY[]::uuid[])
        FROM unnest(COALESCE(t.contacts, ARRAY[]::uuid[]) || ARRAY[a.author_id]) AS x
    )
    FROM (
        SELECT DISTINCT ON (n.thread_id) n.thread_id, n.author_id
        FROM note n JOIN thread t2 ON t2.id = n.thread_id
        WHERE t2.key = ANY(v_keys) AND n.author_id IS NOT NULL
        ORDER BY n.thread_id, n.source_created_at ASC
    ) a
    WHERE t.id = a.thread_id
      AND NOT (a.author_id = ANY(COALESCE(t.contacts, ARRAY[]::uuid[])));

    -- 2. Add Plot Team to groups (fires file_thread_priority_for_group_members).
    IF v_team IS NOT NULL THEN
        UPDATE thread
        SET groups = COALESCE(groups, ARRAY[]::uuid[]) || ARRAY[v_team]
        WHERE key = ANY(v_keys)
          AND NOT (v_team = ANY(COALESCE(groups, ARRAY[]::uuid[])));

        -- 3. Keep Plot Team dormant: delete the thread_state rows the group-file
        --    trigger just created (not present before) FOR PLOT TEAM MEMBERS
        --    ONLY. The step-1 contacts update may also have created a fresh
        --    thread_state row for the author's own user (a non-team-member
        --    visibility path); restricting the DELETE to Plot Team members
        --    leaves those untouched. thread_state is not directly synced (it
        --    feeds computed columns on user.thread), so a bare DELETE here is
        --    safe — see libs/db/AGENTS.md.
        DELETE FROM thread_state ts
        USING thread t
        JOIN group_member gm ON gm.group_id = v_team
        JOIN user_contact uc ON uc.contact_id = gm.contact_id
            AND uc.linked = TRUE AND uc.archived_at IS NULL
        WHERE ts.thread_id = t.id
          AND ts.user_id = uc.user_id
          AND t.key = ANY(v_keys)
          AND NOT EXISTS (
              SELECT 1 FROM _pre_ts p
              WHERE p.user_id = ts.user_id AND p.thread_id = ts.thread_id
          );
    END IF;
END $$;
