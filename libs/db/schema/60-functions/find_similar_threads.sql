-- Function to find similar threads based on link embedding similarity
-- Used for similarity-based priority selection when creating new links
CREATE OR REPLACE FUNCTION public.find_similar_threads (query_embedding text, created_by_id uuid, similarity_threshold float DEFAULT 0.5, match_limit int DEFAULT 1)
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
        l.thread_id AS id,
        t.priority_id,
        COALESCE(l.title, t.title) AS title,
        1 - (l.embedding <=> query_embedding::vector) AS similarity
    FROM
        public.link l
        JOIN public.thread t ON t.id = l.thread_id
    WHERE
        l.created_by = created_by_id
        AND l.embedding IS NOT NULL
        AND t.archived_at IS NULL
        AND (1 - (l.embedding <=> query_embedding::vector)) >= similarity_threshold
    ORDER BY
        l.embedding <=> query_embedding::vector
    LIMIT match_limit;
END;
$$;
