-- Drop "channel" view
DROP VIEW "user"."channel";
-- Modify "thread_priority" table
ALTER TABLE "public"."thread_priority" ADD COLUMN "applied_default_channel_id" bigint NULL;
-- Create index "idx_thread_priority_applied_default" to table: "thread_priority"
CREATE INDEX "idx_thread_priority_applied_default" ON "public"."thread_priority" ("applied_default_channel_id") WHERE (applied_default_channel_id IS NOT NULL);
-- Modify "classify_thread_for_user" function
CREATE OR REPLACE FUNCTION "public"."classify_thread_for_user" ("p_user_id" uuid, "p_thread_id" uuid DEFAULT NULL::uuid, "p_embedding" public.halfvec DEFAULT NULL::public.halfvec, "p_topic" text DEFAULT NULL::text, "p_contacts" uuid[] DEFAULT NULL::uuid[], "p_groups" uuid[] DEFAULT NULL::uuid[]) RETURNS uuid LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_embedding halfvec;
    v_topic text;
    v_contacts uuid[];
    v_groups uuid[];
    v_matched uuid;
BEGIN
    -- 1. Load thread signals when an id was supplied.
    IF p_thread_id IS NOT NULL THEN
        SELECT t.embedding, t.topic, t.contacts, t.groups
        INTO v_embedding, v_topic, v_contacts, v_groups
        FROM public.thread t
        WHERE t.id = p_thread_id;
    END IF;

    v_embedding := COALESCE(p_embedding, v_embedding);
    v_topic     := COALESCE(p_topic, v_topic);
    v_contacts  := COALESCE(p_contacts, v_contacts, ARRAY[]::uuid[]);
    v_groups    := COALESCE(p_groups, v_groups, ARRAY[]::uuid[]);

    -- 2. Topic short-circuit. When the user has moved threads carrying the
    --    same topic, that's a direct statement about where same-topic threads
    --    belong — return the mode of those priorities. Ties broken by the
    --    most recently updated thread_priority row.
    IF v_topic IS NOT NULL THEN
        SELECT tp.priority_id INTO v_matched
        FROM public.thread_priority tp
        JOIN public.thread mt ON mt.id = tp.thread_id
        WHERE tp.user_id = p_user_id
          AND tp.user_moved = TRUE
          AND mt.archived_at IS NULL
          AND mt.topic = v_topic
        GROUP BY tp.priority_id
        ORDER BY COUNT(*) DESC, MAX(tp.updated_at) DESC
        LIMIT 1;
        IF v_matched IS NOT NULL THEN
            RETURN v_matched;
        END IF;
    END IF;

    -- 2.5. Channel default. When the thread topic is of the form
    --      'channel:<pk>' and the channel has a non-archived
    --      default_priority_id, return it. This is the LLM-assigned default
    --      that kicks in before scoring. Step 2 (user_moved topic match)
    --      ran first, so a user move will always trump the default.
    IF v_topic LIKE 'channel:%' THEN
        DECLARE
            v_channel_pk bigint;
        BEGIN
            v_channel_pk := NULLIF(substring(v_topic FROM 9), '')::bigint;
            IF v_channel_pk IS NOT NULL THEN
                SELECT c.default_priority_id INTO v_matched
                FROM public.channel c
                JOIN public.priority p ON p.id = c.default_priority_id
                WHERE c.id = v_channel_pk
                  AND c.default_priority_id IS NOT NULL
                  AND p.user_id = p_user_id
                  AND p.archived_at IS NULL;
                IF v_matched IS NOT NULL THEN
                    RETURN v_matched;
                END IF;
            END IF;
        EXCEPTION WHEN invalid_text_representation THEN
            -- Topic looked like 'channel:...' but the suffix wasn't numeric.
            -- Fall through to scoring.
            NULL;
        END;
    END IF;

    -- 3. Score all moved threads when no topic match was available.
    WITH moved AS (
        -- Every thread this user has explicitly moved. Read CURRENT signals
        -- from the thread row so relinking aliases / group edits take effect
        -- without a rule rewrite.
        SELECT tp.priority_id,
               mt.embedding,
               mt.contacts,
               mt.groups
        FROM public.thread_priority tp
        JOIN public.thread mt ON mt.id = tp.thread_id
        WHERE tp.user_id = p_user_id
          AND tp.user_moved = TRUE
          AND mt.archived_at IS NULL
    ),
    -- Pre-expand contacts once per side to avoid recomputation per candidate.
    candidate AS (
        SELECT public.expand_contacts(v_contacts) AS exp_contacts,
               v_groups AS groups,
               v_embedding AS embedding
    ),
    scored AS (
        SELECT
            f.priority_id,
            -- Semantic: cosine sim thresholded at 0.5, scaled to [0,1], squared.
            CASE
                WHEN f.embedding IS NULL OR c.embedding IS NULL THEN 0
                ELSE POWER(
                    GREATEST(0, (1 - (f.embedding <=> c.embedding)) - 0.5) * 2,
                    2
                )
            END AS sem,
            -- Contacts: Jaccard on expanded sets, squared.
            CASE
                WHEN cardinality(f.contacts) = 0 OR cardinality(c.exp_contacts) = 0 THEN 0
                ELSE POWER(
                    cardinality(ARRAY(
                        SELECT unnest(public.expand_contacts(f.contacts))
                        INTERSECT
                        SELECT unnest(c.exp_contacts)
                    ))::numeric
                    / NULLIF(cardinality(ARRAY(
                        SELECT unnest(public.expand_contacts(f.contacts))
                        UNION
                        SELECT unnest(c.exp_contacts)
                    )), 0),
                    2
                )
            END AS con,
            -- Groups: Jaccard (raw, not expanded), squared.
            CASE
                WHEN cardinality(f.groups) = 0 OR cardinality(c.groups) = 0 THEN 0
                ELSE POWER(
                    cardinality(ARRAY(
                        SELECT unnest(f.groups) INTERSECT SELECT unnest(c.groups)
                    ))::numeric
                    / NULLIF(cardinality(ARRAY(
                        SELECT unnest(f.groups) UNION SELECT unnest(c.groups)
                    )), 0),
                    2
                )
            END AS grp
        FROM moved f
        CROSS JOIN candidate c
    )
    SELECT priority_id INTO v_matched
    FROM scored
    WHERE (0.5 * sem + 0.35 * con + 0.15 * grp) >= 0.15
    ORDER BY (0.5 * sem + 0.35 * con + 0.15 * grp) DESC
    LIMIT 1;

    IF v_matched IS NOT NULL THEN
        RETURN v_matched;
    END IF;

    -- priority:{KEY}[:{SUB_TOPIC}] topic prefix — caller-specified default
    -- routing. Only reached when no user_moved example beat the score floor,
    -- so the user's own moves (same full topic string) always win.
    IF v_topic LIKE 'priority:%' THEN
        DECLARE
            v_priority_key text := split_part(v_topic, ':', 2);
        BEGIN
            IF v_priority_key <> '' THEN
                SELECT p.id INTO v_matched
                FROM public.priority p
                WHERE p.user_id = p_user_id
                  AND p.key = v_priority_key
                  AND p.archived_at IS NULL
                LIMIT 1;
                IF v_matched IS NOT NULL THEN
                    RETURN v_matched;
                END IF;
            END IF;
        END;
    END IF;

    -- Fallback: user's oldest non-archived root priority.
    SELECT p.id INTO v_matched
    FROM public.priority p
    WHERE p.user_id = p_user_id
      AND nlevel(p.path) = 1
      AND p.archived_at IS NULL
    ORDER BY p.created_at ASC
    LIMIT 1;

    RETURN v_matched;
