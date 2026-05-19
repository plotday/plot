-- Modify "thread_priority" table
ALTER TABLE "public"."thread_priority" ADD CONSTRAINT "thread_priority_state_valid" CHECK ((priority_id IS NOT NULL) OR (classify_at IS NOT NULL)), ALTER COLUMN "priority_id" DROP NOT NULL, ADD COLUMN "classify_at" timestamptz NULL;
-- Create index "thread_priority_classify_pending_idx" to table: "thread_priority"
CREATE INDEX "thread_priority_classify_pending_idx" ON "public"."thread_priority" ("classify_at") WHERE (classify_at IS NOT NULL);
-- Set comment to column: "priority_id" on table: "thread_priority"
COMMENT ON COLUMN "public"."thread_priority"."priority_id" IS 'User''s priority filing. NULL means classification is pending (see classify_at). Views must use COALESCE(priority_id, root_priority_id(user_id)) gated by the visibility filter (priority_id IS NOT NULL OR classify_at < now() - classify_visibility_window()).';
-- Set comment to column: "classify_at" on table: "thread_priority"
COMMENT ON COLUMN "public"."thread_priority"."classify_at" IS 'Timestamp when classification was last requested. NULL once classification has succeeded. NOT NULL signals the consumer Worker (workers/classify) to (re-)classify this row.';
-- Create "bump_thread_seq_on_priority_change" function
CREATE FUNCTION "public"."bump_thread_seq_on_priority_change" () RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    UPDATE public.thread
    SET updated_at = now()
    WHERE id = NEW.thread_id;
    RETURN NEW;
END;
$$;
-- Create trigger "thread_priority_bump_parent"
CREATE TRIGGER "thread_priority_bump_parent" AFTER UPDATE OF "priority_id" ON "public"."thread_priority" FOR EACH ROW WHEN (new.priority_id IS DISTINCT FROM old.priority_id) EXECUTE FUNCTION "public"."bump_thread_seq_on_priority_change"();
-- Modify "file_thread_priority_for_group_members" function
CREATE OR REPLACE FUNCTION "public"."file_thread_priority_for_group_members" () RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    v_author_user_id uuid;
BEGIN
    IF NEW.groups IS NULL OR cardinality(NEW.groups) = 0 THEN
        RETURN NEW;
    END IF;

    IF EXISTS (SELECT 1 FROM "public"."user" WHERE id = NEW.created_by) THEN
        v_author_user_id := NEW.created_by;
    ELSE
        v_author_user_id := NULL;
    END IF;

    INSERT INTO thread_priority (thread_id, user_id, priority_id, classify_at)
    SELECT NEW.id, peer.user_id, NULL::uuid, now()
    FROM (
        SELECT DISTINCT uc.user_id
        FROM unnest(NEW.groups) AS arr(group_id)
        JOIN public.group_member gm ON gm.group_id = arr.group_id
        JOIN public.user_contact uc
          ON uc.contact_id = gm.contact_id
         AND uc.linked = TRUE
         AND uc.archived_at IS NULL
        WHERE uc.user_id IS DISTINCT FROM v_author_user_id
    ) peer
    ON CONFLICT ON CONSTRAINT thread_priority_pkey DO NOTHING;

    INSERT INTO thread_unread (user_id, thread_id, urgency, importance)
    SELECT peer.user_id, NEW.id, 'inform-updates', 50
    FROM (
        SELECT DISTINCT uc.user_id
        FROM unnest(NEW.groups) AS arr(group_id)
        JOIN public.group_member gm ON gm.group_id = arr.group_id
        JOIN public.user_contact uc
          ON uc.contact_id = gm.contact_id
         AND uc.linked = TRUE
         AND uc.archived_at IS NULL
        WHERE uc.user_id IS DISTINCT FROM v_author_user_id
    ) peer
    ON CONFLICT (user_id, thread_id) DO NOTHING;

    RETURN NEW;
END;
$$;
-- Modify "file_thread_priority_on_group_member_change" function
CREATE OR REPLACE FUNCTION "public"."file_thread_priority_on_group_member_change" () RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    r_thread RECORD;
    v_peer_user_id uuid;
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

        -- Mark every thread referencing the group pending for this peer.
        INSERT INTO thread_priority (thread_id, user_id, priority_id, classify_at)
        SELECT t.id, v_peer_user_id, NULL::uuid, now()
        FROM public.thread t
        WHERE NEW.group_id = ANY(t.groups)
          AND t.archived_at IS NULL
        ON CONFLICT ON CONSTRAINT thread_priority_pkey DO NOTHING;

        INSERT INTO thread_unread (user_id, thread_id, urgency, importance)
        SELECT t.id, v_peer_user_id, 'inform-updates', 50
        FROM public.thread t
        WHERE NEW.group_id = ANY(t.groups)
          AND t.archived_at IS NULL
        ON CONFLICT (user_id, thread_id) DO NOTHING;

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
-- Modify "file_thread_priority_peers" function
CREATE OR REPLACE FUNCTION "public"."file_thread_priority_peers" () RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    v_author_user_id uuid;
    v_old_contacts uuid[];
