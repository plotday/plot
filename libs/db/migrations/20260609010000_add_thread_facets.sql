-- Drop "thread_x" view
DROP VIEW "public"."thread_x";
-- Modify "thread" table
ALTER TABLE "public"."thread" ADD COLUMN "facets" jsonb NULL;
-- Modify "upsert_thread" function
CREATE OR REPLACE FUNCTION "user"."upsert_thread" ("user_id" uuid, "p_thread" jsonb, "p_defaults" jsonb DEFAULT '{}') RETURNS "public"."thread" LANGUAGE plpgsql AS $$
DECLARE
    v_result thread;
    v_existing thread;
    v_id uuid;
    v_priority_id uuid;
    v_created_by uuid;
    -- The actor credited with CAUSING the thread (distinct from v_created_by).
    -- Set on INSERT and filled-only-when-NULL on UPDATE; never re-attributed.
    v_author_id uuid;
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
    -- Input topic_id — the channel the thread belongs to.
    v_input_topic_id uuid;
    -- Derived topic for INSERT path.
    v_resolved_topic text;
    -- Whether the caller should get a thread_priority row this call.
    v_caller_attested boolean;
BEGIN
    -- Extract identifiers and derived values.
    v_id := COALESCE((p_thread ->> 'id')::uuid, (p_defaults ->> 'id')::uuid);
    v_priority_id := COALESCE((p_thread ->> 'priority_id')::uuid, (p_defaults ->> 'priority_id')::uuid);
    v_created_by := COALESCE((p_thread ->> 'created_by')::uuid, (p_defaults ->> 'created_by')::uuid, user_id);

    -- Who CAUSED this thread (distinct from created_by, the acting entity):
    --   1. explicit author_id from the caller (rare),
    --   2. connector/twist runtime supplies the resolved author in p_defaults,
    --   3. app user → their primary contact (user_contact_id is non-null only
    --      for a user, NULL for a twist_instance id),
    --   4. fallback → created_by (a non-connection twist credits itself).
    v_author_id := COALESCE(
        (p_thread   ->> 'author_id')::uuid,
        (p_defaults ->> 'author_id')::uuid,
        "user".user_contact_id(v_created_by),
        v_created_by
    );

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

    -- Authorization guard for author_id (mirrors the created_by check above):
    -- a USER caller may only attribute a thread to one of their OWN linked
    -- contacts — never spoof authorship to an arbitrary/other person. The
    -- connector/twist path legitimately credits an EXTERNAL author via
    -- p_defaults.author_id and is trusted here (created_by is the owned
    -- twist_instance, just validated). Only an explicitly-supplied value is
    -- checked; the derived fallback (user_contact_id(user_id)) is always safe.
    IF v_created_by = upsert_thread.user_id
       AND COALESCE((p_thread ->> 'author_id')::uuid, (p_defaults ->> 'author_id')::uuid) IS NOT NULL
       AND NOT (COALESCE((p_thread ->> 'author_id')::uuid, (p_defaults ->> 'author_id')::uuid) = ANY(v_user_contacts))
    THEN
        RAISE EXCEPTION 'author_id must be one of the caller''s linked contacts';
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
    v_input_topic_id := COALESCE((p_thread ->> 'topic_id')::uuid, (p_defaults ->> 'topic_id')::uuid);

    -- On INSERT, derive a default topic when none was provided.
    --
    -- User-authored threads (v_twist_id IS NULL): resolution order
    -- priority.config->>'topic' → priority.id::text (for non-root
    -- priorities, so sibling threads filed in the same sub-priority share a
    -- topic filter for classify_thread_for_user) → groups[1]::text.
    --
    -- Connector/twist threads (v_twist_id IS NOT NULL): leave topic NULL so
    -- the set_thread_topic_from_link_channel trigger keys them by
    -- 'channel:<channel.id>' on link insert. Deriving priority.id here would
    -- pre-empt that trigger (it fires only WHERE topic IS NULL) and collapse
    -- every channel filed under one sub-priority into a single coarse topic,
    -- which made topic_shortcircuit funnel unrelated threads into one
    -- priority. Connector threads must be keyed by their channel, not by the
    -- priority the classifier happened to pick at creation.
    IF v_existing.id IS NULL AND v_input_topic IS NULL THEN
        IF v_input_topic_id IS NOT NULL THEN
            -- A topic-addressed thread routes by its channel, stable across
            -- the whole stream, so the classifier topic short-circuit groups
            -- the user's moves of any one thread onto all the others.
            v_resolved_topic := 'topic:' || v_input_topic_id::text;
        ELSIF v_twist_id IS NULL THEN
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
        id, created_by, author_id, title, preview, updated_by, sync_depth, contacts, contact_meta, groups, topic,
        draft, key, icon, twist_id, pending_contacts, team_id, embedding, assignee_id, topic_id, facets
    )
    VALUES (
        v_id,
        v_created_by,
        v_author_id,
        COALESCE(p_thread ->> 'title', p_defaults ->> 'title', v_existing.title),
        COALESCE(p_thread ->> 'preview', p_defaults ->> 'preview', v_existing.preview),
        COALESCE((p_thread ->> 'updated_by')::integer, (p_defaults ->> 'updated_by')::integer, v_existing.updated_by, 0),
        COALESCE((p_thread ->> 'sync_depth')::smallint, (p_defaults ->> 'sync_depth')::smallint, v_existing.sync_depth),
        v_merged_contacts,
        -- Additive merge of caller-provided contact_meta (entries keyed by
        -- contact_id) onto whatever the row already has. Keys that match
        -- contacts being removed below are not stripped here; that's the
        -- POST /thread/:id/share path's job.
        -- Only merge when the caller actually provided an object. A literal
        -- JSON null (`"contact_meta": null`, which clients send for "no meta")
        -- is a JSONB 'null', not SQL NULL, so COALESCE(..., '{}') won't catch
        -- it — and `'{}'::jsonb || 'null'::jsonb` coerces both operands to
        -- single-element arrays and yields `[{}, null]`, corrupting the column
        -- (it must stay an object keyed by contact_id). Guard on jsonb_typeof
        -- so null/array/scalar inputs become a no-op merge.
        COALESCE(v_existing.contact_meta, '{}'::jsonb)
            || (CASE WHEN jsonb_typeof(p_thread -> 'contact_meta') = 'object'
                    THEN p_thread -> 'contact_meta'
                    ELSE '{}'::jsonb END),
        v_input_groups,
        v_resolved_topic,
        COALESCE((p_thread ->> 'draft')::boolean, (p_defaults ->> 'draft')::boolean, v_existing.draft, FALSE),
        COALESCE(p_thread ->> 'key', p_defaults ->> 'key', v_existing.key),
        COALESCE(p_thread ->> 'icon', p_defaults ->> 'icon', v_existing.icon),
        v_twist_id,
        -- pending_contacts on the INSERT path starts empty; entries are added
        -- below only when the caller cannot attest themselves.
        ARRAY[]::uuid[],
        -- team_id: explicit from the caller (user-composed Note/Chat) or
        -- NULL for connector threads, which set_thread_team_and_external
        -- then defaults from the creating twist_instance.team_id.
        COALESCE((p_thread ->> 'team_id')::bigint, (p_defaults ->> 'team_id')::bigint),
        -- Content embedding for focus-matching / classification. The caller
        -- (prepareThreadForDb) computes it and passes it in p_defaults.embedding
        -- as the halfvec text form ("[0.1,...]"). Historically this column was
        -- omitted from the INSERT list, so every source-based (connector/twist)
        -- thread was created with a NULL embedding and never surfaced in
        -- "find matching threads".
        NULLIF(COALESCE(p_thread ->> 'embedding', p_defaults ->> 'embedding'), '')::halfvec,
        -- Thread-level assignee. Explicit caller value wins; otherwise default;
        -- otherwise preserve the existing row's assignee (archived-refile path).
        -- For connector threads the mirror trigger owns this column, so
        -- connectors that never send assignee_id leave it untouched here.
        COALESCE((p_thread ->> 'assignee_id')::uuid, (p_defaults ->> 'assignee_id')::uuid, v_existing.assignee_id),
        -- topic_id: the channel this thread belongs to. Written on INSERT;
        -- on update it is preserved unless the payload includes 'topic_id'
        -- (or the thread is re-filed from archive). See the ON CONFLICT clause.
        v_input_topic_id,
        -- Intrinsic facets (format/automation/reach) supplied by the connector
        -- via p_defaults.facets. Server-only classifier signal; never synced.
        COALESCE(p_thread -> 'facets', p_defaults -> 'facets')
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
            -- Immutable attribution: set once, never overwritten. A later sync
            -- (or the connector backfill sweep) may fill a NULL author, but can
            -- never re-attribute a thread that already has an author.
            author_id = COALESCE(thread.author_id, v_author_id),
            -- Additive contact merge. The union already includes existing +
            -- input + caller's own linked contacts.
            contacts = v_merged_contacts,
            -- Additive contact_meta merge: caller-provided entries (keyed by
            -- contact_id) override existing entries for the same contact;
            -- entries for contacts the caller didn't mention are preserved.
            -- Per-contact role changes / removals go through share_thread
            -- (POST /thread/:id/share), not through upsert_thread.
            -- jsonb_typeof guard: a literal `"contact_meta": null` is a JSONB
            -- 'null' (not SQL NULL), so it slips past COALESCE and the `||`
            -- merge would coerce object+null into `[{}, null]`, corrupting the
            -- column. Only merge real objects; null/array/scalar → no-op.
            contact_meta = CASE WHEN p_thread ? 'contact_meta' THEN
                COALESCE(thread.contact_meta, '{}'::jsonb)
                    || (CASE WHEN jsonb_typeof(p_thread -> 'contact_meta') = 'object'
                            THEN p_thread -> 'contact_meta'
                            ELSE '{}'::jsonb END)
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
            -- Present-key semantics: a client setting an assignee sends the
            -- key explicitly. Connectors never send assignee_id, so the mirror
            -- trigger remains the owner of connector-thread assignment.
            assignee_id = CASE WHEN p_thread ? 'assignee_id' THEN
                (p_thread ->> 'assignee_id')::uuid
            ELSE
                thread.assignee_id
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
            END,
            -- Persist/refresh the content embedding. On a normal update we keep
            -- the existing embedding unless the caller explicitly passes a new
            -- one in p_thread (so frequent connector re-syncs don't churn it);
            -- on the archived-refile path (treated like an insert) we repopulate
            -- from the caller, preserving the existing value if none was
            -- supplied. We never wipe an embedding we already have.
            embedding = CASE
                WHEN v_is_archived THEN
                    COALESCE(
                        NULLIF(COALESCE(p_thread ->> 'embedding', p_defaults ->> 'embedding'), '')::halfvec,
                        thread.embedding
                    )
                ELSE
                    CASE WHEN p_thread ? 'embedding'
                        THEN NULLIF(p_thread ->> 'embedding', '')::halfvec
                        ELSE thread.embedding
                    END
            END,
            topic_id = CASE WHEN v_is_archived THEN
                v_input_topic_id
            ELSE
                CASE WHEN p_thread ? 'topic_id' THEN v_input_topic_id ELSE thread.topic_id END
            END
            ,
            -- Fill facets only when the row has none yet (connector backfill on
            -- re-sync). Never churn an existing value; never wipe to null.
            facets = COALESCE(thread.facets, EXCLUDED.facets)
        RETURNING * INTO v_result;

    -- Attestation was already computed before the merge (see above). If the
    -- caller was attested, they file their own thread_priority row. Otherwise
    -- we record their primary contact in pending_contacts and defer filing.
    --
    -- LOCK ORDER INVARIANT — DO NOT BREAK:
    --   By the time we reach this INSERT, the thread INSERT/UPDATE at line
    --   359 has already fired the FOR EACH STATEMENT sync_user_for_thread
    --   trigger, which inserts user_sync rows for every user with a
    --   thread_priority on this thread. So our acquisition order is:
    --      thread row (line 359) → user_sync (statement trigger)
    --      → thread_priority (THIS INSERT) → user_sync (re-acquired via
    --        sync_user_for_thread_priority statement trigger; already held).
    --   Any other write path that touches both thread_priority and user_sync
    --   for the same thread MUST acquire them in the same relative order
    --   (thread → user_sync → thread_priority), or it will deadlock with
    --   this function under concurrency. See the matching invariant block
    --   in libs/db/schema/95-triggers/18-thread_topic_from_channel.sql.
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
-- Create "thread_x" view
CREATE VIEW "public"."thread_x" (
  "id",
  "created_at",
  "updated_at",
  "created_by",
  "author_id",
  "updated_by",
  "archived_at",
  "draft",
  "contacts",
  "dropped_contacts",
  "title",
  "preview",
  "last_note_created_at",
  "sync_depth",
  "last_note_source_created_at",
  "key",
  "icon",
  "assignee_id",
  "groups",
  "topic",
  "embedding",
  "twist_id",
  "topic_id",
  "pending_contacts",
  "contact_meta",
  "facets",
  "seq",
  "last_note_seq",
  "merged_into_thread_id",
  "team_id",
  "external_contacts"
) AS SELECT id,
    created_at,
    updated_at,
    created_by,
    author_id,
    updated_by,
    archived_at,
    draft,
    contacts,
    dropped_contacts,
    title,
    preview,
    last_note_created_at,
    sync_depth,
    last_note_source_created_at,
    key,
    icon,
    assignee_id,
    groups,
    topic,
    embedding,
    twist_id,
    topic_id,
    pending_contacts,
    contact_meta,
    facets,
    seq,
    last_note_seq,
    merged_into_thread_id,
    team_id,
    external_contacts
   FROM public.thread a;
