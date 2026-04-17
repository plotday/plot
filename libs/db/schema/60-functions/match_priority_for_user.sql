-- Backward-compatibility wrapper around classify_thread_for_user.
--
-- Previously contained the full matching algorithm. Now delegates to
-- classify_thread_for_user which scores against the user's explicitly-moved
-- threads. Kept so that existing callers (triggers, old API code) continue
-- to work. Legacy parameters (embedding, thread_data, filters, threshold)
-- are ignored — classification reads signals from the thread row.
CREATE OR REPLACE FUNCTION public.match_priority_for_user (
    p_user_id uuid,
    query_embedding text DEFAULT NULL,
    p_thread_data jsonb DEFAULT '{}' ::jsonb,
    p_required_filters jsonb DEFAULT '{}' ::jsonb,
    p_scored_fields jsonb DEFAULT '{}' ::jsonb,
    p_similarity_threshold double precision DEFAULT 0.7
)
    RETURNS uuid
    LANGUAGE plpgsql
    AS $function$
BEGIN
    -- Legacy parameters are ignored; classification scores against
    -- thread_priority.user_moved = TRUE training examples.
    RETURN public.classify_thread_for_user(p_user_id);
END;
$function$;
