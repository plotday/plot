-- Classify a thread into a priority for a specific user by evaluating
-- their priority_rules in precedence order:
--   1. content  — cosine similarity ≥ 0.7 against rule embedding
--   2. topic    — exact-string match on thread.topic
--   3. fallback — user's root priority
--
-- Accepts either an existing thread_id (reads data from DB) or raw
-- parameters for pre-insert classification.  Override parameters take
-- precedence when provided (non-NULL).
CREATE OR REPLACE FUNCTION public.classify_thread_for_user (
    p_user_id uuid,
    p_thread_id uuid DEFAULT NULL,
    p_embedding halfvec DEFAULT NULL,
    p_topic text DEFAULT NULL
)
    RETURNS uuid
    LANGUAGE plpgsql
    AS $function$
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
$function$;

COMMENT ON FUNCTION public.classify_thread_for_user IS 'Classify a thread into a priority for a user by evaluating their priority_rules in precedence order: content > topic > root fallback. Accepts either a thread_id or raw parameters for pre-insert classification.';
