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
    -- is a user (not a twist) lacking write access, allow only per-user
    -- archive or mute: if archived_at and/or mute_by_thread_id are the only
    -- mutated fields, update thread_priority and return the unchanged
    -- thread. Reject any other metadata change.
    IF v_existing.id IS NOT NULL
       AND v_created_by = upsert_thread.user_id
       AND NOT "user".user_has_thread_write_access(upsert_thread.user_id, v_existing.id)
    THEN
        IF p_thread ? 'archived_at' OR p_thread ? 'mute_by_thread_id' THEN
            UPDATE thread_priority tp
            SET archived_at = CASE
                    WHEN p_thread ? 'archived_at' THEN
                        NULLIF(p_thread ->> 'archived_at', '')::timestamptz
                    ELSE tp.archived_at
                END,
                mute_by_thread_id = CASE
                    WHEN p_thread ? 'mute_by_thread_id' THEN
                        NULLIF(p_thread ->> 'mute_by_thread_id', '')::uuid
                    ELSE tp.mute_by_thread_id
                END,
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
        -- ORDER BY x makes the array order deterministic so that downstream
        -- consumers (the user_contact INSERT below and the
        -- sync_user_contact_for_thread_contacts trigger) acquire row locks
        -- in a stable order. Without it, two concurrent upserts of threads
        -- with overlapping contacts can lock the same (user_id, contact_id)
        -- pairs in different orders and deadlock.
        SELECT COALESCE(array_agg(DISTINCT x ORDER BY x), ARRAY[]::uuid[])
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
        SELECT COALESCE(array_agg(DISTINCT p ORDER BY p), ARRAY[]::uuid[])
        INTO v_promoted_contacts
        FROM unnest(v_existing.pending_contacts) AS p
        WHERE p = ANY(v_input_contacts);
        -- Promoted contacts also go into the merged contacts list.
        IF cardinality(v_promoted_contacts) > 0 THEN
            SELECT COALESCE(array_agg(DISTINCT x ORDER BY x), ARRAY[]::uuid[])
            INTO v_merged_contacts
            FROM unnest(v_merged_contacts || v_promoted_contacts) AS x;
        END IF;
    ELSE
        v_promoted_contacts := ARRAY[]::uuid[];
    END IF;

    -- Perform the upsert. twist_id is set only on the insert path; the update
    -- path preserves thread.twist_id so first-creator wins.
    INSERT INTO thread (
        id, created_by, title, preview, updated_by, sync_depth, contacts, contact_meta, groups, topic,
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
        -- Additive merge of caller-provided contact_meta (entries keyed by
        -- contact_id) onto whatever the row already has. Keys that match
        -- contacts being removed below are not stripped here; that's the
        -- POST /thread/:id/share path's job.
        COALESCE(v_existing.contact_meta, '{}'::jsonb)
            || COALESCE((p_thread -> 'contact_meta'), '{}'::jsonb),
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
            -- Additive contact_meta merge: caller-provided entries (keyed by
            -- contact_id) override existing entries for the same contact;
            -- entries for contacts the caller didn't mention are preserved.
            -- Per-contact role changes / removals go through share_thread
            -- (POST /thread/:id/share), not through upsert_thread.
            contact_meta = CASE WHEN p_thread ? 'contact_meta' THEN
                COALESCE(thread.contact_meta, '{}'::jsonb)
                    || COALESCE((p_thread -> 'contact_meta'), '{}'::jsonb)
            ELSE
                thread.contact_meta
            END,
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
        INSERT INTO thread_priority (
            thread_id, user_id, priority_id, applied_default_channel_id,
            mute_by_thread_id
        )
        VALUES (
            v_result.id,
            upsert_thread.user_id,
            v_priority_id,
            CASE
                WHEN p_thread ? 'priority_id' THEN NULL
                ELSE public.channel_default_marker (
                    upsert_thread.user_id, v_result.id, v_priority_id
                )
            END,
            NULLIF(p_thread ->> 'mute_by_thread_id', '')::uuid
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
            -- Mute flag: explicit payload value wins; otherwise preserve.
            -- The clear path (broom toggled off) is handled by
            -- "user".clear_mute, invoked by the API after upsert.
            mute_by_thread_id = CASE
                WHEN p_thread ? 'mute_by_thread_id' THEN
                    NULLIF(p_thread ->> 'mute_by_thread_id', '')::uuid
                ELSE thread_priority.mute_by_thread_id
            END,
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

        INSERT INTO thread_state (user_id, thread_id)
        SELECT peer.user_id, v_result.id
        FROM (
            SELECT DISTINCT uc.user_id
            FROM unnest(v_promoted_contacts) AS arr(contact_id)
            JOIN user_contact uc
              ON uc.contact_id = arr.contact_id
             AND uc.linked = TRUE
             AND uc.archived_at IS NULL
            WHERE uc.user_id IS DISTINCT FROM upsert_thread.user_id
        ) peer
        ON CONFLICT ON CONSTRAINT thread_state_pkey DO NOTHING;
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
    -- ORDER BY arr.contact_id locks (user_id, contact_id) rows in a stable
    -- order across concurrent transactions. Without it, two parallel
    -- upsert_thread calls with overlapping contacts (e.g. two Gmail
    -- webhooks arriving in close succession) can attempt to take the same
    -- user_contact row locks in different orders and deadlock.
    IF v_result.contacts IS NOT NULL AND cardinality(v_result.contacts) > 0 THEN
        INSERT INTO user_contact (user_id, contact_id, linked, source)
        SELECT upsert_thread.user_id, arr.contact_id, false, 'thread'
        FROM unnest(v_result.contacts) AS arr(contact_id)
        WHERE EXISTS (SELECT 1 FROM contact c WHERE c.id = arr.contact_id)
        ORDER BY arr.contact_id
        ON CONFLICT ON CONSTRAINT user_contact_pkey DO NOTHING;
    END IF;

    RETURN v_result;
END;
$$;
-- Create "find_mute_candidates" function
CREATE FUNCTION "user"."find_mute_candidates" ("p_user_id" uuid, "p_seed_thread_id" uuid) RETURNS SETOF uuid LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_seed_channels text[];
    v_seed_author uuid;
    v_seed_topic text;
    v_seed_title_norm text;
    v_seed_embedding public.halfvec;
    v_user_contacts uuid[];
    v_user_groups uuid[];
BEGIN
    -- Collect distinct channel ids across all links on the seed thread.
    SELECT array_agg(DISTINCT l.channel_id)
    INTO v_seed_channels
    FROM public.link l
    WHERE l.thread_id = p_seed_thread_id
      AND l.channel_id IS NOT NULL;

    -- Seed must have at least one channel signal — otherwise we can't
    -- bound the rule and a runaway match would surprise the user.
    IF v_seed_channels IS NULL OR cardinality(v_seed_channels) = 0 THEN
        RETURN;
    END IF;

    -- Pick the seed's link author (first non-null wins; usually only one).
    SELECT l.author_id
    INTO v_seed_author
    FROM public.link l
    WHERE l.thread_id = p_seed_thread_id
      AND l.author_id IS NOT NULL
    LIMIT 1;

    SELECT t.topic, t.embedding, public.normalize_title(t.title)
    INTO v_seed_topic, v_seed_embedding, v_seed_title_norm
    FROM public.thread t
    WHERE t.id = p_seed_thread_id;

    -- Need either author (from a link) or topic to identify the sender side.
    IF v_seed_author IS NULL AND v_seed_topic IS NULL THEN
        RETURN;
    END IF;

    v_user_contacts := "user".user_contact_ids(p_user_id);
    v_user_groups := "user".user_group_ids(p_user_id);

    RETURN QUERY
    SELECT t.id
    FROM public.thread t
    JOIN public.thread_priority tp
        ON tp.thread_id = t.id
       AND tp.user_id = p_user_id
       AND tp.archived_at IS NULL
       AND tp.mute_by_thread_id IS NULL
    WHERE t.id <> p_seed_thread_id
      AND t.archived_at IS NULL
      AND (t.draft = FALSE OR t.created_by = p_user_id)
      AND (t.contacts && v_user_contacts OR t.groups && v_user_groups)
      -- Channel match (required).
      AND EXISTS (
          SELECT 1
          FROM public.link l
          WHERE l.thread_id = t.id
            AND l.channel_id = ANY (v_seed_channels)
      )
      -- Author OR topic match.
      AND (
          (v_seed_author IS NOT NULL AND EXISTS (
              SELECT 1
              FROM public.link l
              WHERE l.thread_id = t.id
                AND l.author_id = v_seed_author
          ))
          OR (v_seed_author IS NULL AND v_seed_topic IS NOT NULL AND t.topic = v_seed_topic)
      )
      -- Content match: normalized title OR embedding similarity.
      AND (
          (v_seed_title_norm IS NOT NULL
           AND public.normalize_title(t.title) = v_seed_title_norm)
          OR (v_seed_embedding IS NOT NULL
              AND t.embedding IS NOT NULL
              AND (t.embedding <=> v_seed_embedding) <= 0.15)
      );
END;
$$;
-- Set comment to function: "find_mute_candidates"
COMMENT ON FUNCTION "user"."find_mute_candidates" IS 'Returns thread ids the given user can see and that match the seed thread''s mute rule (same channel + same link author (or topic when no link author) + similar title or embedding). Excludes threads already muted.';
-- Create "apply_mute" function
CREATE FUNCTION "user"."apply_mute" ("p_user_id" uuid, "p_seed_thread_id" uuid) RETURNS integer LANGUAGE plpgsql AS $$
DECLARE
    v_affected integer := 0;
    v_candidate_ids uuid[];
    v_lock_ids uuid[];
BEGIN
    -- Collect candidate ids up front. Materializing them (rather than
    -- streaming the SETOF into the INSERT below) lets us:
    --   1. Pre-lock the parent thread rows in a deterministic order, and
    --   2. Drive the thread_priority upsert from a sortable array.
    SELECT COALESCE(array_agg(cid), ARRAY[]::uuid[])
    INTO v_candidate_ids
    FROM "user".find_mute_candidates(p_user_id, p_seed_thread_id) cid;

    -- Lock every thread we're about to touch — the seed plus the fan-out
    -- candidates — in ascending id order. upsert_thread always locks
    -- thread → thread_priority in that order; taking the locks here in
    -- the same order avoids deadlocks with concurrent upsert_thread.
    SELECT COALESCE(array_agg(DISTINCT id ORDER BY id), ARRAY[]::uuid[])
    INTO v_lock_ids
    FROM unnest(v_candidate_ids || ARRAY[p_seed_thread_id]) AS id
    WHERE id IS NOT NULL;

    IF cardinality(v_lock_ids) > 0 THEN
        PERFORM 1
        FROM public.thread t
        WHERE t.id = ANY(v_lock_ids)
        ORDER BY t.id
        FOR NO KEY UPDATE;
    END IF;

    -- Stamp the seed's thread_priority row. We use ON CONFLICT DO UPDATE
    -- rather than a bare UPDATE so a user who somehow lacks a
    -- thread_priority row for the seed still gets the rule recorded;
    -- that's unusual but cheap to handle.
    INSERT INTO public.thread_priority (
        thread_id, user_id, priority_id, mute_by_thread_id
    )
    VALUES (
        p_seed_thread_id,
        p_user_id,
        "user".root_priority_id(p_user_id),
        p_seed_thread_id
    )
    ON CONFLICT ON CONSTRAINT thread_priority_pkey
    DO UPDATE SET
        mute_by_thread_id = p_seed_thread_id,
        updated_at = now();

    -- Mark the seed read and inactive so it moves to Done immediately.
    INSERT INTO public.thread_state (
        user_id, thread_id, active, read_at
    )
    VALUES (p_user_id, p_seed_thread_id, FALSE, now())
    ON CONFLICT (user_id, thread_id)
    DO UPDATE SET
        active = FALSE,
        read_at = COALESCE(thread_state.read_at, now()),
        updated_at = now();

    -- Fan out to candidates. INSERT then ON CONFLICT update so candidates
    -- without a thread_priority row (rare — typically every visible thread
    -- has one) also pick up the flag. ORDER BY thread_id makes the lock
    -- acquisition on thread_priority deterministic across concurrent
    -- apply_mute calls (same user, different seeds with overlapping
    -- candidates) so they can't deadlock with each other.
    IF cardinality(v_candidate_ids) > 0 THEN
        WITH upserted AS (
            INSERT INTO public.thread_priority (
                thread_id, user_id, priority_id, mute_by_thread_id
            )
            SELECT c.thread_id,
                   p_user_id,
                   "user".root_priority_id(p_user_id),
                   p_seed_thread_id
            FROM unnest(v_candidate_ids) AS c(thread_id)
            ORDER BY c.thread_id
            ON CONFLICT ON CONSTRAINT thread_priority_pkey
            DO UPDATE SET
                mute_by_thread_id = p_seed_thread_id,
                updated_at = now()
            RETURNING thread_id
        )
        SELECT count(*)::int INTO v_affected FROM upserted;

        -- Mark every candidate read and inactive.
        INSERT INTO public.thread_state (user_id, thread_id, active, read_at)
        SELECT p_user_id, c.thread_id, FALSE, now()
        FROM unnest(v_candidate_ids) AS c(thread_id)
        ORDER BY c.thread_id
        ON CONFLICT (user_id, thread_id)
        DO UPDATE SET
            active = FALSE,
            read_at = COALESCE(thread_state.read_at, now()),
            updated_at = now();
    END IF;

    RETURN v_affected;
END;
$$;
-- Set comment to function: "apply_mute"
COMMENT ON FUNCTION "user"."apply_mute" IS 'Apply the "Skip active for threads like this" mute rule anchored at p_seed_thread_id for p_user_id. Stamps mute_by_thread_id=seed and marks read+inactive in thread_state for both the seed and every candidate (per find_mute_candidates). Returns affected candidate count.';
-- Create "apply_mute_for_new_thread" function
CREATE FUNCTION "user"."apply_mute_for_new_thread" ("p_user_id" uuid, "p_thread_id" uuid) RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE
    v_seed_id uuid;
    v_match boolean;
BEGIN
    -- Skip if the thread is already archived (don't reapply on top of an
    -- explicit user action) or if it's itself a seed / already muted.
    IF EXISTS (
        SELECT 1
        FROM public.thread_priority tp
        WHERE tp.thread_id = p_thread_id
          AND tp.user_id = p_user_id
          AND (tp.archived_at IS NOT NULL
               OR tp.mute_by_thread_id IS NOT NULL)
    ) THEN
        RETURN NULL;
    END IF;

    -- Iterate over the user's seed rows (self-referencing ones). Typically
    -- a small set per user. Pick the most recently activated rule first so
    -- newer seeds win when several would match.
    FOR v_seed_id IN
        SELECT tp.thread_id
        FROM public.thread_priority tp
        WHERE tp.user_id = p_user_id
          AND tp.mute_by_thread_id = tp.thread_id
        ORDER BY tp.updated_at DESC
    LOOP
        -- Does the new thread match this seed's criteria?
        SELECT EXISTS (
            SELECT 1
            FROM "user".find_mute_candidates(p_user_id, v_seed_id) cid
            WHERE cid = p_thread_id
        )
        INTO v_match;

        IF v_match THEN
            UPDATE public.thread_priority tp
            SET mute_by_thread_id = v_seed_id,
                updated_at = now()
            WHERE tp.thread_id = p_thread_id
              AND tp.user_id = p_user_id;

            -- Mark read + inactive so the thread surfaces in Done.
            INSERT INTO public.thread_state (
                user_id, thread_id, active, read_at
            )
            VALUES (p_user_id, p_thread_id, FALSE, now())
            ON CONFLICT (user_id, thread_id)
            DO UPDATE SET
                active = FALSE,
                read_at = COALESCE(thread_state.read_at, now()),
                updated_at = now();

            RETURN v_seed_id;
        END IF;
    END LOOP;

    RETURN NULL;
END;
$$;
-- Set comment to function: "apply_mute_for_new_thread"
COMMENT ON FUNCTION "user"."apply_mute_for_new_thread" IS 'Check a newly synced thread against the user''s active mute seeds. If it matches one, stamp the seed reference and mark the thread read + inactive. Returns the matching seed id or NULL. No-ops on threads already archived/muted.';
-- Create "clear_mute" function
CREATE FUNCTION "user"."clear_mute" ("p_user_id" uuid, "p_seed_thread_id" uuid) RETURNS integer LANGUAGE plpgsql AS $$
DECLARE
    v_affected integer;
    v_target_ids uuid[];
BEGIN
    -- Materialize the target thread ids first so we can lock the parent
    -- thread rows in deterministic order (matching upsert_thread's
    -- thread → thread_priority order). Concurrent upsert_thread on one
    -- of the target threads would otherwise see clear_mute lock
    -- thread_priority first; an AFTER UPDATE trigger could then need the
    -- thread row already held by the other transaction and deadlock.
    SELECT COALESCE(array_agg(tp.thread_id ORDER BY tp.thread_id), ARRAY[]::uuid[])
    INTO v_target_ids
    FROM public.thread_priority tp
    WHERE tp.user_id = p_user_id
      AND tp.mute_by_thread_id = p_seed_thread_id;

    IF cardinality(v_target_ids) = 0 THEN
        RETURN 0;
    END IF;

    PERFORM 1
    FROM public.thread t
    WHERE t.id = ANY(v_target_ids)
    ORDER BY t.id
    FOR NO KEY UPDATE;

    WITH updated AS (
        UPDATE public.thread_priority tp
        SET mute_by_thread_id = NULL,
            updated_at = now()
        WHERE tp.user_id = p_user_id
          AND tp.thread_id = ANY(v_target_ids)
        RETURNING tp.thread_id
    )
    SELECT count(*)::int INTO v_affected FROM updated;

    RETURN COALESCE(v_affected, 0);
END;
$$;
-- Set comment to function: "clear_mute"
COMMENT ON FUNCTION "user"."clear_mute" IS 'Reverse the "Skip active for threads like this" mute rule anchored at p_seed_thread_id for p_user_id. Clears mute_by_thread_id on every thread_priority row that was filed under the seed. Returns affected row count.';
-- Rename the per-user rule-anchor column. Preserves existing data — rows
-- previously archived under "Archive threads like this" keep their archive
-- state and seed reference. PostgreSQL propagates the column reference into
-- dependent view parse trees automatically, but the view's output column
-- alias is stored separately and must be renamed with ALTER VIEW below.
ALTER TABLE "public"."thread_priority" RENAME COLUMN "auto_archived_by_thread_id" TO "mute_by_thread_id";
-- Rename the output column on user.thread to match the new schema-file
-- definition. Required before CREATE OR REPLACE VIEW: that statement can
-- add trailing columns but cannot rename existing ones.
ALTER VIEW "user"."thread" RENAME COLUMN "auto_archived_by_thread_id" TO "mute_by_thread_id";
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
  "contact_meta",
  "groups",
  "topic",
  "title",
  "preview",
  "icon",
  "merged_into_thread_id",
  "has_embedding",
  "mute_by_thread_id",
  "last_note_created_at",
  "last_note_source_created_at",
  "bumped_at",
  "unread",
  "importance",
  "active",
  "task",
  "to_read",
  "urgent",
  "state_order",
  "state_on",
  "state_at",
  "activity_at",
  "agenda_at",
  "revoked"
) AS WITH link_agg AS (
         SELECT link.thread_id,
            max(link.source_created_at) AS source_created_at
           FROM public.link
          GROUP BY link.thread_id
        )
 SELECT tp.user_id,
    a.id,
    a.created_at,
    GREATEST(a.updated_at, COALESCE(a.last_note_created_at, '1970-01-01 00:00:00+00'::timestamp with time zone), tp.updated_at, COALESCE(ts.updated_at, '1970-01-01 00:00:00+00'::timestamp with time zone)) AS updated_at,
    GREATEST(a.seq, a.last_note_seq, tp.seq, COALESCE(ts.seq, '0'::xid8)) AS seq,
    a.updated_by,
    COALESCE(a.archived_at, tp.archived_at, upe.archived_at) AS archived_at,
    COALESCE(tp.priority_id, "user".root_priority_id(tp.user_id)) AS priority_id,
    upe.path AS priority_path,
    a.draft,
    a.contacts,
    a.contact_meta,
    a.groups,
    a.topic,
    a.title,
    a.preview,
    a.icon,
    a.merged_into_thread_id,
    a.embedding IS NOT NULL AS has_embedding,
    tp.mute_by_thread_id,
    a.last_note_created_at,
    a.last_note_source_created_at,
    ts.bumped_at,
    COALESCE(ts.read_at IS NULL AND ts.user_id IS NOT NULL, false) AS unread,
    COALESCE(ts.importance, 0::smallint) AS importance,
    COALESCE(ts.active, false) AS active,
    COALESCE(ts.task, false) AS task,
    COALESCE(ts.to_read, false) AS to_read,
    ts.urgent,
    ts."order" AS state_order,
    ts."on" AS state_on,
    ts.at AS state_at,
    COALESCE(GREATEST(a.last_note_source_created_at, la.source_created_at, ts.bumped_at, ( SELECT
                CASE
                    WHEN COALESCE(upper(s_feed.at), upper(s_feed."on")::timestamp with time zone) <= now() THEN COALESCE(upper(s_feed.at), upper(s_feed."on")::timestamp with time zone)
                    ELSE NULL::timestamp with time zone
                END AS "case"
           FROM public.schedule s_feed
          WHERE s_feed.thread_id = a.id AND s_feed.occurrence IS NULL AND s_feed.archived_at IS NULL
         LIMIT 1)), a.created_at) AS activity_at,
    ( SELECT tstzrange(bounds.lo, GREATEST(bounds.lo, bounds.hi), '[]'::text) AS tstzrange
           FROM ( SELECT COALESCE(LEAST(( SELECT COALESCE(lower(s_lo.at), lower(s_lo."on")::timestamp with time zone) AS "coalesce"
                           FROM public.schedule s_lo
                          WHERE s_lo.thread_id = a.id AND s_lo.archived_at IS NULL
                          ORDER BY (COALESCE(lower(s_lo.at), lower(s_lo."on")::timestamp with time zone))
                         LIMIT 1), COALESCE(lower(ts.at), lower(ts."on")::timestamp with time zone), ( SELECT COALESCE(lower(s_lo.at), lower(s_lo."on")::timestamp with time zone) AS "coalesce"
                           FROM public.schedule s_lo
                             JOIN public.link l_lo ON l_lo.id = s_lo.link_id
                          WHERE l_lo.thread_id = a.id AND s_lo.archived_at IS NULL
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
                              WHERE s_hi.thread_id = a.id AND s_hi.archived_at IS NULL
                              ORDER BY (COALESCE(upper(s_hi.at), upper(s_hi."on")::timestamp with time zone)) DESC NULLS LAST
                             LIMIT 1), COALESCE(upper(ts.at), upper(ts."on")::timestamp with time zone), ( SELECT COALESCE(upper(s_hi.at), upper(s_hi."on")::timestamp with time zone) AS "coalesce"
                               FROM public.schedule s_hi
                                 JOIN public.link l_hi ON l_hi.id = s_hi.link_id
                              WHERE l_hi.thread_id = a.id AND s_hi.archived_at IS NULL
                              ORDER BY (COALESCE(upper(s_hi.at), upper(s_hi."on")::timestamp with time zone)) DESC NULLS LAST
                             LIMIT 1))
                        END, a.created_at) AS hi) bounds) AS agenda_at,
    false AS revoked
   FROM public.thread a
     JOIN public.thread_priority tp ON tp.thread_id = a.id
     LEFT JOIN "user".priority_expanded upe ON upe.user_id = tp.user_id AND upe.priority_id = COALESCE(tp.priority_id, "user".root_priority_id(tp.user_id))
     JOIN public.priority p ON p.id = COALESCE(tp.priority_id, "user".root_priority_id(tp.user_id))
     LEFT JOIN public.thread_state ts ON ts.user_id = tp.user_id AND ts.thread_id = a.id
     LEFT JOIN link_agg la ON la.thread_id = a.id
  WHERE tp.revoked_at IS NULL AND (a.draft = false OR a.created_by = tp.user_id) AND (a.contacts && "user".user_contact_ids(tp.user_id) OR a.groups && "user".user_group_ids(tp.user_id)) AND (tp.priority_id IS NOT NULL OR tp.classify_at < (now() - public.classify_visibility_window())) AND (p.team_id IS NULL OR (EXISTS ( SELECT 1
           FROM public.team_user tu2
          WHERE tu2.team_id = p.team_id AND tu2.user_id = tp.user_id AND tu2.archived_at IS NULL)));
-- Rename a view column from "auto_archived_by_thread_id" to "mute_by_thread_id"
ALTER VIEW "user"."thread_redacted" RENAME COLUMN "auto_archived_by_thread_id" TO "mute_by_thread_id";
-- Drop "apply_auto_archive" function
DROP FUNCTION "user"."apply_auto_archive";
-- Drop "apply_auto_archive_for_new_thread" function
DROP FUNCTION "user"."apply_auto_archive_for_new_thread";
-- Drop "clear_auto_archive" function
DROP FUNCTION "user"."clear_auto_archive";
-- Drop "find_auto_archive_candidates" function
DROP FUNCTION "user"."find_auto_archive_candidates";