END;
$$;
-- Set comment to function: "classify_thread_for_user"
COMMENT ON FUNCTION "public"."classify_thread_for_user" IS 'Classify a thread into a priority. Order: (1) topic short-circuit on user_moved siblings, (2) channel.default_priority_id when topic is ''channel:<pk>'', (3) semantic/contact/group scoring against user_moved examples, (4) priority:{KEY} prefix, (5) root priority fallback.';
-- Create "channel_default_marker" function
CREATE FUNCTION "public"."channel_default_marker" ("p_user_id" uuid, "p_thread_id" uuid, "p_priority_id" uuid) RETURNS bigint LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_topic text;
    v_channel_pk bigint;
    v_default_id uuid;
BEGIN
    IF p_user_id IS NULL OR p_thread_id IS NULL OR p_priority_id IS NULL THEN
        RETURN NULL;
    END IF;

    SELECT t.topic INTO v_topic
    FROM public.thread t
    WHERE t.id = p_thread_id;

    IF v_topic IS NULL OR v_topic NOT LIKE 'channel:%' THEN
        RETURN NULL;
    END IF;

    BEGIN
        v_channel_pk := NULLIF(substring(v_topic FROM 9), '')::bigint;
    EXCEPTION WHEN invalid_text_representation THEN
        RETURN NULL;
    END;

    IF v_channel_pk IS NULL THEN
        RETURN NULL;
    END IF;

    SELECT c.default_priority_id INTO v_default_id
    FROM public.channel c
    JOIN public.twist_instance ti ON ti.id = c.twist_instance_id
    WHERE c.id = v_channel_pk
      AND ti.owner_id = p_user_id;

    IF v_default_id IS NOT NULL AND v_default_id = p_priority_id THEN
        RETURN v_channel_pk;
    END IF;

    RETURN NULL;
