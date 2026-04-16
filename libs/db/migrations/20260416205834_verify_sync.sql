-- Modify "activate_invited_user" function
CREATE OR REPLACE FUNCTION "public"."activate_invited_user" ("p_user_id" uuid) RETURNS jsonb LANGUAGE plpgsql SET "search_path" = public AS $$
DECLARE
    v_root_priority_id uuid;
    v_new_path ltree;
BEGIN
    -- Already has a root priority?
    SELECT id INTO v_root_priority_id
    FROM public.priority
    WHERE user_id = p_user_id
      AND nlevel(path) = 1
    ORDER BY created_at ASC
    LIMIT 1;

    IF v_root_priority_id IS NOT NULL THEN
        RETURN jsonb_build_object('activated', FALSE, 'already_active', TRUE, 'root_priority_id', v_root_priority_id);
    END IF;

    -- Create the root priority. default_priority_user_id fills user_id
    -- from created_by, so the new row is fully owned by the user.
    v_new_path := generate_path(NULL);
    INSERT INTO public.priority (created_by, user_id, title, path, color)
        VALUES (p_user_id, p_user_id, 'Everything', v_new_path, 0)
    RETURNING id INTO v_root_priority_id;

    -- Create Using Plot (@plot.app)
    INSERT INTO public.priority (created_by, user_id, title, path, color, key, default_thread_icon)
    VALUES (p_user_id, p_user_id, 'Using Plot', v_new_path || generate_path(NULL), 7, '@plot.app', 'https://plot.day/assets/plot-icon.svg');

    -- Create Twist Development (@plot.twist-dev)
    INSERT INTO public.priority (created_by, user_id, title, path, color, key)
    VALUES (p_user_id, p_user_id, 'Twist Development', v_new_path || generate_path(NULL), 3, '@plot.twist-dev');

    -- Add priority rules for auto-filing
    -- 1. Everyone group -> Using Plot
    INSERT INTO public.priority_rule (user_id, priority_id, type, topic)
    SELECT p_user_id, p.id, 'topic', g.id::text
    FROM public.priority p
    CROSS JOIN public."group" g
    WHERE p.user_id = p_user_id AND p.key = '@plot.app'
      AND g.auto_maintained = TRUE AND g.team_id IS NULL AND g.auto_publisher_id IS NULL AND g.name = 'Everyone';

    -- 2. User account topic (the user's own uuid) -> Using Plot
    INSERT INTO public.priority_rule (user_id, priority_id, type, topic)
    SELECT p_user_id, p.id, 'topic', p_user_id::text
    FROM public.priority p
    WHERE p.user_id = p_user_id AND p.key = '@plot.app';

    -- 3. Team admin groups -> Using Plot
    INSERT INTO public.priority_rule (user_id, priority_id, type, topic)
    SELECT p_user_id, p.id, 'topic', g.id::text
    FROM public.priority p
    CROSS JOIN public."group" g
    JOIN public.team_user tu ON tu.team_id = g.auto_team_admin_team_id AND tu.user_id = p_user_id
    WHERE p.user_id = p_user_id AND p.key = '@plot.app'
      AND g.auto_team_admin_team_id IS NOT NULL;

    -- 4. Personal twists topic (keyed on "personal-twists:<user_id>") -> Twist Development
    INSERT INTO public.priority_rule (user_id, priority_id, type, topic)
    SELECT p_user_id, p.id, 'topic', 'personal-twists:' || p_user_id::text
    FROM public.priority p
    WHERE p.user_id = p_user_id AND p.key = '@plot.twist-dev';

    -- 5. Publisher groups (where this user is a member) -> Twist Development
    INSERT INTO public.priority_rule (user_id, priority_id, type, topic)
    SELECT p_user_id, p.id, 'topic', g.id::text
    FROM public.priority p
    CROSS JOIN public."group" g
    JOIN public.group_member gm ON gm.group_id = g.id
    JOIN public.user_contact uc ON uc.contact_id = gm.contact_id
    WHERE p.user_id = p_user_id AND p.key = '@plot.twist-dev'
      AND g.auto_publisher_id IS NOT NULL
      AND g.auto_maintained = TRUE
      AND uc.user_id = p_user_id
      AND uc.linked = TRUE
      AND uc.archived_at IS NULL;

    RETURN jsonb_build_object('activated', TRUE, 'already_active', FALSE, 'root_priority_id', v_root_priority_id);
END;
$$;
-- Modify "classify_thread_for_user" function
CREATE OR REPLACE FUNCTION "public"."classify_thread_for_user" ("p_user_id" uuid, "p_thread_id" uuid DEFAULT NULL::uuid, "p_embedding" public.halfvec DEFAULT NULL::public.halfvec, "p_topic" text DEFAULT NULL::text) RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE
    v_embedding halfvec;
    v_topic text;
    v_matched_priority_id uuid;
    v_root_priority_id uuid;
BEGIN
    -- 1. Load thread data from DB when thread exists, then apply overrides.
    IF p_thread_id IS NOT NULL THEN
        SELECT t.embedding, t.topic
        INTO v_embedding, v_topic
        FROM public.thread t
        WHERE t.id = p_thread_id;
    END IF;

    v_embedding := COALESCE(p_embedding, v_embedding);
    v_topic     := COALESCE(p_topic, v_topic);

    -- 2a. Content rules (highest precedence).
    IF v_embedding IS NOT NULL THEN
        SELECT pr.priority_id INTO v_matched_priority_id
        FROM public.priority_rule pr
        WHERE pr.user_id = p_user_id
          AND pr.type = 'content'
          AND pr.embedding IS NOT NULL
          AND (1 - (pr.embedding <=> v_embedding)) >= 0.7
        ORDER BY (1 - (pr.embedding <=> v_embedding)) DESC
        LIMIT 1;

        IF v_matched_priority_id IS NOT NULL THEN
            RETURN v_matched_priority_id;
        END IF;
    END IF;

    -- 2b. Topic rules.
    IF v_topic IS NOT NULL THEN
        SELECT pr.priority_id INTO v_matched_priority_id
        FROM public.priority_rule pr
        WHERE pr.user_id = p_user_id
          AND pr.type = 'topic'
          AND pr.topic = v_topic
        ORDER BY pr.created_at ASC
        LIMIT 1;

        IF v_matched_priority_id IS NOT NULL THEN
            RETURN v_matched_priority_id;
        END IF;
    END IF;

    -- 3. Fall back to the user's root priority.
    SELECT p.id INTO v_root_priority_id
    FROM public.priority p
    WHERE p.user_id = p_user_id
      AND nlevel(p.path) = 1
      AND p.archived_at IS NULL
    ORDER BY p.created_at ASC
    LIMIT 1;

    RETURN v_root_priority_id;
END;
$$;
-- Modify "apply_priority_rule" function
CREATE OR REPLACE FUNCTION "public"."apply_priority_rule" ("p_rule_id" uuid, "p_max_moves" integer DEFAULT 100) RETURNS TABLE ("thread_id" uuid, "old_priority_id" uuid) LANGUAGE plpgsql AS $$
DECLARE
    v_rule RECORD;
BEGIN
    -- Load the rule.
    SELECT * INTO v_rule
    FROM public.priority_rule
    WHERE id = p_rule_id;

    IF NOT FOUND THEN
        RETURN;
    END IF;

    RETURN QUERY
    WITH matched AS (
        SELECT tp.thread_id, tp.priority_id AS current_priority_id
        FROM public.thread_priority tp
        JOIN public.thread t ON t.id = tp.thread_id
        WHERE tp.user_id = v_rule.user_id
          AND tp.priority_id IS DISTINCT FROM v_rule.priority_id
          AND t.archived_at IS NULL
          AND t.draft = FALSE
          AND CASE v_rule.type
              WHEN 'content' THEN
                  t.embedding IS NOT NULL
                  AND v_rule.embedding IS NOT NULL
                  AND (1 - (t.embedding <=> v_rule.embedding)) >= 0.7
              WHEN 'topic' THEN
                  v_rule.topic IS NOT NULL
                  AND t.topic = v_rule.topic
          END
        LIMIT p_max_moves
    ),
    -- Only move if no higher-precedence rule already classifies this thread
    -- into a different priority.
    filtered AS (
        SELECT m.thread_id, m.current_priority_id
        FROM matched m
        WHERE public.classify_thread_for_user(
            v_rule.user_id,
            m.thread_id
        ) IS NOT DISTINCT FROM v_rule.priority_id
    ),
    moved AS (
        UPDATE public.thread_priority tp
        SET priority_id = v_rule.priority_id
        FROM filtered f
        WHERE tp.thread_id = f.thread_id
          AND tp.user_id = v_rule.user_id
        RETURNING tp.thread_id, f.current_priority_id AS old_priority_id
    )
    SELECT moved.thread_id, moved.old_priority_id FROM moved;
END;
$$;
-- Modify "file_thread_priority_on_group_member_change" function
CREATE OR REPLACE FUNCTION "public"."file_thread_priority_on_group_member_change" () RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    r_thread RECORD;
    v_peer_user_id uuid;
    v_peer_priority_id uuid;
BEGIN
    IF TG_OP = 'INSERT' THEN
        SELECT uc.user_id INTO v_peer_user_id
        FROM public.user_contact uc
        WHERE uc.contact_id = NEW.contact_id
          AND uc.linked = TRUE
          AND uc.archived_at IS NULL
        LIMIT 1;

        IF v_peer_user_id IS NULL THEN
            RETURN NEW;
        END IF;

        FOR r_thread IN
            SELECT t.id AS thread_id
            FROM public.thread t
            WHERE NEW.group_id = ANY(t.groups)
              AND t.archived_at IS NULL
        LOOP
            v_peer_priority_id := public.classify_thread_for_user(v_peer_user_id, r_thread.thread_id);
            IF v_peer_priority_id IS NULL THEN
                CONTINUE;
            END IF;

            INSERT INTO thread_priority (thread_id, user_id, priority_id)
            VALUES (r_thread.thread_id, v_peer_user_id, v_peer_priority_id)
            ON CONFLICT ON CONSTRAINT thread_priority_pkey DO NOTHING;

            INSERT INTO thread_unread (user_id, thread_id, urgency, importance)
            VALUES (v_peer_user_id, r_thread.thread_id, 'inform-updates', 50)
            ON CONFLICT (user_id, thread_id) DO NOTHING;
        END LOOP;

        RETURN NEW;

    ELSIF TG_OP = 'DELETE' THEN
        SELECT uc.user_id INTO v_peer_user_id
        FROM public.user_contact uc
        WHERE uc.contact_id = OLD.contact_id
          AND uc.linked = TRUE
          AND uc.archived_at IS NULL
        LIMIT 1;

        IF v_peer_user_id IS NULL THEN
            RETURN OLD;
        END IF;

        FOR r_thread IN
            SELECT t.id AS thread_id
            FROM public.thread t
            WHERE OLD.group_id = ANY(t.groups)
              AND t.archived_at IS NULL
        LOOP
            IF NOT EXISTS (
                SELECT 1 FROM public.thread t2
                WHERE t2.id = r_thread.thread_id
                  AND (
                    t2.contacts && "user".user_contact_ids(v_peer_user_id)
                    OR EXISTS (
                        SELECT 1 FROM unnest(t2.groups) AS gid
                        JOIN group_member gm2 ON gm2.group_id = gid
                        JOIN user_contact uc2 ON uc2.contact_id = gm2.contact_id
                            AND uc2.linked = TRUE AND uc2.archived_at IS NULL
                        WHERE uc2.user_id = v_peer_user_id
                          AND gm2.group_id != OLD.group_id
                    )
                  )
            ) THEN
                DELETE FROM thread_priority
                WHERE thread_id = r_thread.thread_id
                  AND user_id = v_peer_user_id;

                DELETE FROM thread_unread
                WHERE thread_id = r_thread.thread_id
                  AND user_id = v_peer_user_id;
            END IF;
        END LOOP;

        RETURN OLD;
    END IF;
END;
$$;
-- Modify "sync_user_for_group" function
CREATE OR REPLACE FUNCTION "public"."sync_user_for_group" () RETURNS trigger LANGUAGE plpgsql SET "search_path" = public AS $$
DECLARE
    v_max_updated_at timestamptz;
    v_user_id uuid;
BEGIN
    SELECT
        MAX(updated_at) INTO v_max_updated_at
    FROM
        new_table;
    FOR v_user_id IN SELECT DISTINCT
        ug.user_id
    FROM
        new_table n
        JOIN "user"."group" ug ON ug.id = n.id
    ORDER BY
        ug.user_id LOOP
            INSERT INTO user_sync (user_id, entity, last_update_at)
                VALUES (v_user_id, 'group', v_max_updated_at)
            ON CONFLICT (user_id, entity)
                DO UPDATE SET
                    last_update_at = GREATEST (user_sync.last_update_at, EXCLUDED.last_update_at);
        END LOOP;
    RETURN NULL;
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

    IF v_priority_id IS NULL THEN
        RAISE EXCEPTION 'priority_id must be provided';
    END IF;

    -- Validate the caller has access to the target priority.
    IF NOT user_has_priority_access(upsert_thread.user_id, v_priority_id) THEN
        RAISE EXCEPTION 'User does not have access to this priority';
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

    -- On INSERT, derive a default topic when none was provided.
    IF v_existing.id IS NULL AND v_input_topic IS NULL THEN
        -- Channel from the caller's twist_instance (if any): first enabled
        -- channel row for this twist_instance is ambiguous, so we key on
        -- any link attached to this thread whose (twist_instance_id, channel_id)
        -- matches a channel row. On INSERT there are no links yet, so this
        -- path only fires on reconciliation / later updates. Ignore for now
        -- and fall back to groups[1].
        IF cardinality(v_input_groups) > 0 THEN
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
        -- Trusted caller: union existing, input, and caller's own contacts.
        SELECT COALESCE(array_agg(DISTINCT x), ARRAY[]::uuid[])
        INTO v_merged_contacts
        FROM unnest(
            COALESCE(v_existing.contacts, ARRAY[]::uuid[])
            || v_input_contacts
            || v_user_contacts
        ) AS x;
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
        INSERT INTO thread_priority (thread_id, user_id, priority_id)
        VALUES (v_result.id, upsert_thread.user_id, v_priority_id)
        ON CONFLICT ON CONSTRAINT thread_priority_pkey
        DO UPDATE SET
            priority_id = CASE
                WHEN p_thread ? 'priority_id' THEN EXCLUDED.priority_id
                WHEN v_is_archived THEN EXCLUDED.priority_id
                ELSE thread_priority.priority_id
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
                    INSERT INTO thread_priority (thread_id, user_id, priority_id)
                    VALUES (v_result.id, r.peer_user_id, v_peer_priority)
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
-- Modify "group" table
ALTER TABLE "public"."group" DROP CONSTRAINT "topic_auto_publisher_id_fkey", DROP CONSTRAINT "topic_auto_team_admin_team_id_fkey", DROP CONSTRAINT "topic_created_by_fkey", DROP CONSTRAINT "topic_team_id_fkey", ADD CONSTRAINT "group_auto_publisher_id_fkey" FOREIGN KEY ("auto_publisher_id") REFERENCES "public"."publisher" ("id") ON UPDATE NO ACTION ON DELETE CASCADE, ADD CONSTRAINT "group_auto_team_admin_team_id_fkey" FOREIGN KEY ("auto_team_admin_team_id") REFERENCES "public"."team" ("id") ON UPDATE NO ACTION ON DELETE CASCADE, ADD CONSTRAINT "group_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "public"."user" ("id") ON UPDATE NO ACTION ON DELETE CASCADE, ADD CONSTRAINT "group_team_id_fkey" FOREIGN KEY ("team_id") REFERENCES "public"."team" ("id") ON UPDATE NO ACTION ON DELETE SET NULL;
-- Modify "group_admin" table
ALTER TABLE "public"."group_admin" DROP CONSTRAINT "topic_admin_topic_id_fkey", DROP CONSTRAINT "topic_admin_user_id_fkey", ADD CONSTRAINT "group_admin_group_id_fkey" FOREIGN KEY ("group_id") REFERENCES "public"."group" ("id") ON UPDATE NO ACTION ON DELETE CASCADE, ADD CONSTRAINT "group_admin_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."user" ("id") ON UPDATE NO ACTION ON DELETE CASCADE;
-- Modify "group_member" table
ALTER TABLE "public"."group_member" DROP CONSTRAINT "topic_member_contact_id_fkey", DROP CONSTRAINT "topic_member_topic_id_fkey", ADD CONSTRAINT "group_member_contact_id_fkey" FOREIGN KEY ("contact_id") REFERENCES "public"."contact" ("id") ON UPDATE NO ACTION ON DELETE CASCADE, ADD CONSTRAINT "group_member_group_id_fkey" FOREIGN KEY ("group_id") REFERENCES "public"."group" ("id") ON UPDATE NO ACTION ON DELETE CASCADE;
-- Drop "thread_x" view
DROP VIEW "public"."thread_x";
-- Create "thread_x" view
CREATE VIEW "public"."thread_x" (
  "id",
  "created_at",
  "updated_at",
  "created_by",
  "updated_by",
  "archived_at",
  "draft",
  "contacts",
  "title",
  "preview",
  "last_note_created_at",
  "sync_depth",
  "last_note_source_created_at",
  "key",
  "icon",
  "groups",
  "topic",
  "embedding",
  "twist_id",
  "pending_contacts"
) AS SELECT id,
    created_at,
    updated_at,
    created_by,
    updated_by,
    archived_at,
    draft,
    contacts,
    title,
    preview,
    last_note_created_at,
    sync_depth,
    last_note_source_created_at,
    key,
    icon,
    groups,
    topic,
    embedding,
    twist_id,
    pending_contacts
   FROM public.thread a;
