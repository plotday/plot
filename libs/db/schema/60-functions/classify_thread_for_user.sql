-- Classify a thread into a priority for a specific user by evaluating
-- their priority_rules in precedence order:
--   1. content  — cosine similarity ≥ 0.7 against rule embedding
--   2. contact_topics — any overlap in topics or contacts
--   3. channel  — catch-all default for the channel
--   4. fallback — user's root priority
--
-- Accepts either an existing thread_id (reads data from DB) or raw
-- parameters for pre-insert classification.  Override parameters take
-- precedence when provided (non-NULL).
CREATE OR REPLACE FUNCTION public.classify_thread_for_user (
    p_user_id uuid,
    p_thread_id uuid DEFAULT NULL,
    p_embedding halfvec DEFAULT NULL,
    p_topics uuid[] DEFAULT NULL,
    p_contacts uuid[] DEFAULT NULL,
    p_channel_id bigint DEFAULT NULL
)
    RETURNS uuid
    LANGUAGE plpgsql
    AS $function$
DECLARE
    v_embedding halfvec;
    v_topics uuid[];
    v_contacts uuid[];
    v_channel_id bigint;
    v_matched_priority_id uuid;
    v_root_priority_id uuid;
BEGIN
    -- 1. Load thread data from DB when thread exists, then apply overrides.
    IF p_thread_id IS NOT NULL THEN
        SELECT t.embedding, t.topics, t.contacts
        INTO v_embedding, v_topics, v_contacts
        FROM public.thread t
        WHERE t.id = p_thread_id;
    END IF;

    v_embedding := COALESCE(p_embedding, v_embedding);
    v_topics    := COALESCE(p_topics, v_topics, ARRAY[]::uuid[]);
    v_contacts  := COALESCE(p_contacts, v_contacts, ARRAY[]::uuid[]);

    -- 2. Resolve channel.
    --    Explicit override wins; otherwise derive from the thread's links.
    IF p_channel_id IS NOT NULL THEN
        v_channel_id := p_channel_id;
    ELSIF p_thread_id IS NOT NULL THEN
        SELECT c.id INTO v_channel_id
        FROM public.link l
        JOIN public.channel c
            ON c.twist_instance_id = l.created_by
           AND c.channel_id = l.channel_id
        WHERE l.thread_id = p_thread_id
          AND l.channel_id IS NOT NULL
        ORDER BY l.created_at DESC
        LIMIT 1;
    END IF;

    -- 3a. Content rules (highest precedence).
    IF v_embedding IS NOT NULL THEN
        SELECT pr.priority_id INTO v_matched_priority_id
        FROM public.priority_rule pr
        WHERE pr.user_id = p_user_id
          AND pr.type = 'content'
          AND pr.channel_id IS NOT DISTINCT FROM v_channel_id
          AND pr.embedding IS NOT NULL
          AND (1 - (pr.embedding <=> v_embedding)) >= 0.7
        ORDER BY (1 - (pr.embedding <=> v_embedding)) DESC
        LIMIT 1;

        IF v_matched_priority_id IS NOT NULL THEN
            RETURN v_matched_priority_id;
        END IF;
    END IF;

    -- 3b. Contact / topic rules.
    IF cardinality(v_topics) > 0 OR cardinality(v_contacts) > 0 THEN
        SELECT pr.priority_id INTO v_matched_priority_id
        FROM public.priority_rule pr
        WHERE pr.user_id = p_user_id
          AND pr.type = 'contact_topics'
          AND pr.channel_id IS NOT DISTINCT FROM v_channel_id
          AND (
              (pr.criteria ? 'topics'
                  AND v_topics && ARRAY(
                      SELECT jsonb_array_elements_text(pr.criteria -> 'topics')
                  )::uuid[])
              OR
              (pr.criteria ? 'contacts'
                  AND v_contacts && ARRAY(
                      SELECT jsonb_array_elements_text(pr.criteria -> 'contacts')
                  )::uuid[])
          )
        ORDER BY pr.created_at ASC
        LIMIT 1;

        IF v_matched_priority_id IS NOT NULL THEN
            RETURN v_matched_priority_id;
        END IF;
    END IF;

    -- 3c. Channel rule (lowest precedence, catch-all for a channel).
    IF v_channel_id IS NOT NULL THEN
        SELECT pr.priority_id INTO v_matched_priority_id
        FROM public.priority_rule pr
        WHERE pr.user_id = p_user_id
          AND pr.type = 'channel'
          AND pr.channel_id = v_channel_id
        ORDER BY pr.created_at ASC
        LIMIT 1;

        IF v_matched_priority_id IS NOT NULL THEN
            RETURN v_matched_priority_id;
        END IF;
    END IF;

    -- 4. Fall back to the user's root priority.
    SELECT p.id INTO v_root_priority_id
    FROM public.priority p
    WHERE p.user_id = p_user_id
      AND nlevel(p.path) = 1
      AND p.archived_at IS NULL
    ORDER BY p.created_at ASC
    LIMIT 1;

    RETURN v_root_priority_id;
END;
$function$;

COMMENT ON FUNCTION public.classify_thread_for_user IS 'Classify a thread into a priority for a user by evaluating their priority_rules in precedence order: content > contact_topics > channel > root fallback. Accepts either a thread_id or raw parameters for pre-insert classification.';