END;
$$;
-- Set comment to function: "channel_default_marker"
COMMENT ON FUNCTION "public"."channel_default_marker" IS 'Return the channel pk if proposing to place (p_thread_id, p_user_id) at p_priority_id would land at the channel''s default_priority_id for this user, else NULL. Used by every writer of thread_priority.applied_default_channel_id.';
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
    -- Each peer classifies against their own channels — channel_default_marker
    -- only stamps when the peer themselves owns the channel with this topic
    -- and its default matches the chosen priority.
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
            INSERT INTO thread_priority (thread_id, user_id, priority_id, applied_default_channel_id)
            VALUES (
                NEW.id,
                r.peer_user_id,
                v_peer_priority_id,
                public.channel_default_marker (
                    r.peer_user_id, NEW.id, v_peer_priority_id
                )
            )
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
-- Modify "reclassify_user_threads" function
CREATE OR REPLACE FUNCTION "public"."reclassify_user_threads" ("p_user_id" uuid, "p_anchor_thread_id" uuid, "p_max_candidates" integer DEFAULT 500) RETURNS integer LANGUAGE plpgsql AS $$
DECLARE
    v_topic text;
    v_embedding halfvec;
    v_contacts uuid[];
    v_groups uuid[];
    v_moved_count int;
BEGIN
    SELECT t.topic, t.embedding, t.contacts, t.groups
    INTO v_topic, v_embedding, v_contacts, v_groups
    FROM public.thread t
    WHERE t.id = p_anchor_thread_id;

    IF NOT FOUND THEN
        RETURN 0;
    END IF;

    -- No-op when the user has no training examples yet. classify would
    -- otherwise fall back to root for every candidate, yanking currently-
    -- well-placed threads into the root priority with no real signal.
    IF NOT EXISTS (
        SELECT 1 FROM public.thread_priority tp
        WHERE tp.user_id = p_user_id AND tp.user_moved = TRUE
    ) THEN
        RETURN 0;
    END IF;

    WITH candidates AS (
        -- Topic equality (idx_thread_topic partial index).
        SELECT t.id
        FROM public.thread t
        JOIN public.thread_priority tp
          ON tp.thread_id = t.id
         AND tp.user_id = p_user_id
         AND tp.user_moved = FALSE
        WHERE v_topic IS NOT NULL
          AND t.topic = v_topic
          AND t.archived_at IS NULL
          AND t.draft = FALSE

        UNION

        -- Semantic nearest-neighbor (HNSW idx_thread_embedding), bounded.
        SELECT id FROM (
            SELECT t.id, (t.embedding <=> v_embedding) AS dist
            FROM public.thread t
            JOIN public.thread_priority tp
              ON tp.thread_id = t.id
             AND tp.user_id = p_user_id
             AND tp.user_moved = FALSE
            WHERE v_embedding IS NOT NULL
              AND t.embedding IS NOT NULL
              AND (1 - (t.embedding <=> v_embedding)) >= 0.5
              AND t.archived_at IS NULL
              AND t.draft = FALSE
            ORDER BY t.embedding <=> v_embedding ASC
            LIMIT p_max_candidates
        ) semantic

        UNION

        -- Contact / group overlap (GIN idx_thread_contacts, idx_thread_groups).
        SELECT t.id
        FROM public.thread t
        JOIN public.thread_priority tp
          ON tp.thread_id = t.id
         AND tp.user_id = p_user_id
         AND tp.user_moved = FALSE
        WHERE t.archived_at IS NULL
          AND t.draft = FALSE
          AND (
              (cardinality(v_contacts) > 0 AND t.contacts && v_contacts)
              OR (cardinality(v_groups) > 0 AND t.groups && v_groups)
          )
    ),
    reclass AS (
        SELECT c.id AS thread_id,
               public.classify_thread_for_user(p_user_id, c.id) AS new_priority_id
        FROM candidates c
        WHERE c.id IS DISTINCT FROM p_anchor_thread_id
    ),
    updated AS (
        UPDATE public.thread_priority tp
        SET priority_id = r.new_priority_id,
            applied_default_channel_id = public.channel_default_marker (
                p_user_id, r.thread_id, r.new_priority_id
            ),
            updated_at = now()
        FROM reclass r
        WHERE tp.thread_id = r.thread_id
          AND tp.user_id = p_user_id
          AND tp.user_moved = FALSE
          AND r.new_priority_id IS NOT NULL
          AND r.new_priority_id IS DISTINCT FROM tp.priority_id
        RETURNING 1
    )
    SELECT COUNT(*) INTO v_moved_count FROM updated;

    RETURN v_moved_count;
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

    -- prepareThreadForDb classifies the new thread before the link row exists,
    -- so the topic short-circuit had nothing to match. Now that topic is set,
    -- re-classify any thread_priority row that the user has not explicitly
    -- moved. user_moved = TRUE rows are sticky and are never overwritten.
    -- Also stamp applied_default_channel_id when the new priority matches
    -- this channel's default — the marker lets apply_channel_default find
    -- the row later when the default changes again.
    UPDATE public.thread_priority tp
    SET priority_id = classified.new_priority_id,
        applied_default_channel_id = public.channel_default_marker (
            tp.user_id, NEW.thread_id, classified.new_priority_id
        ),
        updated_at = now()
    FROM (
        SELECT
            tp2.user_id,
            tp2.thread_id,
            tp2.priority_id AS current_priority_id,
            tp2.applied_default_channel_id AS current_marker,
            public.classify_thread_for_user(tp2.user_id, NEW.thread_id) AS new_priority_id
        FROM public.thread_priority tp2
        WHERE tp2.thread_id = NEW.thread_id
          AND tp2.user_moved = FALSE
    ) classified
    WHERE tp.thread_id = classified.thread_id
      AND tp.user_id = classified.user_id
      AND tp.user_moved = FALSE
      AND (
          classified.new_priority_id IS DISTINCT FROM classified.current_priority_id
          OR public.channel_default_marker (
                 tp.user_id, NEW.thread_id, classified.new_priority_id
             ) IS DISTINCT FROM classified.current_marker
      );

    RETURN NEW;