BEGIN
    IF NEW.contacts IS NULL OR cardinality(NEW.contacts) = 0 THEN
        RETURN NEW;
    END IF;

    -- Only auto-file peers for user-authored threads.
    IF NOT EXISTS (SELECT 1 FROM "public"."user" WHERE id = NEW.created_by) THEN
        RETURN NEW;
    END IF;
    v_author_user_id := NEW.created_by;

    IF TG_OP = 'UPDATE' THEN
        v_old_contacts := COALESCE(OLD.contacts, ARRAY[]::uuid[]);
    ELSE
        v_old_contacts := ARRAY[]::uuid[];
    END IF;

    -- Mark every peer pending classification. applied_default_channel_id
    -- is set by the consumer Worker once it knows the chosen priority.
    INSERT INTO thread_priority (thread_id, user_id, priority_id, classify_at)
    SELECT NEW.id, peer.user_id, NULL::uuid, now()
    FROM (
        SELECT DISTINCT uc.user_id
        FROM unnest(NEW.contacts) AS arr(contact_id)
        JOIN public.user_contact uc
          ON uc.contact_id = arr.contact_id
         AND uc.linked = TRUE
         AND uc.archived_at IS NULL
        WHERE uc.user_id IS DISTINCT FROM v_author_user_id
    ) peer
    ON CONFLICT ON CONSTRAINT thread_priority_pkey DO NOTHING;

    -- thread_unread for newly-added contacts only. Harmless while the
    -- parent thread_priority row is hidden — only surfaces in user.*
    -- views once the visibility filter admits the row.
    INSERT INTO thread_unread (user_id, thread_id, urgency, importance)
    SELECT peer.user_id, NEW.id, 'inform-updates', 50
    FROM (
        SELECT DISTINCT uc.user_id
        FROM unnest(NEW.contacts) AS arr(contact_id)
        JOIN public.user_contact uc
          ON uc.contact_id = arr.contact_id
         AND uc.linked = TRUE
         AND uc.archived_at IS NULL
        WHERE uc.user_id IS DISTINCT FROM v_author_user_id
          AND arr.contact_id != ALL(v_old_contacts)
    ) peer
    ON CONFLICT (user_id, thread_id) DO NOTHING;

    RETURN NEW;
END;
$$;
-- Modify "set_thread_topic_from_link_channel" function
CREATE OR REPLACE FUNCTION "public"."set_thread_topic_from_link_channel" () RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    v_channel_pk bigint;
BEGIN
    IF NEW.channel_id IS NULL OR NEW.thread_id IS NULL OR NEW.created_by IS NULL THEN
        RETURN NEW;
    END IF;

    SELECT ch.id INTO v_channel_pk
    FROM public.channel ch
    WHERE ch.twist_instance_id = NEW.created_by
      AND ch.channel_id = NEW.channel_id
    LIMIT 1;

    IF v_channel_pk IS NULL THEN
        RETURN NEW;
    END IF;

    UPDATE public.thread
    SET topic = 'channel:' || v_channel_pk
    WHERE id = NEW.thread_id
      AND topic IS NULL;

    -- Mark every non-sticky settled row pending. Pending rows (priority_id
    -- IS NULL) are already pending; sticky rows (user_moved = TRUE) are
    -- never reclassified.
    UPDATE public.thread_priority
    SET classify_at = now()
    WHERE thread_id = NEW.thread_id
      AND priority_id IS NOT NULL
      AND user_moved = FALSE;

    RETURN NEW;
END;
$$;
-- Create "classify_visibility_window" function
CREATE FUNCTION "public"."classify_visibility_window" () RETURNS interval LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$ SELECT interval '5 minutes' $$;
-- Create "mark_channel_default_candidates" function
CREATE FUNCTION "public"."mark_channel_default_candidates" ("p_channel_id" bigint) RETURNS TABLE ("user_id" uuid, "thread_id" uuid) LANGUAGE plpgsql AS $$
DECLARE
    v_owner_id uuid;
    v_root_id uuid;
