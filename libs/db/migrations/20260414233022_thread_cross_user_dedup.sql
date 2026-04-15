-- Modify "thread" table
ALTER TABLE "public"."thread" ADD COLUMN "twist_id" bigint NULL, ADD COLUMN "pending_contacts" uuid[] NOT NULL DEFAULT ARRAY[]::uuid[];

-- Data migration: backfill thread.twist_id from twist_instance.twist_id via
-- created_by for twist-created threads. User-created threads keep twist_id
-- NULL and are excluded from the new partial unique index.
UPDATE thread t
SET twist_id = ti.twist_id
FROM twist_instance ti
WHERE t.created_by = ti.id
  AND t.twist_id IS NULL;

-- Data migration: dedupe threads with the same (twist_id, key) before the
-- new unique index is created. For each group, keep the oldest thread and
-- repoint all dependent rows at it; union contacts; delete the losers.
-- This resolves the cross-user duplication that accumulated under the
-- old per-creator uniqueness model (Alice's and Bob's connectors each
-- creating their own thread for the same external item).
WITH grouped AS (
    SELECT twist_id,
           key,
           array_agg(id ORDER BY created_at ASC) AS ids
    FROM thread
    WHERE twist_id IS NOT NULL
      AND key IS NOT NULL
      AND archived_at IS NULL
    GROUP BY twist_id, key
    HAVING count(*) > 1
),
ranked AS (
    SELECT
        ids[1] AS keep_id,
        (SELECT array_agg(id) FROM unnest(ids) WITH ORDINALITY AS u(id, ord) WHERE ord > 1) AS dup_ids
    FROM grouped
),
mapping AS (
    SELECT keep_id, unnest(dup_ids) AS dup_id
    FROM ranked
)
-- Merge contacts and pending_contacts from duplicates into the canonical thread.
UPDATE thread k
SET contacts = (
        SELECT COALESCE(array_agg(DISTINCT x), ARRAY[]::uuid[])
        FROM unnest(
            COALESCE(k.contacts, ARRAY[]::uuid[])
            || COALESCE((SELECT array_agg(c) FROM mapping m, unnest(d.contacts) c
                        WHERE m.keep_id = k.id AND d.id = m.dup_id), ARRAY[]::uuid[])
        ) AS x
    )
FROM thread d
JOIN mapping m ON m.dup_id = d.id
WHERE k.id = m.keep_id;

-- Repoint children at the canonical thread. Order matters: do this before
-- the duplicate thread rows are deleted by the final DELETE at the bottom.
WITH grouped AS (
    SELECT twist_id, key, array_agg(id ORDER BY created_at ASC) AS ids
    FROM thread
    WHERE twist_id IS NOT NULL AND key IS NOT NULL AND archived_at IS NULL
    GROUP BY twist_id, key HAVING count(*) > 1
),
mapping AS (
    SELECT ids[1] AS keep_id, u.id AS dup_id
    FROM grouped g, unnest(g.ids) WITH ORDINALITY AS u(id, ord)
    WHERE u.ord > 1
)
UPDATE note SET thread_id = m.keep_id
FROM mapping m
WHERE note.thread_id = m.dup_id;

WITH grouped AS (
    SELECT twist_id, key, array_agg(id ORDER BY created_at ASC) AS ids
    FROM thread
    WHERE twist_id IS NOT NULL AND key IS NOT NULL AND archived_at IS NULL
    GROUP BY twist_id, key HAVING count(*) > 1
),
mapping AS (
    SELECT ids[1] AS keep_id, u.id AS dup_id
    FROM grouped g, unnest(g.ids) WITH ORDINALITY AS u(id, ord)
    WHERE u.ord > 1
)
UPDATE link SET thread_id = m.keep_id
FROM mapping m
WHERE link.thread_id = m.dup_id;

