-- Function to find matching threads based on configurable scoring rules
-- Supports both required exact matches and weighted similarity scoring
-- Queries link table for embedding, meta, and type fields
CREATE OR REPLACE FUNCTION public.find_matching_threads_scored (query_embedding text, created_by_id uuid, required_filters jsonb DEFAULT '{}' ::jsonb, scored_fields jsonb DEFAULT '{}' ::jsonb, thread_data jsonb DEFAULT '{}' ::jsonb, similarity_threshold double precision DEFAULT 0.7)
    RETURNS TABLE (
        id uuid,
        priority_id uuid,
        title text,
        total_score double precision)
    LANGUAGE plpgsql
    AS $function$
BEGIN
    RETURN QUERY WITH filtered_links AS (
        -- First filter by required exact matches on link fields
        SELECT
            l.id AS link_id,
            l.thread_id,
            t.priority_id,
            COALESCE(l.title, t.title) AS title,
            l.type,
            l.meta,
            l.embedding
        FROM
            public.link l
            JOIN public.thread t ON t.id = l.thread_id
        WHERE
            l.created_by = created_by_id
            AND t.archived_at IS NULL
            -- Content similarity filter (when content is required)
            -- Skip if query_embedding is null/empty (embedding generation failed)
            AND ((required_filters ? 'content'
                    AND query_embedding IS NOT NULL
                    AND query_embedding <> ''
                    AND query_embedding <> '[]'
                    AND l.embedding IS NOT NULL
                    AND (1 - (l.embedding <=> query_embedding::vector)) >= similarity_threshold)
                OR NOT (required_filters ? 'content'))
            -- Type exact match (when type is required)
            AND ((required_filters ? 'type'
                    AND l.type = (thread_data ->> 'type'))
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
                        AND (l.meta IS NULL
                            OR l.meta ->> substring(key FROM 6) IS DISTINCT FROM thread_data -> 'meta' ->> substring(key FROM 6))))
),
scored_links AS (
    -- Calculate scores for each matching link
    SELECT
        fl.thread_id AS id,
        fl.priority_id,
        fl.title,
        -- Sum up all scores
        (
            -- Content similarity score (skip if query_embedding is null/empty)
            COALESCE(
                CASE WHEN scored_fields ? 'content'
                    AND fl.embedding IS NOT NULL
                    AND query_embedding IS NOT NULL
                    AND query_embedding <> ''
                    AND query_embedding <> '[]' THEN
                    (scored_fields ->> 'content')::float * (1 - (fl.embedding <=> query_embedding::vector))
                ELSE
                    0
                END, 0) +
            -- Type exact match score
            COALESCE(
                CASE WHEN scored_fields ? 'type' THEN
                    CASE WHEN fl.type = (thread_data ->> 'type') THEN
                        (scored_fields ->> 'type')::float
                    ELSE
                        0
                    END
                ELSE
                    0
                END, 0) +
            -- Meta field exact match scores
            COALESCE((
                SELECT
                    COALESCE(SUM(
                            CASE WHEN fl.meta IS NOT NULL
                                AND fl.meta ->> substring(key FROM 6) IS NOT DISTINCT FROM thread_data -> 'meta' ->> substring(key FROM 6) THEN
                                (scored_fields ->> key)::float
                            ELSE
                                0
                            END), 0)
                FROM jsonb_object_keys(scored_fields) AS key
                WHERE
                    key LIKE 'meta.%'), 0)) AS total_score
FROM
    filtered_links fl
)
SELECT
    sl.id,
    sl.priority_id,
    sl.title,
    sl.total_score
FROM
    scored_links sl
WHERE
    sl.total_score > 0
ORDER BY
    sl.total_score DESC
LIMIT 1;
END;
$function$;
