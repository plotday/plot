-- Function to find similar activities based on embedding similarity
-- Used for similarity-based priority selection when creating new activities
CREATE OR REPLACE FUNCTION public.find_similar_activities (query_embedding text, created_by_id uuid, similarity_threshold float DEFAULT 0.5, match_limit int DEFAULT 1)
    RETURNS TABLE (
        id uuid,
        priority_id uuid,
        title text,
        similarity float)
    LANGUAGE plpgsql
    AS $$
BEGIN
    RETURN QUERY
    SELECT
        a.id,
        a.priority_id,
        a.title,
        1 - (a.embedding <=> query_embedding::vector) AS similarity
    FROM
        public.activity a
    WHERE
        a.created_by = created_by_id
        AND a.embedding IS NOT NULL
        AND a.archived_at IS NULL
        AND (1 - (a.embedding <=> query_embedding::vector)) >= similarity_threshold
    ORDER BY
        a.embedding <=> query_embedding::vector
    LIMIT match_limit;
END;
$$;

