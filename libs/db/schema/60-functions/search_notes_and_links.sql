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
        SELECT 'note'::text, n.id, n.thread_id, t.title, tp.priority_id,
               p.title, n.content, NULL::text, NULL::text,
               (1 - (n.embedding <=> query_embedding::halfvec))::float AS similarity
        FROM note n
        JOIN thread t ON t.id = n.thread_id
        JOIN thread_priority tp ON tp.thread_id = t.id AND tp.user_id = requesting_user_id
        JOIN priority p ON p.id = tp.priority_id
        JOIN priority_child pc ON pc.priority_id = scope_priority_id
                              AND pc.child_id = tp.priority_id
        WHERE n.embedding IS NOT NULL
          AND n.archived_at IS NULL AND n.draft = FALSE
          AND t.archived_at IS NULL
          AND t.contacts && "user".user_contact_ids(requesting_user_id)
          AND (
            n.created_by = requesting_user_id
            OR (n.access_contacts IS NULL AND n.access_groups IS NULL)
            OR (n.access_contacts IS NOT NULL AND n.access_contacts && "user".user_contact_ids(requesting_user_id))
            OR (n.access_groups IS NOT NULL AND n.access_groups && "user".user_group_ids(requesting_user_id))
          )
          AND (exclude_created_by IS NULL OR n.created_by != exclude_created_by)
          AND (1 - (n.embedding <=> query_embedding::halfvec)) >= similarity_threshold

        UNION ALL

        -- Threads (via thread.embedding)
        SELECT 'link'::text, l.id, l.thread_id, t.title, tp.priority_id,
               p.title, l.preview, l.title, l.source_url,
               (1 - (t.embedding <=> query_embedding::halfvec))::float AS similarity
        FROM link l
        JOIN thread t ON t.id = l.thread_id
        JOIN thread_priority tp ON tp.thread_id = t.id AND tp.user_id = requesting_user_id
        JOIN priority p ON p.id = tp.priority_id
        JOIN priority_child pc ON pc.priority_id = scope_priority_id
                              AND pc.child_id = tp.priority_id
        WHERE t.embedding IS NOT NULL AND l.thread_id IS NOT NULL
          AND t.archived_at IS NULL
          AND t.contacts && "user".user_contact_ids(requesting_user_id)
          AND (1 - (t.embedding <=> query_embedding::halfvec)) >= similarity_threshold
    ) combined
    ORDER BY combined.similarity DESC
    LIMIT match_limit;
END;
$$;
