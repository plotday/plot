-- Modify "mark_reclassify_candidates" function
CREATE OR REPLACE FUNCTION "public"."mark_reclassify_candidates" ("p_user_id" uuid, "p_anchor_thread_id" uuid, "p_max_candidates" integer DEFAULT 500) RETURNS TABLE ("user_id" uuid, "thread_id" uuid) LANGUAGE plpgsql AS $$
DECLARE
    v_topic text;
    v_embedding halfvec;
    v_contacts uuid[];
    v_groups uuid[];
    v_own_contacts uuid[];
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

    -- Strip the user's own linked contacts from the anchor's contacts: the
    -- user appears in thread.contacts of every thread they can see, so
    -- leaving them in makes the contact-overlap branch match the whole
    -- workspace instead of "threads shared with the same people".
    v_own_contacts := "user".user_contact_ids(p_user_id);
    v_contacts := ARRAY(
        SELECT c
        FROM unnest(v_contacts) AS c
        WHERE c <> ALL (v_own_contacts)
    );

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
        SELECT id FROM (
            SELECT t.id
            FROM public.thread t
            JOIN public.thread_priority tp
              ON tp.thread_id = t.id
             AND tp.user_id = p_user_id
             AND tp.user_moved = FALSE
             AND tp.priority_id IS NOT NULL
             AND tp.classify_at IS NULL
            WHERE v_topic IS NOT NULL
              AND t.topic = v_topic
              AND t.archived_at IS NULL
              AND t.draft = FALSE
            ORDER BY t.created_at DESC
            LIMIT p_max_candidates
        ) topical

        UNION

        SELECT id FROM (
            SELECT t.id
            FROM public.thread t
            JOIN public.thread_priority tp
              ON tp.thread_id = t.id
             AND tp.user_id = p_user_id
             AND tp.user_moved = FALSE
             AND tp.priority_id IS NOT NULL
             AND tp.classify_at IS NULL
            WHERE v_embedding IS NOT NULL
              AND t.embedding IS NOT NULL
              AND (1 - (t.embedding <=> v_embedding)) >= 0.5
              AND t.archived_at IS NULL
              AND t.draft = FALSE
              -- Onboarding threads stay pinned to the Inbox: they're only
              -- ever dragged along the topic branch above (when the moved
              -- anchor is itself an 'onboarding' thread), never pulled out
              -- by similarity to some unrelated thread the user moved.
              AND t.topic IS DISTINCT FROM 'onboarding'
            ORDER BY t.embedding <=> v_embedding ASC
            LIMIT p_max_candidates
        ) semantic

        UNION

        SELECT id FROM (
            SELECT t.id
            FROM public.thread t
            JOIN public.thread_priority tp
              ON tp.thread_id = t.id
             AND tp.user_id = p_user_id
             AND tp.user_moved = FALSE
             AND tp.priority_id IS NOT NULL
             AND tp.classify_at IS NULL
            WHERE t.archived_at IS NULL
              AND t.draft = FALSE
              -- Onboarding threads only move via the topic branch (see above).
              AND t.topic IS DISTINCT FROM 'onboarding'
              AND (
                  (cardinality(v_contacts) > 0 AND t.contacts && v_contacts)
                  OR (cardinality(v_groups) > 0 AND t.groups && v_groups)
              )
            ORDER BY t.created_at DESC
            LIMIT p_max_candidates
        ) social
    )
    UPDATE public.thread_priority tp
    SET classify_at = now(),
        updated_at = now()
    FROM candidates c
    WHERE tp.thread_id = c.id
      AND tp.user_id = p_user_id
      AND tp.user_moved = FALSE
      AND tp.priority_id IS NOT NULL
      AND tp.classify_at IS NULL
      AND c.id IS DISTINCT FROM p_anchor_thread_id
    RETURNING tp.user_id, tp.thread_id;
END;
$$;
-- Create "merge_priority" function
CREATE FUNCTION "user"."merge_priority" ("user_id" uuid, "p_source_priority_id" uuid, "p_target_priority_id" uuid) RETURNS integer LANGUAGE plpgsql SET "search_path" = public, "user" AS $$
#variable_conflict use_column
DECLARE
    v_moved integer;
BEGIN
    IF p_source_priority_id = p_target_priority_id THEN
        RAISE EXCEPTION 'Cannot merge a focus into itself';
    END IF;

    -- Ownership checks: both focuses must belong to the calling user.
    IF NOT EXISTS (
        SELECT 1 FROM priority p
        WHERE p.id = p_source_priority_id
          AND p.user_id = merge_priority.user_id
    ) THEN
        RAISE EXCEPTION 'Source focus not found';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM priority p
        WHERE p.id = p_target_priority_id
          AND p.user_id = merge_priority.user_id
          AND p.archived_at IS NULL
    ) THEN
        RAISE EXCEPTION 'Target focus not found or archived';
    END IF;

    -- Re-file before archiving the source so no row ever observes an
    -- archived filing (effective_priority_id would bounce it to root).
    UPDATE thread_priority tp
    SET priority_id = p_target_priority_id
    WHERE tp.user_id = merge_priority.user_id
      AND tp.priority_id = p_source_priority_id;
    GET DIAGNOSTICS v_moved = ROW_COUNT;

    UPDATE priority p
    SET archived_at = now()
    WHERE p.id = p_source_priority_id
      AND p.user_id = merge_priority.user_id
      AND p.archived_at IS NULL;

    RETURN v_moved;
END;
$$;
-- Set comment to function: "merge_priority"
COMMENT ON FUNCTION "user"."merge_priority" IS 'Re-file all of one user''s thread filings from a source focus onto a target in a single statement, then archive the source. Replaces the client-side per-thread merge loop so a bulk merge generates no classifier-training signals and no retroactive reclassify sweeps.';
