-- Modify "group" table
ALTER TABLE "public"."group" ADD COLUMN "key" text NULL, ADD CONSTRAINT "group_key_unique" UNIQUE ("key");
-- Set comment to column: "key" on table: "group"
COMMENT ON COLUMN "public"."group"."key" IS 'Stable identifier for system-managed groups (e.g. ''@plot.team''). Drives special-cased visibility in the user.group view. Nullable; user-created groups have no key.';
-- Modify "auto_create_team_group" function
CREATE OR REPLACE FUNCTION "public"."auto_create_team_group" () RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    v_group_id uuid;
    v_first_admin_id uuid;
BEGIN
    SELECT tu.user_id INTO v_first_admin_id
    FROM team_user tu
    WHERE tu.team_id = NEW.id
    ORDER BY (tu.role = 'admin') DESC, tu.created_at ASC
    LIMIT 1;

    IF v_first_admin_id IS NULL THEN
        RETURN NEW;
    END IF;

    INSERT INTO "group" (name, type, team_id, created_by, auto_maintained, key)
    VALUES (
        NEW.name || ' Team',
        'team',
        NEW.id,
        v_first_admin_id,
        TRUE,
        CASE WHEN NEW.name = 'Plot' THEN '@plot.team' ELSE NULL END
    )
    ON CONFLICT DO NOTHING;

    RETURN NEW;
END;
$$;
-- Modify "auto_maintain_team_group_members" function
CREATE OR REPLACE FUNCTION "public"."auto_maintain_team_group_members" () RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    v_group_id uuid;
    v_contact_id uuid;
    v_team_id bigint;
    v_user_id uuid;
BEGIN
    IF TG_OP = 'DELETE' THEN
        v_team_id := OLD.team_id;
        v_user_id := OLD.user_id;
    ELSE
        v_team_id := NEW.team_id;
        v_user_id := NEW.user_id;
    END IF;

    SELECT id INTO v_group_id
    FROM "group"
    WHERE team_id = v_team_id AND auto_maintained = TRUE AND auto_team_admin_team_id IS NULL;

    IF v_group_id IS NULL AND TG_OP != 'DELETE' THEN
        INSERT INTO "group" (name, type, team_id, created_by, auto_maintained, key)
        SELECT
            t.name || ' Team',
            'team',
            t.id,
            v_user_id,
            TRUE,
            CASE WHEN t.name = 'Plot' THEN '@plot.team' ELSE NULL END
        FROM team t WHERE t.id = v_team_id
        ON CONFLICT DO NOTHING
        RETURNING id INTO v_group_id;

        IF v_group_id IS NULL THEN
            SELECT id INTO v_group_id
            FROM "group"
            WHERE team_id = v_team_id AND auto_maintained = TRUE AND auto_team_admin_team_id IS NULL;
        END IF;
    END IF;

    IF v_group_id IS NULL THEN
        RETURN COALESCE(NEW, OLD);
    END IF;

    SELECT uc.contact_id INTO v_contact_id
    FROM user_contact uc
    WHERE uc.user_id = v_user_id
      AND uc."primary" = TRUE
      AND uc.linked = TRUE
      AND uc.archived_at IS NULL;

    IF TG_OP = 'INSERT' THEN
        IF v_contact_id IS NOT NULL THEN
            INSERT INTO group_member (group_id, contact_id)
            VALUES (v_group_id, v_contact_id)
            ON CONFLICT DO NOTHING;
        END IF;
        IF NEW.role = 'admin' THEN
            INSERT INTO group_admin (group_id, user_id)
            VALUES (v_group_id, v_user_id)
            ON CONFLICT DO NOTHING;
        END IF;
    ELSIF TG_OP = 'DELETE' THEN
        IF v_contact_id IS NOT NULL THEN
            DELETE FROM group_member
            WHERE group_id = v_group_id AND contact_id = v_contact_id;
        END IF;
        DELETE FROM group_admin
        WHERE group_id = v_group_id AND user_id = v_user_id;
    ELSIF TG_OP = 'UPDATE' THEN
        IF NEW.role = 'admin' AND OLD.role != 'admin' THEN
            INSERT INTO group_admin (group_id, user_id)
            VALUES (v_group_id, v_user_id)
            ON CONFLICT DO NOTHING;
        ELSIF NEW.role != 'admin' AND OLD.role = 'admin' THEN
            DELETE FROM group_admin
            WHERE group_id = v_group_id AND user_id = v_user_id;
        END IF;
    END IF;

    RETURN COALESCE(NEW, OLD);