WITH grouped AS (
    SELECT twist_id, key, array_agg(id ORDER BY created_at ASC) AS ids
    FROM thread
    WHERE twist_id IS NOT NULL AND key IS NOT NULL AND archived_at IS NULL
    GROUP BY twist_id, key HAVING count(*) > 1
),
mapping AS (
    SELECT ids[1] AS keep_id, u.id AS dup_id
    FROM grouped g, unnest(g.ids) WITH ORDINALITY AS u(id, ord)
    WHERE u.ord > 1
)
UPDATE schedule SET thread_id = m.keep_id
FROM mapping m
WHERE schedule.thread_id = m.dup_id;

-- thread_tag: move to canonical unless a conflicting row already exists.
WITH grouped AS (
    SELECT twist_id, key, array_agg(id ORDER BY created_at ASC) AS ids
    FROM thread
    WHERE twist_id IS NOT NULL AND key IS NOT NULL AND archived_at IS NULL
    GROUP BY twist_id, key HAVING count(*) > 1
),
mapping AS (
    SELECT ids[1] AS keep_id, u.id AS dup_id
    FROM grouped g, unnest(g.ids) WITH ORDINALITY AS u(id, ord)
    WHERE u.ord > 1
)
UPDATE thread_tag SET thread_id = m.keep_id
FROM mapping m
WHERE thread_tag.thread_id = m.dup_id
  AND NOT EXISTS (
      SELECT 1 FROM thread_tag existing
      WHERE existing.thread_id = m.keep_id
        AND existing.tag_id = thread_tag.tag_id
        AND existing.actor_id = thread_tag.actor_id
        AND existing.occurrence IS NOT DISTINCT FROM thread_tag.occurrence
  );

-- thread_priority: merge duplicates onto the canonical thread_id, preserving
-- the user's chosen priority (keep row with earliest created_at on conflict).
WITH grouped AS (
    SELECT twist_id, key, array_agg(id ORDER BY created_at ASC) AS ids
    FROM thread
    WHERE twist_id IS NOT NULL AND key IS NOT NULL AND archived_at IS NULL
    GROUP BY twist_id, key HAVING count(*) > 1
),
mapping AS (
    SELECT ids[1] AS keep_id, u.id AS dup_id
    FROM grouped g, unnest(g.ids) WITH ORDINALITY AS u(id, ord)
    WHERE u.ord > 1
)
UPDATE thread_priority tp SET thread_id = m.keep_id
FROM mapping m
WHERE tp.thread_id = m.dup_id
  AND NOT EXISTS (
      SELECT 1 FROM thread_priority existing
      WHERE existing.thread_id = m.keep_id AND existing.user_id = tp.user_id
  );

-- thread_unread: same pattern — move unless duplicate already exists for the user.
WITH grouped AS (
    SELECT twist_id, key, array_agg(id ORDER BY created_at ASC) AS ids
    FROM thread
    WHERE twist_id IS NOT NULL AND key IS NOT NULL AND archived_at IS NULL
    GROUP BY twist_id, key HAVING count(*) > 1
),
mapping AS (
    SELECT ids[1] AS keep_id, u.id AS dup_id
    FROM grouped g, unnest(g.ids) WITH ORDINALITY AS u(id, ord)
    WHERE u.ord > 1
)
UPDATE thread_unread tu SET thread_id = m.keep_id
FROM mapping m
WHERE tu.thread_id = m.dup_id
  AND NOT EXISTS (
      SELECT 1 FROM thread_unread existing
      WHERE existing.thread_id = m.keep_id AND existing.user_id = tu.user_id
  );

-- thread_read: same pattern.
WITH grouped AS (
    SELECT twist_id, key, array_agg(id ORDER BY created_at ASC) AS ids
    FROM thread
    WHERE twist_id IS NOT NULL AND key IS NOT NULL AND archived_at IS NULL
    GROUP BY twist_id, key HAVING count(*) > 1
),
mapping AS (
    SELECT ids[1] AS keep_id, u.id AS dup_id
    FROM grouped g, unnest(g.ids) WITH ORDINALITY AS u(id, ord)
    WHERE u.ord > 1
)
UPDATE thread_read tr SET thread_id = m.keep_id
FROM mapping m
WHERE tr.thread_id = m.dup_id
  AND NOT EXISTS (
      SELECT 1 FROM thread_read existing
      WHERE existing.thread_id = m.keep_id AND existing.user_id = tr.user_id
  );