END;
$$;
-- Create "apply_channel_default" function
CREATE FUNCTION "public"."apply_channel_default" ("p_channel_id" bigint) RETURNS integer LANGUAGE plpgsql AS $$
DECLARE
    v_owner_id uuid;
    v_root_id uuid;
    v_updated int;
BEGIN
    SELECT ti.owner_id
    INTO v_owner_id
    FROM public.channel c
    JOIN public.twist_instance ti ON ti.id = c.twist_instance_id
    WHERE c.id = p_channel_id;

    IF v_owner_id IS NULL THEN
        RETURN 0;
    END IF;

    SELECT p.id INTO v_root_id
    FROM public.priority p
    WHERE p.user_id = v_owner_id
      AND nlevel(p.path) = 1
      AND p.archived_at IS NULL
    ORDER BY p.created_at ASC
    LIMIT 1;

    WITH candidates AS (
        SELECT tp.thread_id, tp.user_id
        FROM public.thread_priority tp
        WHERE tp.applied_default_channel_id = p_channel_id
          AND tp.user_id = v_owner_id
          AND tp.user_moved = FALSE

        UNION

        SELECT tp.thread_id, tp.user_id
        FROM public.thread_priority tp
        JOIN public.thread t ON t.id = tp.thread_id
        WHERE tp.user_id = v_owner_id
          AND tp.user_moved = FALSE
          AND tp.priority_id = v_root_id
          AND t.topic = 'channel:' || p_channel_id::text
          AND t.archived_at IS NULL
    ),
    reclass AS (
        SELECT c.thread_id,
               c.user_id,
               public.classify_thread_for_user(c.user_id, c.thread_id) AS new_priority_id
        FROM candidates c
    ),
    updated AS (
        UPDATE public.thread_priority tp
        SET priority_id = r.new_priority_id,
            applied_default_channel_id = public.channel_default_marker (
                r.user_id, r.thread_id, r.new_priority_id
            ),
            updated_at = now()
        FROM reclass r
        WHERE tp.thread_id = r.thread_id
          AND tp.user_id = r.user_id
          AND tp.user_moved = FALSE
          AND r.new_priority_id IS NOT NULL
          AND (
              r.new_priority_id IS DISTINCT FROM tp.priority_id
              OR public.channel_default_marker (
                     r.user_id, r.thread_id, r.new_priority_id
                 ) IS DISTINCT FROM tp.applied_default_channel_id
          )
        RETURNING 1
    )
    SELECT COUNT(*) INTO v_updated FROM updated;

    RETURN v_updated;