BEGIN
    SELECT ti.owner_id
    INTO v_owner_id
    FROM public.channel c
    JOIN public.twist_instance ti ON ti.id = c.twist_instance_id
    WHERE c.id = p_channel_id;

    IF v_owner_id IS NULL THEN
        RETURN;
    END IF;

    SELECT p.id INTO v_root_id
    FROM public.priority p
    WHERE p.user_id = v_owner_id
      AND nlevel(p.path) = 1
      AND p.archived_at IS NULL
    ORDER BY p.created_at ASC
    LIMIT 1;

    RETURN QUERY
    WITH candidates AS MATERIALIZED (
        -- Previously placed by this channel's default.
        SELECT tp.thread_id, tp.user_id
        FROM public.thread_priority tp
        WHERE tp.applied_default_channel_id = p_channel_id
          AND tp.user_id = v_owner_id
          AND tp.user_moved = FALSE
          AND tp.priority_id IS NOT NULL

        UNION

        -- Sitting at root with no marker, but this channel now claims them.
        SELECT tp.thread_id, tp.user_id
        FROM public.thread_priority tp
        JOIN public.thread t ON t.id = tp.thread_id
        WHERE tp.user_id = v_owner_id
          AND tp.user_moved = FALSE
          AND tp.priority_id = v_root_id
          AND t.topic = 'channel:' || p_channel_id::text
          AND t.archived_at IS NULL
    )
    UPDATE public.thread_priority tp
    SET classify_at = now(),
        updated_at = now()
    FROM candidates c
    WHERE tp.thread_id = c.thread_id
      AND tp.user_id = c.user_id
      AND tp.user_moved = FALSE
      AND tp.priority_id IS NOT NULL
    RETURNING tp.user_id, tp.thread_id;
END;
$$;
-- Set comment to function: "mark_channel_default_candidates"
COMMENT ON FUNCTION "public"."mark_channel_default_candidates" IS 'After a channel''s default_priority_id changes, mark candidate thread_priority rows pending re-classification. Returns (user_id, thread_id) of the marked rows so the API can enqueue ClassifyJobs. Replaces apply_channel_default in the hybrid-classifier wiring.';
-- Create "mark_reclassify_candidates" function
CREATE FUNCTION "public"."mark_reclassify_candidates" ("p_user_id" uuid, "p_anchor_thread_id" uuid, "p_max_candidates" integer DEFAULT 500) RETURNS TABLE ("user_id" uuid, "thread_id" uuid) LANGUAGE plpgsql AS $$
DECLARE
    v_topic text;
    v_embedding halfvec;
    v_contacts uuid[];
    v_groups uuid[];
BEGIN
    PERFORM pg_advisory_xact_lock(
        hashtextextended('mark_reclassify_candidates:' || p_user_id::text, 0)
    );

    SELECT t.topic, t.embedding, t.contacts, t.groups
    INTO v_topic, v_embedding, v_contacts, v_groups
    FROM public.thread t
    WHERE t.id = p_anchor_thread_id;

    IF NOT FOUND THEN
        RETURN;
    END IF;

    -- No-op when the user has no training examples yet — same rationale
    -- as the old function (classifier would yank rows into root).
    IF NOT EXISTS (
        SELECT 1 FROM public.thread_priority tp
        WHERE tp.user_id = p_user_id AND tp.user_moved = TRUE
    ) THEN
        RETURN;
    END IF;

    RETURN QUERY
    WITH candidates AS MATERIALIZED (
        SELECT t.id
        FROM public.thread t
        JOIN public.thread_priority tp
          ON tp.thread_id = t.id
         AND tp.user_id = p_user_id
         AND tp.user_moved = FALSE
         AND tp.priority_id IS NOT NULL
        WHERE v_topic IS NOT NULL
          AND t.topic = v_topic
          AND t.archived_at IS NULL
          AND t.draft = FALSE

        UNION

        SELECT id FROM (
            SELECT t.id, (t.embedding <=> v_embedding) AS dist
            FROM public.thread t
            JOIN public.thread_priority tp
              ON tp.thread_id = t.id
             AND tp.user_id = p_user_id
             AND tp.user_moved = FALSE
             AND tp.priority_id IS NOT NULL
            WHERE v_embedding IS NOT NULL
              AND t.embedding IS NOT NULL
              AND (1 - (t.embedding <=> v_embedding)) >= 0.5
              AND t.archived_at IS NULL
              AND t.draft = FALSE
            ORDER BY t.embedding <=> v_embedding ASC
            LIMIT p_max_candidates
        ) semantic

        UNION

        SELECT t.id
        FROM public.thread t
        JOIN public.thread_priority tp
          ON tp.thread_id = t.id
         AND tp.user_id = p_user_id
         AND tp.user_moved = FALSE
         AND tp.priority_id IS NOT NULL
        WHERE t.archived_at IS NULL
          AND t.draft = FALSE
          AND (
              (cardinality(v_contacts) > 0 AND t.contacts && v_contacts)
              OR (cardinality(v_groups) > 0 AND t.groups && v_groups)
          )
    )
    UPDATE public.thread_priority tp
    SET classify_at = now(),
        updated_at = now()
    FROM candidates c
    WHERE tp.thread_id = c.id
      AND tp.user_id = p_user_id
      AND tp.user_moved = FALSE
      AND tp.priority_id IS NOT NULL
      AND c.id IS DISTINCT FROM p_anchor_thread_id
    RETURNING tp.user_id, tp.thread_id;