-- Delete any thread_priority/thread_unread/thread_read rows that couldn't move
-- because of existing rows on the canonical thread.
WITH grouped AS (
    SELECT twist_id, key, array_agg(id ORDER BY created_at ASC) AS ids
    FROM thread
    WHERE twist_id IS NOT NULL AND key IS NOT NULL AND archived_at IS NULL
    GROUP BY twist_id, key HAVING count(*) > 1
),
mapping AS (
    SELECT ids[1] AS keep_id, u.id AS dup_id
    FROM grouped g, unnest(g.ids) WITH ORDINALITY AS u(id, ord)
    WHERE u.ord > 1
)
DELETE FROM thread_priority WHERE thread_id IN (SELECT dup_id FROM mapping);

WITH grouped AS (
    SELECT twist_id, key, array_agg(id ORDER BY created_at ASC) AS ids
    FROM thread
    WHERE twist_id IS NOT NULL AND key IS NOT NULL AND archived_at IS NULL
    GROUP BY twist_id, key HAVING count(*) > 1
),
mapping AS (
    SELECT ids[1] AS keep_id, u.id AS dup_id
    FROM grouped g, unnest(g.ids) WITH ORDINALITY AS u(id, ord)
    WHERE u.ord > 1
)
DELETE FROM thread_unread WHERE thread_id IN (SELECT dup_id FROM mapping);

WITH grouped AS (
    SELECT twist_id, key, array_agg(id ORDER BY created_at ASC) AS ids
    FROM thread
    WHERE twist_id IS NOT NULL AND key IS NOT NULL AND archived_at IS NULL
    GROUP BY twist_id, key HAVING count(*) > 1
),
mapping AS (
    SELECT ids[1] AS keep_id, u.id AS dup_id
    FROM grouped g, unnest(g.ids) WITH ORDINALITY AS u(id, ord)
    WHERE u.ord > 1
)
DELETE FROM thread_read WHERE thread_id IN (SELECT dup_id FROM mapping);

WITH grouped AS (
    SELECT twist_id, key, array_agg(id ORDER BY created_at ASC) AS ids
    FROM thread
    WHERE twist_id IS NOT NULL AND key IS NOT NULL AND archived_at IS NULL
    GROUP BY twist_id, key HAVING count(*) > 1
),
mapping AS (
    SELECT ids[1] AS keep_id, u.id AS dup_id
    FROM grouped g, unnest(g.ids) WITH ORDINALITY AS u(id, ord)
    WHERE u.ord > 1
)
DELETE FROM thread_tag WHERE thread_id IN (SELECT dup_id FROM mapping);

-- Finally drop the duplicate thread rows.
WITH grouped AS (
    SELECT twist_id, key, array_agg(id ORDER BY created_at ASC) AS ids
    FROM thread
    WHERE twist_id IS NOT NULL AND key IS NOT NULL AND archived_at IS NULL
    GROUP BY twist_id, key HAVING count(*) > 1
),
mapping AS (
    SELECT ids[1] AS keep_id, u.id AS dup_id
    FROM grouped g, unnest(g.ids) WITH ORDINALITY AS u(id, ord)
    WHERE u.ord > 1
)
DELETE FROM thread WHERE id IN (SELECT dup_id FROM mapping);