END;
$$;
-- Modify "share_thread_with_groups" function
CREATE OR REPLACE FUNCTION "public"."share_thread_with_groups" ("p_user_id" uuid, "p_thread_id" uuid, "p_add_group_ids" uuid[] DEFAULT ARRAY[]::uuid[], "p_remove_group_ids" uuid[] DEFAULT ARRAY[]::uuid[]) RETURNS jsonb LANGUAGE plpgsql SET "search_path" = public AS $$
DECLARE
    v_current_groups uuid[];
    v_new_groups uuid[];
    v_group RECORD;
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM thread_priority tp
        WHERE tp.thread_id = p_thread_id
          AND tp.user_id = p_user_id
    ) THEN
        RAISE EXCEPTION 'User does not have access to this thread';
    END IF;

    FOR v_group IN
        SELECT g.id, g.type
        FROM unnest(p_add_group_ids) AS arr(id)
        JOIN "group" g ON g.id = arr.id
        WHERE g.archived_at IS NULL
    LOOP
        IF v_group.type = 'announce' THEN
            -- Announce groups stay admin-only post (existing inverted role:
            -- everyone receives, only admins broadcast).
            IF NOT EXISTS (
                SELECT 1 FROM group_admin
                WHERE group_id = v_group.id AND user_id = p_user_id
            ) THEN
                RAISE EXCEPTION 'Only admins can add announce groups to threads';
            END IF;
        ELSE
            -- Anyone with picker visibility can address the group. Drives off
            -- the same user.group view that decides whether the chip renders,
            -- so "can see it" and "can post to it" are the same gate. Posting
            -- never grants the poster read access to existing threads — only
            -- members receive what's sent (via file_thread_priority_for_group_members).
            IF NOT EXISTS (
                SELECT 1 FROM "user"."group" ug
                WHERE ug.user_id = p_user_id AND ug.id = v_group.id
            ) THEN
                RAISE EXCEPTION 'User does not have permission to add this group';
            END IF;
        END IF;
    END LOOP;

    SELECT groups INTO v_current_groups
    FROM thread
    WHERE id = p_thread_id;

    IF v_current_groups IS NULL THEN
        v_current_groups := ARRAY[]::uuid[];
    END IF;

    SELECT COALESCE(array_agg(DISTINCT gid), ARRAY[]::uuid[])
    INTO v_new_groups
    FROM (
        SELECT unnest(v_current_groups) AS gid
        UNION
        SELECT unnest(p_add_group_ids)
    ) all_groups
    WHERE gid != ALL(COALESCE(p_remove_group_ids, ARRAY[]::uuid[]));

    UPDATE thread
    SET groups = v_new_groups
    WHERE id = p_thread_id;

    RETURN jsonb_build_object('groups', to_jsonb(v_new_groups));
END;
$$;
-- Modify "upsert_thread" function
CREATE OR REPLACE FUNCTION "user"."upsert_thread" ("user_id" uuid, "p_thread" jsonb, "p_defaults" jsonb DEFAULT '{}') RETURNS "public"."thread" LANGUAGE plpgsql AS $$
DECLARE
    v_result thread;
    v_existing thread;
    v_id uuid;
    v_priority_id uuid;
    v_created_by uuid;
    v_twist_id bigint;
    v_is_archived boolean;
    -- All linked contact IDs for the calling user. Used to check attestation
    -- and to merge the caller's own contacts into the thread.
    v_user_contacts uuid[];
    -- The caller's primary linked contact (used when we need a single contact
    -- id to record in pending_contacts).
    v_user_primary_contact uuid;
    -- Caller-provided contacts, normalized to uuid[].
    v_input_contacts uuid[];
    -- Working set of contacts that will be written into thread.contacts.
    v_merged_contacts uuid[];
    -- Contacts being promoted out of pending_contacts on this call.
    v_promoted_contacts uuid[];
    -- Input groups normalized.
    v_input_groups uuid[];
    -- Input topic (text) — explicit value or NULL to derive the default.
    v_input_topic text;
    -- Derived topic for INSERT path.
    v_resolved_topic text;
    -- Whether the caller should get a thread_priority row this call.
    v_caller_attested boolean;