END;
$$;
-- Set comment to function: "mark_reclassify_candidates"
COMMENT ON FUNCTION "public"."mark_reclassify_candidates" IS 'After an explicit user move, mark candidate thread_priority rows pending re-classification. Returns (user_id, thread_id) of the marked rows so the API can enqueue ClassifyJobs. Replaces reclassify_user_threads in the hybrid-classifier wiring.';
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
    v_chain_next uuid;
    v_chain_hops int;
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
            -- Lookup matches archived rows too (drop archived_at filter):
            -- a thread that was merged into another thread keeps its
            -- (twist_id, key) on its archived row. Active row preferred
            -- via NULLS FIRST.
            SELECT t.id, t.merged_into_thread_id
            INTO v_id, v_chain_next
            FROM thread t
            WHERE t.twist_id = v_twist_id
              AND t.key = (p_thread ->> 'key')
            ORDER BY t.archived_at ASC NULLS FIRST
            LIMIT 1;

            -- Follow merged_into_thread_id chain so connector resyncs of
            -- a merge source's external item land on the merged target.
            -- Cap at 10 hops to defend against pathological state.
            v_chain_hops := 0;
            WHILE v_chain_next IS NOT NULL AND v_chain_hops < 10 LOOP
                v_id := v_chain_next;
                SELECT merged_into_thread_id INTO v_chain_next
                FROM thread WHERE id = v_id;
                v_chain_hops := v_chain_hops + 1;
            END LOOP;
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
    -- pending thread_priority rows for each linked user whose contact was
    -- just moved out of pending_contacts. The consumer Worker picks each
    -- peer's priority once the API enqueues the ClassifyJobs after the
    -- transaction commits. applied_default_channel_id is left NULL here —
    -- the consumer recomputes via channel_default_marker when it writes
    -- the final priority.
    IF cardinality(v_promoted_contacts) > 0 THEN
        INSERT INTO thread_priority (thread_id, user_id, priority_id, classify_at)
        SELECT v_result.id, peer.user_id, NULL::uuid, now()
        FROM (
            SELECT DISTINCT uc.user_id
            FROM unnest(v_promoted_contacts) AS arr(contact_id)
            JOIN user_contact uc
              ON uc.contact_id = arr.contact_id
             AND uc.linked = TRUE
             AND uc.archived_at IS NULL
            WHERE uc.user_id IS DISTINCT FROM upsert_thread.user_id
        ) peer
        ON CONFLICT ON CONSTRAINT thread_priority_pkey
        DO UPDATE SET archived_at = NULL,
                      -- Mark for re-classification on re-attestation.
                      classify_at = COALESCE(thread_priority.classify_at, now()),
                      updated_at = now();

        INSERT INTO thread_unread (user_id, thread_id, urgency, importance)
        SELECT peer.user_id, v_result.id, 'inform-updates', 50
        FROM (
            SELECT DISTINCT uc.user_id
            FROM unnest(v_promoted_contacts) AS arr(contact_id)
            JOIN user_contact uc
              ON uc.contact_id = arr.contact_id
             AND uc.linked = TRUE
             AND uc.archived_at IS NULL
            WHERE uc.user_id IS DISTINCT FROM upsert_thread.user_id
        ) peer
        ON CONFLICT ON CONSTRAINT thread_unread_pkey DO NOTHING;
    END IF;

    -- Re-mark peer thread_priority rows pending on INITIAL creation. The
    -- file_thread_priority_peers / file_thread_priority_for_group_members
    -- triggers wrote pending markers; this block additionally re-marks any
    -- peer rows whose cross-user keyed-priority signal only becomes
    -- available now that the author's row has been inserted. Skipped on
    -- UPDATE because the triggers handle UPDATE OF contacts / groups
    -- correctly and we don't want to disrupt peers who organized on their
    -- own side.
    IF v_existing.id IS NULL THEN
        UPDATE public.thread_priority tp
        SET classify_at = COALESCE(tp.classify_at, now()),
            updated_at = now()
        WHERE tp.thread_id = v_result.id
          AND tp.user_id IS DISTINCT FROM upsert_thread.user_id
          AND tp.user_moved IS NOT TRUE
          AND tp.archived_at IS NULL;
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
-- Create "root_priority_id" function
CREATE FUNCTION "user"."root_priority_id" ("p_user_id" uuid) RETURNS uuid LANGUAGE sql STABLE AS $$
SELECT p.id
    FROM priority p
    WHERE p.user_id = p_user_id
      AND nlevel(p.path) = 1
      AND p.archived_at IS NULL
    ORDER BY p.created_at ASC
    LIMIT 1;