-- Create index "thread_twist_key_unique" to table: "thread"
CREATE UNIQUE INDEX "thread_twist_key_unique" ON "public"."thread" ("twist_id", "key") WHERE ((twist_id IS NOT NULL) AND (key IS NOT NULL) AND (archived_at IS NULL));
-- Set comment to column: "key" on table: "thread"
COMMENT ON COLUMN "public"."thread"."key" IS 'Identifier for cross-user deduplication within a twist. Scoped by twist_id via thread_twist_key_unique. Not synced to clients.';
-- Set comment to column: "contacts" on table: "thread"
COMMENT ON COLUMN "public"."thread"."contacts" IS 'Attested contact_ids on this thread. For twist-created threads, a user only gains visibility when their linked contact appears here via another attester''s sync (or via share_thread). Users who attempted to join before attestation land in pending_contacts and are promoted when an attester confirms them. User-created threads do not require attestation.';
-- Set comment to column: "twist_id" on table: "thread"
COMMENT ON COLUMN "public"."thread"."twist_id" IS 'Twist definition that created this thread. Scopes (twist_id, key) dedup so all instances of the same twist share the same thread per external item. Immutable after creation.';
-- Set comment to column: "pending_contacts" on table: "thread"
COMMENT ON COLUMN "public"."thread"."pending_contacts" IS 'Contacts whose own sync wants to join but who have not yet been attested by another user''s sync. Promoted to contacts (with thread_priority filing) once a subsequent attester includes them.';
-- Modify "thread_priority" table
ALTER TABLE "public"."thread_priority" ADD COLUMN "archived_at" timestamptz NULL;
-- Create index "idx_thread_priority_archived" to table: "thread_priority"
CREATE INDEX "idx_thread_priority_archived" ON "public"."thread_priority" ("thread_id") WHERE (archived_at IS NULL);
-- Modify "file_thread_priority_peers" function
CREATE OR REPLACE FUNCTION "public"."file_thread_priority_peers" () RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    r RECORD;
    v_peer_priority_id uuid;
    v_author_user_id uuid;
    v_old_contacts uuid[];