BEGIN
    -- Extract identifiers and derived values.
    v_id := COALESCE((p_thread ->> 'id')::uuid, (p_defaults ->> 'id')::uuid);
    v_priority_id := COALESCE((p_thread ->> 'priority_id')::uuid, (p_defaults ->> 'priority_id')::uuid);
    v_created_by := COALESCE((p_thread ->> 'created_by')::uuid, (p_defaults ->> 'created_by')::uuid, user_id);

    -- Load the caller's linked contacts (used for attestation and merging).
    SELECT COALESCE(array_agg(uc.contact_id), ARRAY[]::uuid[])
    INTO v_user_contacts
    FROM user_contact uc
    WHERE uc.user_id = upsert_thread.user_id
      AND uc.linked = TRUE
      AND uc.archived_at IS NULL;

    SELECT uc.contact_id
    INTO v_user_primary_contact
    FROM user_contact uc
    WHERE uc.user_id = upsert_thread.user_id
      AND uc.linked = TRUE
      AND uc.archived_at IS NULL
    ORDER BY uc.primary DESC NULLS LAST, uc.created_at ASC
    LIMIT 1;

    -- Derive twist_id from the caller's twist_instance (never from p_thread:
    -- callers are not allowed to spoof which twist owns a thread).
    IF v_created_by IS NOT NULL AND v_created_by IS DISTINCT FROM user_id THEN
        SELECT ti.twist_id INTO v_twist_id
        FROM twist_instance ti
        WHERE ti.id = v_created_by;
    END IF;

    -- If an id was not supplied, look up an existing thread by (twist_id, key)
    -- across all users. Restrict to non-archived threads so the (twist_id, key)
    -- slot can be reused after a prior thread was fully archived.
    IF v_id IS NULL THEN
        -- Serialize concurrent upserts for the same (twist_id, key) pair.
        -- Without this, two sessions can both see the lookup below miss,
        -- generate different uuidv7() ids, and both INSERT — the second
        -- violates thread_twist_key_unique. The advisory lock is
        -- transaction-scoped, so it releases on COMMIT/ROLLBACK.
        IF v_twist_id IS NOT NULL
           AND COALESCE(p_thread ->> 'key', p_defaults ->> 'key') IS NOT NULL THEN
            PERFORM pg_advisory_xact_lock(
                hashtextextended(
                    'thread_upsert|' ||
                    v_twist_id::text || '|' ||
                    COALESCE(p_thread ->> 'key', p_defaults ->> 'key'),
                    0
                )
            );
        END IF;
        IF (p_thread ? 'key')
            AND v_twist_id IS NOT NULL
            AND (p_thread ->> 'key') IS NOT NULL THEN
            SELECT t.id INTO v_id
            FROM thread t
            WHERE t.twist_id = v_twist_id
              AND t.key = (p_thread ->> 'key')
              AND t.archived_at IS NULL;
        END IF;
        IF v_id IS NULL THEN
            v_id := uuidv7 ();
        END IF;
    END IF;

    -- Resolve priority_id from the caller's existing thread_priority row.
    IF v_priority_id IS NULL THEN
        SELECT tp.priority_id INTO v_priority_id
        FROM thread_priority tp
        WHERE tp.thread_id = v_id
          AND tp.user_id = upsert_thread.user_id;
    END IF;

    -- Fall back to the user's root priority when the given priority isn't
    -- accessible. Priority is per-user organization, not access control, so
    -- we don't hard-fail on cross-user or missing priorities.
    IF v_priority_id IS NULL
       OR NOT user_has_priority_access(upsert_thread.user_id, v_priority_id) THEN
        SELECT p.id INTO v_priority_id
        FROM public.priority p
        WHERE p.user_id = upsert_thread.user_id
          AND nlevel(p.path) = 1
          AND p.archived_at IS NULL
        ORDER BY p.created_at ASC
        LIMIT 1;
        IF v_priority_id IS NULL THEN
            RAISE EXCEPTION 'User has no root priority';
        END IF;
    END IF;

    -- Validate created_by: either the caller or one of their own twist_instances.
    IF v_created_by IS DISTINCT FROM user_id THEN
        IF NOT EXISTS (
            SELECT 1
            FROM twist_instance pt
            WHERE pt.id = v_created_by
              AND pt.owner_id = upsert_thread.user_id
        ) THEN
            RAISE EXCEPTION 'created_by must be user or owned twist_instance';
        END IF;
    END IF;

    -- Load the existing row (if any) — used to satisfy CHECK constraints on
    -- the INSERT-with-ON-CONFLICT path and for merge semantics.
    SELECT * INTO v_existing FROM thread WHERE id = v_id;

    -- Read-only viewer gate. When the thread already exists and the caller
    -- is a user (not a twist) lacking write access, allow only a per-user
    -- archive: if archived_at is the only mutated field, set
    -- thread_priority.archived_at and return the unchanged thread. Reject
    -- any other metadata change.
    IF v_existing.id IS NOT NULL
       AND v_created_by = upsert_thread.user_id
       AND NOT "user".user_has_thread_write_access(upsert_thread.user_id, v_existing.id)
    THEN
        IF p_thread ? 'archived_at' THEN
            UPDATE thread_priority tp
            SET archived_at = NULLIF(p_thread ->> 'archived_at', '')::timestamptz,
                updated_at = now()
            WHERE tp.thread_id = v_existing.id
              AND tp.user_id = upsert_thread.user_id;
            -- Discard any other fields the caller sent — return unchanged.
            RETURN v_existing;
        END IF;
        RAISE EXCEPTION 'User does not have write access to thread';
    END IF;

    -- If the thread exists, this is effectively an update. We treat the
    -- thread as archived (triggering the insert-path fallthrough for missing
    -- fields) when thread.archived_at is set OR when the caller has no
    -- active (non-archived) thread_priority row. thread_priority.archived_at
    -- is the per-user archive marker.
    v_is_archived := COALESCE(
        v_existing.archived_at IS NOT NULL
        OR (v_existing.id IS NOT NULL AND NOT EXISTS (
            SELECT 1
            FROM thread_priority tp
            WHERE tp.thread_id = v_existing.id
              AND tp.user_id = upsert_thread.user_id
              AND tp.archived_at IS NULL
              AND EXISTS (
                  SELECT 1 FROM priority p
                  WHERE p.id = tp.priority_id
                    AND p.archived_at IS NULL
              )
        )),
        FALSE
    );

    -- Normalize caller-provided contacts and groups to uuid[].
    v_input_contacts := CASE
        WHEN p_thread ? 'contacts' AND jsonb_typeof(p_thread -> 'contacts') = 'array' THEN
            COALESCE((SELECT array_agg(elem::uuid) FROM jsonb_array_elements_text(p_thread -> 'contacts') elem), ARRAY[]::uuid[])
        WHEN p_defaults ? 'contacts' AND jsonb_typeof(p_defaults -> 'contacts') = 'array' THEN
            COALESCE((SELECT array_agg(elem::uuid) FROM jsonb_array_elements_text(p_defaults -> 'contacts') elem), ARRAY[]::uuid[])
        ELSE ARRAY[]::uuid[]
    END;

    v_input_groups := CASE
        WHEN p_thread ? 'groups' AND jsonb_typeof(p_thread -> 'groups') = 'array' THEN
            COALESCE((SELECT array_agg(elem::uuid) FROM jsonb_array_elements_text(p_thread -> 'groups') elem), ARRAY[]::uuid[])
        WHEN p_defaults ? 'groups' AND jsonb_typeof(p_defaults -> 'groups') = 'array' THEN
            COALESCE((SELECT array_agg(elem::uuid) FROM jsonb_array_elements_text(p_defaults -> 'groups') elem), ARRAY[]::uuid[])
        ELSE COALESCE(v_existing.groups, ARRAY[]::uuid[])
    END;

    v_input_topic := COALESCE(p_thread ->> 'topic', p_defaults ->> 'topic');

    -- On INSERT, derive a default topic when none was provided. Resolution
    -- order: priority.config->>'topic' → priority.id::text (for non-root
    -- priorities, so sibling threads filed in the same sub-priority share a
    -- topic filter for classify_thread_for_user) → groups[1]::text.
    IF v_existing.id IS NULL AND v_input_topic IS NULL THEN
        SELECT
            COALESCE(
                p.config ->> 'topic',
                CASE WHEN nlevel(p.path) > 1 THEN p.id::text END
            )
        INTO v_resolved_topic
        FROM public.priority p
        WHERE p.id = v_priority_id;

        IF v_resolved_topic IS NULL AND cardinality(v_input_groups) > 0 THEN
            v_resolved_topic := v_input_groups[1]::text;
        END IF;
    ELSE
        v_resolved_topic := v_input_topic;
    END IF;

    -- Attestation check (determined BEFORE we mutate thread.contacts so a
    -- caller can't self-attest by adding their own contact in the same call):
    --   - On insert: creator is always trusted with the initial contact list.
    --   - On update: caller is attested iff one of their linked contacts was
    --     already in thread.contacts before this call (or in pending_contacts,
    --     in which case this call promotes them).
    --   - User-created threads (v_created_by = user_id and no twist_id)
    --     bypass attestation — user flows go through share_thread.
    v_caller_attested := (v_existing.id IS NULL)
        OR (v_created_by = upsert_thread.user_id AND v_twist_id IS NULL)
        OR (v_user_contacts && COALESCE(v_existing.contacts, ARRAY[]::uuid[]));

    -- Decide contact merge policy based on attestation.
    IF v_caller_attested THEN
        -- Trusted caller: union existing and input contacts. If none of the
        -- caller's linked contacts are already represented, add their
        -- primary linked contact so the caller has visibility. We do NOT
        -- merge every linked contact of the caller — otherwise a user with
        -- multiple linked identities (work + personal email, etc.) shows
        -- up multiple times to every other viewer of the thread.
        SELECT COALESCE(array_agg(DISTINCT x), ARRAY[]::uuid[])
        INTO v_merged_contacts
        FROM unnest(
            COALESCE(v_existing.contacts, ARRAY[]::uuid[])
            || v_input_contacts
        ) AS x;

        IF v_user_primary_contact IS NOT NULL
           AND NOT (v_user_contacts && v_merged_contacts) THEN
            v_merged_contacts := v_merged_contacts || ARRAY[v_user_primary_contact];
        END IF;
    ELSE
        -- Untrusted caller: thread.contacts cannot be extended by this
        -- sync. The caller's primary linked contact lands in pending_contacts
        -- below (in the post-upsert branch).
        v_merged_contacts := COALESCE(v_existing.contacts, ARRAY[]::uuid[]);
    END IF;

    -- Identify contacts being promoted from pending_contacts on this call.
    -- Only a trusted (attested) caller can promote — otherwise a rogue
    -- instance could claim an attested user and push them into contacts.
    IF v_caller_attested
       AND v_existing.pending_contacts IS NOT NULL
       AND cardinality(v_existing.pending_contacts) > 0 THEN
        SELECT COALESCE(array_agg(DISTINCT p), ARRAY[]::uuid[])
        INTO v_promoted_contacts
        FROM unnest(v_existing.pending_contacts) AS p
        WHERE p = ANY(v_input_contacts);
        -- Promoted contacts also go into the merged contacts list.
        IF cardinality(v_promoted_contacts) > 0 THEN
            SELECT COALESCE(array_agg(DISTINCT x), ARRAY[]::uuid[])
            INTO v_merged_contacts
            FROM unnest(v_merged_contacts || v_promoted_contacts) AS x;
        END IF;
    ELSE
        v_promoted_contacts := ARRAY[]::uuid[];
    END IF;

    -- Perform the upsert. twist_id is set only on the insert path; the update
    -- path preserves thread.twist_id so first-creator wins.
    INSERT INTO thread (
        id, created_by, title, preview, updated_by, sync_depth, contacts, groups, topic,
        draft, key, icon, twist_id, pending_contacts
    )
    VALUES (
        v_id,
        v_created_by,
        COALESCE(p_thread ->> 'title', p_defaults ->> 'title', v_existing.title),
        COALESCE(p_thread ->> 'preview', p_defaults ->> 'preview', v_existing.preview),
        COALESCE((p_thread ->> 'updated_by')::integer, (p_defaults ->> 'updated_by')::integer, v_existing.updated_by, 0),
        COALESCE((p_thread ->> 'sync_depth')::smallint, (p_defaults ->> 'sync_depth')::smallint, v_existing.sync_depth),
        v_merged_contacts,
        v_input_groups,
        v_resolved_topic,
        COALESCE((p_thread ->> 'draft')::boolean, (p_defaults ->> 'draft')::boolean, v_existing.draft, FALSE),
        COALESCE(p_thread ->> 'key', p_defaults ->> 'key', v_existing.key),
        COALESCE(p_thread ->> 'icon', p_defaults ->> 'icon', v_existing.icon),
        v_twist_id,
        -- pending_contacts on the INSERT path starts empty; entries are added
        -- below only when the caller cannot attest themselves.
        ARRAY[]::uuid[]
    )
    ON CONFLICT (id)
        DO UPDATE SET
            title = CASE WHEN v_is_archived THEN
                COALESCE(p_thread ->> 'title', p_defaults ->> 'title', thread.title)
            ELSE
                CASE WHEN p_thread ? 'title' THEN
                    p_thread ->> 'title'
                ELSE
                    thread.title
                END
            END,
            preview = CASE WHEN v_is_archived THEN
                COALESCE(p_thread ->> 'preview', p_defaults ->> 'preview', thread.preview)
            ELSE
                CASE WHEN p_thread ? 'preview' THEN
                    p_thread ->> 'preview'
                ELSE
                    thread.preview
                END
            END,
            updated_by = CASE WHEN v_is_archived THEN
                COALESCE((p_thread ->> 'updated_by')::integer, (p_defaults ->> 'updated_by')::integer, thread.updated_by)
            ELSE
                CASE WHEN p_thread ? 'updated_by' THEN
                    (p_thread ->> 'updated_by')::integer
                ELSE
                    thread.updated_by
                END
            END,
            sync_depth = CASE WHEN v_is_archived THEN
                COALESCE((p_thread ->> 'sync_depth')::smallint, (p_defaults ->> 'sync_depth')::smallint, thread.sync_depth)
            ELSE
                CASE WHEN p_thread ? 'sync_depth' THEN
                    (p_thread ->> 'sync_depth')::smallint
                ELSE
                    thread.sync_depth
                END
            END,
            -- Additive contact merge. The union already includes existing +
            -- input + caller's own linked contacts.
            contacts = v_merged_contacts,
            groups = CASE WHEN v_is_archived THEN
                v_input_groups
            ELSE
                CASE WHEN p_thread ? 'groups' THEN
                    v_input_groups
                ELSE
                    thread.groups
                END
            END,
            topic = CASE WHEN v_is_archived THEN
                v_resolved_topic
            ELSE
                CASE WHEN p_thread ? 'topic' THEN
                    v_input_topic
                ELSE
                    thread.topic
                END
            END,
            draft = CASE WHEN v_is_archived THEN
                COALESCE((p_thread ->> 'draft')::boolean, (p_defaults ->> 'draft')::boolean, thread.draft)
            ELSE
                CASE WHEN p_thread ? 'draft' THEN
                    (p_thread ->> 'draft')::boolean
                ELSE
                    thread.draft
                END
            END,
            icon = CASE WHEN v_is_archived THEN
                COALESCE(p_thread ->> 'icon', p_defaults ->> 'icon', thread.icon)
            ELSE
                CASE WHEN p_thread ? 'icon' THEN
                    p_thread ->> 'icon'
                ELSE
                    thread.icon
                END
            END,
            archived_at = CASE WHEN v_is_archived THEN
                CASE WHEN p_thread ? 'archived_at' THEN
                    (p_thread ->> 'archived_at')::timestamptz
                WHEN p_defaults ? 'archived_at' THEN
                    (p_defaults ->> 'archived_at')::timestamptz
                ELSE
                    thread.archived_at
                END
            ELSE
                CASE WHEN p_thread ? 'archived_at' THEN
                    (p_thread ->> 'archived_at')::timestamptz
                ELSE
                    thread.archived_at
                END
            END,
            -- Immutable identity: first creator wins. We do NOT overwrite
            -- thread.created_by or thread.twist_id on update.
            -- Remove promoted contacts from pending_contacts.
            pending_contacts = CASE
                WHEN cardinality(v_promoted_contacts) > 0 THEN
                    COALESCE((
                        SELECT array_agg(p)
                        FROM unnest(thread.pending_contacts) AS p
                        WHERE NOT (p = ANY(v_promoted_contacts))
                    ), ARRAY[]::uuid[])
                ELSE
                    thread.pending_contacts
            END
        RETURNING * INTO v_result;

    -- Attestation was already computed before the merge (see above). If the
    -- caller was attested, they file their own thread_priority row. Otherwise
    -- we record their primary contact in pending_contacts and defer filing.
    IF v_caller_attested THEN
        -- Normal path: the caller can file the thread under their priority.
        -- Stamp applied_default_channel_id when the chosen priority matches
        -- the thread's channel default, but only when the caller did not
        -- pass an explicit priority_id (an explicit pick is never a default).
        INSERT INTO thread_priority (thread_id, user_id, priority_id, applied_default_channel_id)
        VALUES (
            v_result.id,
            upsert_thread.user_id,
            v_priority_id,
            CASE
                WHEN p_thread ? 'priority_id' THEN NULL
                ELSE public.channel_default_marker (
                    upsert_thread.user_id, v_result.id, v_priority_id
                )
            END
        )
        ON CONFLICT ON CONSTRAINT thread_priority_pkey
        DO UPDATE SET
            priority_id = CASE
                WHEN p_thread ? 'priority_id' THEN EXCLUDED.priority_id
                WHEN v_is_archived THEN EXCLUDED.priority_id
                ELSE thread_priority.priority_id
            END,
            -- An explicit caller priority_id is not a default placement.
            -- Preserve the existing marker otherwise.
            applied_default_channel_id = CASE
                WHEN p_thread ? 'priority_id' THEN NULL
                ELSE thread_priority.applied_default_channel_id
            END,
            -- Un-archive on a legitimate re-file.
            archived_at = NULL,
            updated_at = now();
    ELSE
        -- Attestation not yet established. Record the caller's primary
        -- contact in pending_contacts so a subsequent attester can promote
        -- them. Do not create a thread_priority row — the caller will not
        -- see this thread yet.
        IF v_user_primary_contact IS NOT NULL THEN
            UPDATE thread
            SET pending_contacts = (
                SELECT COALESCE(array_agg(DISTINCT x), ARRAY[]::uuid[])
                FROM unnest(COALESCE(pending_contacts, ARRAY[]::uuid[]) || ARRAY[v_user_primary_contact]) AS x
            )
            WHERE id = v_result.id
              AND NOT (v_user_primary_contact = ANY(COALESCE(pending_contacts, ARRAY[]::uuid[])))
              AND NOT (v_user_primary_contact = ANY(COALESCE(contacts, ARRAY[]::uuid[])));
            -- Refresh v_result so the returned row reflects the updated pending_contacts.
            SELECT * INTO v_result FROM thread WHERE id = v_result.id;
        END IF;
    END IF;

    -- Promote pending contacts that the caller has now attested: create
    -- thread_priority rows for each linked user whose contact was just
    -- moved out of pending_contacts. Uses classify_thread_for_user to pick
    -- each peer's priority. Idempotent via ON CONFLICT.
    IF cardinality(v_promoted_contacts) > 0 THEN
        DECLARE
            r RECORD;
            v_peer_priority uuid;
        BEGIN
            FOR r IN
                SELECT DISTINCT uc.user_id AS peer_user_id
                FROM unnest(v_promoted_contacts) AS arr(contact_id)
                JOIN user_contact uc
                  ON uc.contact_id = arr.contact_id
                 AND uc.linked = TRUE
                 AND uc.archived_at IS NULL
                WHERE uc.user_id IS DISTINCT FROM upsert_thread.user_id
            LOOP
                v_peer_priority := public.classify_thread_for_user(r.peer_user_id, v_result.id);
                IF v_peer_priority IS NOT NULL THEN
                    INSERT INTO thread_priority (thread_id, user_id, priority_id, applied_default_channel_id)
                    VALUES (
                        v_result.id,
                        r.peer_user_id,
                        v_peer_priority,
                        public.channel_default_marker (
                            r.peer_user_id, v_result.id, v_peer_priority
                        )
                    )
                    ON CONFLICT ON CONSTRAINT thread_priority_pkey
                    DO UPDATE SET archived_at = NULL, updated_at = now();

                    INSERT INTO thread_unread (user_id, thread_id, urgency, importance)
                    VALUES (r.peer_user_id, v_result.id, 'inform-updates', 50)
                    ON CONFLICT ON CONSTRAINT thread_unread_pkey DO NOTHING;
                END IF;
            END LOOP;
        END;
    END IF;

    -- Ensure the calling user has user_contact rows for all external
    -- contacts on this thread so they appear as actors in the app.
    IF v_result.contacts IS NOT NULL AND cardinality(v_result.contacts) > 0 THEN
        INSERT INTO user_contact (user_id, contact_id, linked, source)
        SELECT upsert_thread.user_id, arr.contact_id, false, 'thread'
        FROM unnest(v_result.contacts) AS arr(contact_id)
        WHERE EXISTS (SELECT 1 FROM contact c WHERE c.id = arr.contact_id)
        ON CONFLICT ON CONSTRAINT user_contact_pkey DO NOTHING;
    END IF;

    RETURN v_result;
END;
$$;
-- Modify "group" view
CREATE OR REPLACE VIEW "user"."group" (
  "user_id",
  "id",
  "created_at",
  "updated_at",
  "archived_at",
  "name",
  "type",
  "join_policy",
  "team_id",
  "auto_maintained",
  "is_admin",
  "is_member",
  "member_contact_ids"
) AS SELECT u.id AS user_id,
    g.id,
    g.created_at,
    g.updated_at,
    g.archived_at,
    g.name,
    g.type,
    g.join_policy,
    g.team_id,
    g.auto_maintained,
    (EXISTS ( SELECT 1
           FROM public.group_admin ga
          WHERE ga.group_id = g.id AND ga.user_id = u.id)) AS is_admin,
    (EXISTS ( SELECT 1
           FROM public.group_member gm
             JOIN public.user_contact uc ON uc.contact_id = gm.contact_id AND uc.linked = true AND uc.archived_at IS NULL
          WHERE gm.group_id = g.id AND uc.user_id = u.id)) AS is_member,
        CASE
            WHEN (EXISTS ( SELECT 1
               FROM public.group_admin ga
              WHERE ga.group_id = g.id AND ga.user_id = u.id)) THEN ( SELECT COALESCE(array_agg(gm2.contact_id), ARRAY[]::uuid[]) AS "coalesce"
               FROM public.group_member gm2
              WHERE gm2.group_id = g.id)
            WHEN (g.type = ANY (ARRAY['private'::public.group_type, 'team'::public.group_type])) AND (EXISTS ( SELECT 1
               FROM public.group_member gm
                 JOIN public.user_contact uc ON uc.contact_id = gm.contact_id AND uc.linked = true AND uc.archived_at IS NULL
              WHERE gm.group_id = g.id AND uc.user_id = u.id)) THEN ( SELECT COALESCE(array_agg(gm2.contact_id), ARRAY[]::uuid[]) AS "coalesce"
               FROM public.group_member gm2
              WHERE gm2.group_id = g.id)
            ELSE ARRAY[]::uuid[]
        END AS member_contact_ids
   FROM public."user" u
     CROSS JOIN public."group" g
  WHERE g.archived_at IS NULL AND ((g.type = ANY (ARRAY['public'::public.group_type, 'announce'::public.group_type])) OR g.key = '@plot.team'::text OR g.type = 'team'::public.group_type AND (EXISTS ( SELECT 1
           FROM public.team_user tu
          WHERE tu.team_id = g.team_id AND tu.user_id = u.id)) OR g.type = 'private'::public.group_type AND ((EXISTS ( SELECT 1
           FROM public.group_admin ga
          WHERE ga.group_id = g.id AND ga.user_id = u.id)) OR (EXISTS ( SELECT 1
           FROM public.group_member gm
             JOIN public.user_contact uc ON uc.contact_id = gm.contact_id AND uc.linked = true AND uc.archived_at IS NULL
          WHERE gm.group_id = g.id AND uc.user_id = u.id))));

-- Backfill: tag the existing auto-maintained Plot Team group so non-members
-- can see/address it via the new user.group visibility branch.
-- No-op in environments where the Plot team doesn't exist (e.g. local dev
-- with the Plot Publisher fallback).
UPDATE "public"."group" g
SET key = '@plot.team'
WHERE g.auto_maintained = TRUE
  AND g.auto_team_admin_team_id IS NULL
  AND g.team_id = (SELECT id FROM team WHERE name = 'Plot' LIMIT 1)
  AND g.key IS DISTINCT FROM '@plot.team';