$$;
-- Modify "channel" view
CREATE OR REPLACE VIEW "user"."channel" (
  "user_id",
  "id",
  "twist_instance_id",
  "channel_id",
  "title",
  "enabled",
  "link_types",
  "default_priority_id",
  "default_priority_reason",
  "created_at",
  "updated_at",
  "seq"
) AS SELECT pt.owner_id AS user_id,
    sc.id,
    sc.twist_instance_id,
    sc.channel_id,
    sc.title,
    sc.enabled,
    sc.link_types,
    sc.default_priority_id,
    sc.default_priority_reason,
    sc.created_at,
    sc.updated_at,
    sc.seq
   FROM public.channel sc
     JOIN public.twist_instance pt ON pt.id = sc.twist_instance_id
UNION
 SELECT DISTINCT tp.user_id,
    sc.id,
    sc.twist_instance_id,
    sc.channel_id,
    sc.title,
    sc.enabled,
    sc.link_types,
    sc.default_priority_id,
    sc.default_priority_reason,
    sc.created_at,
    sc.updated_at,
    sc.seq
   FROM public.channel sc
     JOIN public.link l ON l.channel_id = sc.channel_id AND l.created_by = sc.twist_instance_id
     JOIN public.thread_priority tp ON tp.thread_id = l.thread_id AND (tp.priority_id IS NOT NULL OR tp.classify_at < (now() - public.classify_visibility_window()))
     JOIN public.twist_instance pt ON pt.id = sc.twist_instance_id
  WHERE tp.user_id <> pt.owner_id;
-- Modify "note" view
CREATE OR REPLACE VIEW "user"."note" (
  "user_id",
  "id",
  "created_at",
  "updated_at",
  "seq",
  "source_created_at",
  "author_id",
  "created_by",
  "updated_by",
  "archived_at",
  "thread_id",
  "draft",
  "access_contacts",
  "content",
  "actions",
  "mentions",
  "re_note_id",
  "merged_from_thread_id"
) AS SELECT tp.user_id,
    n.id,
    n.created_at,
    n.updated_at,
    n.seq,
    n.source_created_at,
    n.author_id,
    n.created_by,
    n.updated_by,
    n.archived_at,
    n.thread_id,
    n.draft,
    n.access_contacts,
    n.content,
    n.actions,
    n.mentions,
    n.re_note_id,
    n.merged_from_thread_id
   FROM public.note n
     JOIN public.thread a ON a.id = n.thread_id
     JOIN public.thread_priority tp ON tp.thread_id = a.id AND (tp.priority_id IS NOT NULL OR tp.classify_at < (now() - public.classify_visibility_window()))
  WHERE (n.draft = false OR n.created_by = tp.user_id) AND (n.access_contacts IS NULL OR n.created_by = tp.user_id OR n.access_contacts && "user".user_contact_ids(tp.user_id)) AND (a.draft = false OR a.created_by = tp.user_id) AND (a.contacts && "user".user_contact_ids(tp.user_id) OR a.groups && "user".user_group_ids(tp.user_id));
-- Modify "note_redacted" view
CREATE OR REPLACE VIEW "user"."note_redacted" (
  "user_id",
  "id",
  "created_at",
  "updated_at",
  "seq",
  "source_created_at",
  "author_id",
  "created_by",
  "updated_by",
  "archived_at",
  "thread_id",
  "draft",
  "access_contacts",
  "content",
  "actions",
  "mentions",
  "re_note_id",
  "merged_from_thread_id"
) AS SELECT tp.user_id,
    n.id,
    n.created_at,
    n.updated_at,
    n.seq,
    n.source_created_at,
    n.author_id,
    n.created_by,
    n.updated_by,
    COALESCE(n.archived_at, n.updated_at) AS archived_at,
    n.thread_id,
    n.draft,
    NULL::uuid[] AS access_contacts,
    NULL::text AS content,
    NULL::jsonb AS actions,
    NULL::uuid[] AS mentions,
    n.re_note_id,
    n.merged_from_thread_id
   FROM public.note n
     JOIN public.thread a ON a.id = n.thread_id
     JOIN public.thread_priority tp ON tp.thread_id = a.id AND (tp.priority_id IS NOT NULL OR tp.classify_at < (now() - public.classify_visibility_window()))
  WHERE (n.draft = false OR n.created_by = tp.user_id) AND (a.draft = false OR a.created_by = tp.user_id) AND (a.contacts && "user".user_contact_ids(tp.user_id) OR a.groups && "user".user_group_ids(tp.user_id)) AND n.access_contacts IS NOT NULL AND n.created_by <> tp.user_id AND NOT COALESCE(n.access_contacts, ARRAY[]::uuid[]) && "user".user_contact_ids(tp.user_id);
