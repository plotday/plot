-- Backward-compatibility wrapper around classify_thread_for_user.
--
-- Previously contained the full matching algorithm. Now delegates to
-- classify_thread_for_user which evaluates user-defined priority_rules.
-- Kept so that existing callers (triggers, old API code) continue to work.
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
    -- Legacy parameters are ignored; classification is now rule-based.
    RETURN public.classify_thread_for_user(p_user_id);
END;
$function$;
