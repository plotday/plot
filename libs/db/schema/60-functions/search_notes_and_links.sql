CREATE OR REPLACE FUNCTION public.search_notes_and_links(
    query_embedding text,
    scope_priority_id uuid,
    requesting_user_id uuid,
    exclude_created_by uuid DEFAULT NULL,
    similarity_threshold float DEFAULT 0.3,
    match_limit int DEFAULT 20
)
RETURNS TABLE (
    result_type text,
    result_id uuid,
    thread_id uuid,
    thread_title text,
    priority_id uuid,
    priority_title text,
    content text,
    title text,
    source_url text,
    similarity float
)
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY
    SELECT * FROM (
        -- Notes
        SELECT 'note'::text, n.id, n.thread_id, t.title, t.priority_id,
               p.title, n.content, NULL::text, NULL::text,
               (1 - (n.embedding <=> query_embedding::halfvec))::float AS similarity
        FROM note n
        JOIN thread t ON t.id = n.thread_id
        JOIN priority p ON p.id = t.priority_id
        JOIN priority_child pc ON pc.priority_id = scope_priority_id
                              AND pc.child_id = t.priority_id
        WHERE n.embedding IS NOT NULL
          AND n.archived_at IS NULL AND n.draft = FALSE
          AND t.archived_at IS NULL
          AND (t.private = FALSE AND n.private = FALSE OR n.created_by = requesting_user_id OR t.created_by = requesting_user_id)
          AND (exclude_created_by IS NULL OR n.created_by != exclude_created_by)
          AND (1 - (n.embedding <=> query_embedding::halfvec)) >= similarity_threshold

        UNION ALL

        -- Links
        SELECT 'link'::text, l.id, l.thread_id, t.title, t.priority_id,
               p.title, l.preview, l.title, l.source_url,
               (1 - (l.embedding <=> query_embedding::halfvec))::float AS similarity
        FROM link l
        JOIN thread t ON t.id = l.thread_id
        JOIN priority p ON p.id = t.priority_id
        JOIN priority_child pc ON pc.priority_id = scope_priority_id
                              AND pc.child_id = t.priority_id
        WHERE l.embedding IS NOT NULL AND l.thread_id IS NOT NULL
          AND t.archived_at IS NULL
          AND (t.private = FALSE OR t.created_by = requesting_user_id)
          AND (1 - (l.embedding <=> query_embedding::halfvec)) >= similarity_threshold
    ) combined
    ORDER BY combined.similarity DESC
    LIMIT match_limit;
END;
$$;