-- Modify "priority_unread" view
CREATE OR REPLACE VIEW "user"."priority_unread" (
  "user_id",
  "priority_id",
  "unread",
  "updated_at"
) AS SELECT tp.user_id,
    COALESCE(tp.priority_id, "user".root_priority_id(tp.user_id)) AS priority_id,
    true AS unread,
    max(tu.updated_at) AS updated_at
   FROM public.thread_priority tp
     JOIN public.thread a ON a.id = tp.thread_id AND a.archived_at IS NULL AND tp.archived_at IS NULL AND (a.draft = false OR a.created_by = tp.user_id) AND (a.contacts && "user".user_contact_ids(tp.user_id) OR a.groups && "user".user_group_ids(tp.user_id)) AND (tp.priority_id IS NOT NULL OR tp.classify_at < (now() - public.classify_visibility_window()))
     JOIN public.thread_unread tu ON tu.user_id = tp.user_id AND tu.thread_id = a.id AND tu.read_at IS NULL
  GROUP BY tp.user_id, (COALESCE(tp.priority_id, "user".root_priority_id(tp.user_id)));
-- Modify "thread_association" view
CREATE OR REPLACE VIEW "user"."thread_association" (
  "user_id",
  "id",
  "created_at",
  "updated_at",
  "seq",
  "archived_at",
  "parent_thread_id",
  "child_thread_id",
  "order"
) AS SELECT tp.user_id,
    ta.id,
    ta.created_at,
    ta.updated_at,
    ta.seq,
    ta.archived_at,
    ta.parent_thread_id,
    ta.child_thread_id,
    ta."order"
   FROM public.thread_association ta
     JOIN public.thread_priority tp ON tp.thread_id = ta.parent_thread_id AND (tp.priority_id IS NOT NULL OR tp.classify_at < (now() - public.classify_visibility_window()));
-- Modify "link" view
CREATE OR REPLACE VIEW "user"."link" (
  "user_id",
  "id",
  "created_at",
  "updated_at",
  "seq",
  "thread_id",
  "source",
  "source_created_at",
  "author_id",
  "twist_id",
  "created_by",
  "updated_by",
  "sync_depth",
  "title",
  "preview",
  "assignee_id",
  "type",
  "status",
  "actions",
  "meta",
  "source_url",
  "channel_id",
  "logo",
  "priority_id",
  "merged_from_thread_id",
  "priority_path"
) AS SELECT COALESCE(tp.user_id, p.user_id) AS user_id,
    l.id,
    l.created_at,
    l.updated_at,
    l.seq,
    l.thread_id,
    l.source,
    l.source_created_at,
    l.author_id,
    l.twist_id,
    l.created_by,
    l.updated_by,
    l.sync_depth,
    l.title,
    l.preview,
    l.assignee_id,
    l.type,
    l.status,
    l.actions,
    l.meta,
    l.source_url,
    l.channel_id,
    l.logo,
    COALESCE(tp.priority_id, "user".root_priority_id(tp.user_id), l.priority_id) AS priority_id,
    l.merged_from_thread_id,
    COALESCE(upe.path, pp.path) AS priority_path
   FROM public.link l
     LEFT JOIN public.thread_priority tp ON tp.thread_id = l.thread_id AND (tp.priority_id IS NOT NULL OR tp.classify_at < (now() - public.classify_visibility_window()))
     LEFT JOIN "user".priority_expanded upe ON upe.user_id = tp.user_id AND upe.priority_id = COALESCE(tp.priority_id, "user".root_priority_id(tp.user_id))
     LEFT JOIN public.priority pp ON pp.id = l.priority_id AND l.thread_id IS NULL
     LEFT JOIN public.priority p ON p.id = l.priority_id AND l.thread_id IS NULL
  WHERE tp.user_id IS NOT NULL OR p.user_id IS NOT NULL;
-- Modify "schedule" view
CREATE OR REPLACE VIEW "user"."schedule" (
  "user_id",
  "id",
  "created_at",
  "updated_at",
  "seq",
  "archived_at",
  "schedule_user_id",
  "order",
  "at",
  "on",
  "recurrence_rule",
  "duration",
  "recurrence_exdates",
  "occurrence",
  "thread_id",
  "link_id",
  "reason",
  "outstanding_tasks",
  "priority_path",
  "range_at",
  "range_on",
  "contacts"
) AS SELECT tp.user_id,
    s.id,
    s.created_at,
    s.updated_at,
    GREATEST(s.seq, COALESCE(( SELECT max(sc.seq) AS max
           FROM public.schedule_contact sc
          WHERE sc.schedule_id = s.id), '0'::xid8)) AS seq,
    COALESCE(s.archived_at, upe.archived_at) AS archived_at,
    s.user_id AS schedule_user_id,
    s."order",
    s.at,
    s."on",
    s.recurrence_rule,
    s.duration,
    s.recurrence_exdates,
    s.occurrence,
    s.thread_id,
    s.link_id,
    s.reason,
    s.outstanding_tasks,
    upe.path AS priority_path,
        CASE
            WHEN s.at IS NOT NULL THEN s.at
            ELSE NULL::tstzrange
        END AS range_at,
        CASE
            WHEN s."on" IS NOT NULL THEN s."on"
            ELSE NULL::daterange
        END AS range_on,
    COALESCE(( SELECT jsonb_agg(jsonb_build_object('id', sc.id, 'contact_id', sc.contact_id, 'contact_email', c.email, 'contact_name', c.name, 'contact_user_id', c.user_id, 'status', sc.status, 'role', sc.role, 'archived_at', sc.archived_at, 'updated_at', sc.updated_at) ORDER BY sc.created_at) AS jsonb_agg
           FROM public.schedule_contact sc
             JOIN public.contact c ON c.id = sc.contact_id
          WHERE sc.schedule_id = s.id), '[]'::jsonb) AS contacts
   FROM public.schedule s
     LEFT JOIN public.link l ON l.id = s.link_id
     JOIN public.thread_priority tp ON tp.thread_id = COALESCE(s.thread_id, l.thread_id) AND (tp.priority_id IS NOT NULL OR tp.classify_at < (now() - public.classify_visibility_window()))
     LEFT JOIN "user".priority_expanded upe ON upe.user_id = tp.user_id AND upe.priority_id = COALESCE(tp.priority_id, "user".root_priority_id(tp.user_id))
  WHERE s.user_id IS NULL OR s.user_id = tp.user_id;