BEGIN
    IF NEW.contacts IS NULL OR cardinality(NEW.contacts) = 0 THEN
        RETURN NEW;
    END IF;

    -- Only auto-file peers for user-authored threads. For twist-authored
    -- threads, filing happens exclusively through each user's own
    -- upsert_thread call (which promotes them from pending_contacts).
    IF NOT EXISTS (SELECT 1 FROM "public"."user" WHERE id = NEW.created_by) THEN
        RETURN NEW;
    END IF;
    v_author_user_id := NEW.created_by;

    -- Compute old contacts for delta (empty on INSERT).
    IF TG_OP = 'UPDATE' THEN
        v_old_contacts := COALESCE(OLD.contacts, ARRAY[]::uuid[]);
    ELSE
        v_old_contacts := ARRAY[]::uuid[];
    END IF;

    -- thread_priority for ALL contacts (idempotent via ON CONFLICT DO NOTHING).
    FOR r IN
        SELECT DISTINCT uc.user_id AS peer_user_id
        FROM unnest(NEW.contacts) AS arr(contact_id)
        JOIN public.user_contact uc
          ON uc.contact_id = arr.contact_id
         AND uc.linked = TRUE
         AND uc.archived_at IS NULL
        WHERE uc.user_id IS DISTINCT FROM v_author_user_id
    LOOP
        v_peer_priority_id := public.classify_thread_for_user(r.peer_user_id, NEW.id);
        IF v_peer_priority_id IS NOT NULL THEN
            INSERT INTO thread_priority (thread_id, user_id, priority_id)
            VALUES (NEW.id, r.peer_user_id, v_peer_priority_id)
            ON CONFLICT ON CONSTRAINT thread_priority_pkey DO NOTHING;
        END IF;
    END LOOP;

    -- thread_unread for NEWLY ADDED contacts only, so shared threads appear
    -- as unread for peers. ON CONFLICT DO NOTHING preserves read state.
    FOR r IN
        SELECT DISTINCT uc.user_id AS peer_user_id
        FROM unnest(NEW.contacts) AS arr(contact_id)
        JOIN public.user_contact uc
          ON uc.contact_id = arr.contact_id
         AND uc.linked = TRUE
         AND uc.archived_at IS NULL
        WHERE uc.user_id IS DISTINCT FROM v_author_user_id
          AND arr.contact_id != ALL(v_old_contacts)
    LOOP
        INSERT INTO thread_unread (user_id, thread_id, urgency, importance)
        VALUES (r.peer_user_id, NEW.id, 'inform-updates', 50)
        ON CONFLICT (user_id, thread_id) DO NOTHING;
    END LOOP;

    RETURN NEW;
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
    -- Input topics normalized.
    v_input_topics uuid[];
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

    -- Normalize caller-provided contacts and topics to uuid[].
    v_input_contacts := CASE
        WHEN p_thread ? 'contacts' AND jsonb_typeof(p_thread -> 'contacts') = 'array' THEN
            COALESCE((SELECT array_agg(elem::uuid) FROM jsonb_array_elements_text(p_thread -> 'contacts') elem), ARRAY[]::uuid[])
        WHEN p_defaults ? 'contacts' AND jsonb_typeof(p_defaults -> 'contacts') = 'array' THEN
            COALESCE((SELECT array_agg(elem::uuid) FROM jsonb_array_elements_text(p_defaults -> 'contacts') elem), ARRAY[]::uuid[])
        ELSE ARRAY[]::uuid[]
    END;

    v_input_topics := CASE
        WHEN p_thread ? 'topics' AND jsonb_typeof(p_thread -> 'topics') = 'array' THEN
            COALESCE((SELECT array_agg(elem::uuid) FROM jsonb_array_elements_text(p_thread -> 'topics') elem), ARRAY[]::uuid[])
        WHEN p_defaults ? 'topics' AND jsonb_typeof(p_defaults -> 'topics') = 'array' THEN
            COALESCE((SELECT array_agg(elem::uuid) FROM jsonb_array_elements_text(p_defaults -> 'topics') elem), ARRAY[]::uuid[])
        ELSE COALESCE(v_existing.topics, ARRAY[]::uuid[])
    END;

    -- Additive merge: the new contact set is the union of the existing
    -- contacts, the caller-provided contacts, and the caller's own linked
    -- contacts. Removal is only possible via share_thread.
    SELECT COALESCE(array_agg(DISTINCT x), ARRAY[]::uuid[])
    INTO v_merged_contacts
    FROM unnest(
        COALESCE(v_existing.contacts, ARRAY[]::uuid[])
        || v_input_contacts
        || v_user_contacts
    ) AS x;

    -- Identify contacts being promoted from pending_contacts on this call.
    -- A contact is promoted when the caller-provided contacts include a
    -- contact currently in pending_contacts.
    IF v_existing.pending_contacts IS NOT NULL AND cardinality(v_existing.pending_contacts) > 0 THEN
        SELECT COALESCE(array_agg(DISTINCT p), ARRAY[]::uuid[])
        INTO v_promoted_contacts
        FROM unnest(v_existing.pending_contacts) AS p
        WHERE p = ANY(v_input_contacts);
    ELSE
        v_promoted_contacts := ARRAY[]::uuid[];
    END IF;

    -- Perform the upsert. twist_id is set only on the insert path; the update
    -- path preserves thread.twist_id so first-creator wins.
    INSERT INTO thread (
        id, created_by, title, preview, updated_by, sync_depth, contacts, topics,
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
        v_input_topics,
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
            topics = CASE WHEN v_is_archived THEN
                v_input_topics
            ELSE
                CASE WHEN p_thread ? 'topics' THEN
                    v_input_topics
                ELSE
                    thread.topics
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

    -- Decide whether the caller is attested on this thread.
    --   - user-created thread (v_created_by = user_id) with no twist_id:
    --     always attested (we trust user-driven flows and share_thread).
    --   - twist-created thread: attested iff at least one of the caller's
    --     linked contacts is in thread.contacts after the merge.
    v_caller_attested := (v_created_by = upsert_thread.user_id AND v_result.twist_id IS NULL)
        OR (v_user_contacts && v_result.contacts);

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
                    ON CONFLICT (user_id, thread_id) DO NOTHING;
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
-- Modify "thread_x" view
CREATE OR REPLACE VIEW "public"."thread_x" (
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
  "topics",
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
    topics,
    embedding,
    twist_id,
    pending_contacts
   FROM public.thread a;
