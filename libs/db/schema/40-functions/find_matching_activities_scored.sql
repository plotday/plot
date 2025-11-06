-- Function to find matching activities based on configurable scoring rules
-- Supports both required exact matches and weighted similarity scoring
CREATE OR REPLACE FUNCTION public.find_matching_activities_scored (query_embedding text, created_by_id uuid, required_filters jsonb DEFAULT '{}' ::jsonb, scored_fields jsonb DEFAULT '{}' ::jsonb, activity_data jsonb DEFAULT '{}' ::jsonb, similarity_threshold double precision DEFAULT 0.7)
    RETURNS TABLE (
        id uuid,
        priority_id uuid,
        title text,
        total_score double precision)
    LANGUAGE plpgsql
    AS $function$
BEGIN
    RETURN QUERY WITH filtered_activities AS (
        -- First filter by required exact matches
        SELECT
            a.id,
            a.priority_id,
            a.title,
            a.type,
            a.mentions,
            a.meta,
            a.embedding
        FROM
            public.activity a
        WHERE
            a.created_by = created_by_id
            AND a.archived_at IS NULL
            -- Content similarity filter (when content is required)
            AND ((required_filters ? 'content'
                    AND a.embedding IS NOT NULL
                    AND (1 - (a.embedding <=> query_embedding::vector)) >= similarity_threshold)
                OR NOT (required_filters ? 'content'))
            -- Type exact match (when type is required)
            AND ((required_filters ? 'type'
                    AND a.type = (activity_data ->> 'type')::int)
                OR NOT (required_filters ? 'type'))
            -- Meta field exact matches (when meta.field is required)
            AND (
                -- Check all required meta fields match
                NOT EXISTS (
                    SELECT
                        1
                    FROM
                        jsonb_object_keys(required_filters) AS key
                    WHERE
                        key LIKE 'meta.%'
                        AND (a.meta IS NULL
                            OR a.meta ->> substring(key FROM 6) IS DISTINCT FROM activity_data -> 'meta' ->> substring(key FROM 6))))
),
scored_activities AS (
    -- Calculate scores for each matching activity
    SELECT
        fa.id,
        fa.priority_id,
        fa.title,
        -- Sum up all scores
        (
            -- Content similarity score
            COALESCE(
                CASE WHEN scored_fields ? 'content'
                    AND fa.embedding IS NOT NULL THEN
                    (scored_fields ->> 'content')::float * (1 - (fa.embedding <=> query_embedding::vector))
                ELSE
                    0
                END, 0) +
            -- Type exact match score
            COALESCE(
                CASE WHEN scored_fields ? 'type' THEN
                    CASE WHEN fa.type = (activity_data ->> 'type')::int THEN
                        (scored_fields ->> 'type')::float
                    ELSE
                        0
                END
                ELSE
                    0
                END, 0) +
            -- Mentions array overlap score
            COALESCE(
                CASE WHEN scored_fields ? 'mentions'
                    AND fa.mentions IS NOT NULL
                    AND jsonb_array_length(activity_data -> 'mentions') > 0 THEN
                    (scored_fields ->> 'mentions')::float * (
                        -- Count matching elements / length of existing array
                        (
                            SELECT
                                COUNT(*)::float
                            FROM jsonb_array_elements_text(fa.mentions::jsonb) existing_mention
                            WHERE
                                existing_mention IN (
                                    SELECT
                                        jsonb_array_elements_text(activity_data -> 'mentions'))) / jsonb_array_length(fa.mentions::jsonb))
                ELSE
                    0
                END, 0) +
            -- Meta field exact match scores
            COALESCE((
                SELECT
                    COALESCE(SUM(
                            CASE WHEN fa.meta IS NOT NULL
                                AND fa.meta ->> substring(key FROM 6) IS NOT DISTINCT FROM activity_data -> 'meta' ->> substring(key FROM 6) THEN
                                (scored_fields ->> key)::float
                            ELSE
                                0
                            END), 0)
                FROM jsonb_object_keys(scored_fields) AS key
                WHERE
                    key LIKE 'meta.%'), 0)) AS total_score
FROM
    filtered_activities fa
)
SELECT
    sa.id,
    sa.priority_id,
    sa.title,
    sa.total_score
FROM
    scored_activities sa
WHERE
    sa.total_score > 0
ORDER BY
    sa.total_score DESC
LIMIT 1;
END;
$function$;