-- Modify "thread" view
CREATE OR REPLACE VIEW "user"."thread" (
  "user_id",
  "id",
  "created_at",
  "updated_at",
  "seq",
  "updated_by",
  "archived_at",
  "priority_id",
  "priority_path",
  "draft",
  "contacts",
  "groups",
  "topic",
  "title",
  "preview",
  "icon",
  "merged_into_thread_id",
  "has_embedding",
  "last_note_created_at",
  "last_note_source_created_at",
  "bumped_at",
  "unread",
  "importance",
  "urgency",
  "activity_at",
  "agenda_at"
) AS WITH link_agg AS (
         SELECT link.thread_id,
            max(link.source_created_at) AS source_created_at
           FROM public.link
          GROUP BY link.thread_id
        )
 SELECT tp.user_id,
    a.id,
    a.created_at,
    GREATEST(a.updated_at, COALESCE(a.last_note_created_at, '1970-01-01 00:00:00+00'::timestamp with time zone), tp.updated_at, COALESCE(tu.updated_at, '1970-01-01 00:00:00+00'::timestamp with time zone)) AS updated_at,
    GREATEST(a.seq, a.last_note_seq, tp.seq, COALESCE(tu.seq, '0'::xid8)) AS seq,
    a.updated_by,
    COALESCE(a.archived_at, tp.archived_at, upe.archived_at) AS archived_at,
    COALESCE(tp.priority_id, "user".root_priority_id(tp.user_id)) AS priority_id,
    upe.path AS priority_path,
    a.draft,
    a.contacts,
    a.groups,
    a.topic,
    a.title,
    a.preview,
    a.icon,
    a.merged_into_thread_id,
    a.embedding IS NOT NULL AS has_embedding,
    a.last_note_created_at,
    a.last_note_source_created_at,
    tu.bumped_at,
    COALESCE(tu.read_at IS NULL AND tu.user_id IS NOT NULL, false) AS unread,
    COALESCE(
        CASE
            WHEN tu.read_at IS NULL AND tu.user_id IS NOT NULL THEN tu.importance
            ELSE NULL::smallint
        END, 0::smallint) AS importance,
    COALESCE(
        CASE
            WHEN tu.read_at IS NULL AND tu.user_id IS NOT NULL THEN tu.urgency
            ELSE NULL::text
        END, NULL::text) AS urgency,
    COALESCE(GREATEST(a.last_note_source_created_at, la.source_created_at, tu.bumped_at, ( SELECT
                CASE
                    WHEN COALESCE(upper(s_feed.at), upper(s_feed."on")::timestamp with time zone) <= now() THEN COALESCE(upper(s_feed.at), upper(s_feed."on")::timestamp with time zone)
                    ELSE NULL::timestamp with time zone
                END AS "case"
           FROM public.schedule s_feed
          WHERE s_feed.thread_id = a.id AND s_feed.user_id IS NULL AND s_feed.occurrence IS NULL AND s_feed.archived_at IS NULL
         LIMIT 1)), a.created_at) AS activity_at,
    ( SELECT tstzrange(bounds.lo, GREATEST(bounds.lo, bounds.hi), '[]'::text) AS tstzrange
           FROM ( SELECT COALESCE(LEAST(( SELECT COALESCE(lower(s_lo.at), lower(s_lo."on")::timestamp with time zone) AS "coalesce"
                           FROM public.schedule s_lo
                          WHERE s_lo.thread_id = a.id AND s_lo.user_id IS NULL AND s_lo.archived_at IS NULL
                          ORDER BY (COALESCE(lower(s_lo.at), lower(s_lo."on")::timestamp with time zone))
                         LIMIT 1), ( SELECT COALESCE(lower(s_lo.at), lower(s_lo."on")::timestamp with time zone) AS "coalesce"
                           FROM public.schedule s_lo
                          WHERE s_lo.thread_id = a.id AND s_lo.user_id = tp.user_id AND s_lo.archived_at IS NULL
                          ORDER BY (COALESCE(lower(s_lo.at), lower(s_lo."on")::timestamp with time zone))
                         LIMIT 1), ( SELECT COALESCE(lower(s_lo.at), lower(s_lo."on")::timestamp with time zone) AS "coalesce"
                           FROM public.schedule s_lo
                             JOIN public.link l_lo ON l_lo.id = s_lo.link_id
                          WHERE l_lo.thread_id = a.id AND s_lo.user_id IS NULL AND s_lo.archived_at IS NULL
                          ORDER BY (COALESCE(lower(s_lo.at), lower(s_lo."on")::timestamp with time zone))
                         LIMIT 1)), a.created_at) AS lo,
                    COALESCE(
                        CASE
                            WHEN (EXISTS ( SELECT 1
                               FROM public.schedule s_rec
                              WHERE s_rec.thread_id = a.id AND s_rec.archived_at IS NULL AND s_rec.recurrence_rule IS NOT NULL)) OR (EXISTS ( SELECT 1
                               FROM public.schedule s_rec
                                 JOIN public.link l_rec ON l_rec.id = s_rec.link_id
                              WHERE l_rec.thread_id = a.id AND s_rec.archived_at IS NULL AND s_rec.recurrence_rule IS NOT NULL)) THEN 'infinity'::timestamp with time zone
                            WHEN (EXISTS ( SELECT 1
                               FROM public.schedule s_ub
                              WHERE s_ub.thread_id = a.id AND s_ub.archived_at IS NULL AND (s_ub.at IS NOT NULL OR s_ub."on" IS NOT NULL) AND COALESCE(upper(s_ub.at), upper(s_ub."on")::timestamp with time zone) IS NULL)) OR (EXISTS ( SELECT 1
                               FROM public.schedule s_ub
                                 JOIN public.link l_ub ON l_ub.id = s_ub.link_id
                              WHERE l_ub.thread_id = a.id AND s_ub.archived_at IS NULL AND (s_ub.at IS NOT NULL OR s_ub."on" IS NOT NULL) AND COALESCE(upper(s_ub.at), upper(s_ub."on")::timestamp with time zone) IS NULL)) THEN 'infinity'::timestamp with time zone
                            ELSE GREATEST(( SELECT COALESCE(upper(s_hi.at), upper(s_hi."on")::timestamp with time zone) AS "coalesce"
                               FROM public.schedule s_hi
                              WHERE s_hi.thread_id = a.id AND s_hi.user_id IS NULL AND s_hi.archived_at IS NULL
                              ORDER BY (COALESCE(upper(s_hi.at), upper(s_hi."on")::timestamp with time zone)) DESC NULLS LAST
                             LIMIT 1), ( SELECT COALESCE(upper(s_hi.at), upper(s_hi."on")::timestamp with time zone) AS "coalesce"
                               FROM public.schedule s_hi
                              WHERE s_hi.thread_id = a.id AND s_hi.user_id = tp.user_id AND s_hi.archived_at IS NULL
                              ORDER BY (COALESCE(upper(s_hi.at), upper(s_hi."on")::timestamp with time zone)) DESC NULLS LAST
                             LIMIT 1), ( SELECT COALESCE(upper(s_hi.at), upper(s_hi."on")::timestamp with time zone) AS "coalesce"
                               FROM public.schedule s_hi
                                 JOIN public.link l_hi ON l_hi.id = s_hi.link_id
                              WHERE l_hi.thread_id = a.id AND s_hi.user_id IS NULL AND s_hi.archived_at IS NULL
                              ORDER BY (COALESCE(upper(s_hi.at), upper(s_hi."on")::timestamp with time zone)) DESC NULLS LAST
                             LIMIT 1))
                        END, a.created_at) AS hi) bounds) AS agenda_at
   FROM public.thread a
     JOIN public.thread_priority tp ON tp.thread_id = a.id
     LEFT JOIN "user".priority_expanded upe ON upe.user_id = tp.user_id AND upe.priority_id = COALESCE(tp.priority_id, "user".root_priority_id(tp.user_id))
     LEFT JOIN public.thread_unread tu ON tu.user_id = tp.user_id AND tu.thread_id = a.id
     LEFT JOIN link_agg la ON la.thread_id = a.id
  WHERE (a.draft = false OR a.created_by = tp.user_id) AND (a.contacts && "user".user_contact_ids(tp.user_id) OR a.groups && "user".user_group_ids(tp.user_id)) AND (tp.priority_id IS NOT NULL OR tp.classify_at < (now() - public.classify_visibility_window()));