END;
$$;
-- Set comment to function: "apply_channel_default"
COMMENT ON FUNCTION "public"."apply_channel_default" IS 'Re-file threads after a channel''s default_priority_id changes. Walks candidates tagged with applied_default_channel_id = p_channel_id plus root-filed threads whose topic matches this channel, re-runs classify_thread_for_user, and updates priority_id + applied_default_channel_id. Never touches rows with user_moved = TRUE.';
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
-- Modify "channel" table
ALTER TABLE "public"."channel" ADD COLUMN "default_priority_id" uuid NULL, ADD COLUMN "default_priority_reason" text NULL, ADD CONSTRAINT "channel_default_priority_id_fkey" FOREIGN KEY ("default_priority_id") REFERENCES "public"."priority" ("id") ON UPDATE NO ACTION ON DELETE SET NULL;
-- Create "channel" view
CREATE VIEW "user"."channel" (
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
  "updated_at"
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
    sc.updated_at
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
    sc.updated_at
   FROM public.channel sc
     JOIN public.link l ON l.channel_id = sc.channel_id AND l.created_by = sc.twist_instance_id
     JOIN public.thread_priority tp ON tp.thread_id = l.thread_id
     JOIN public.twist_instance pt ON pt.id = sc.twist_instance_id
  WHERE tp.user_id <> pt.owner_id;
