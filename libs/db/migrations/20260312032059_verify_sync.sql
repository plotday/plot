-- Modify "get_thread_mentions" function
CREATE OR REPLACE FUNCTION "public"."get_thread_mentions" ("p_thread_id" uuid) RETURNS uuid[] LANGUAGE sql STABLE AS $$
SELECT
        ARRAY_AGG(DISTINCT mention)
    FROM (
        -- Mentions from notes
        SELECT unnest(n.mentions) AS mention
        FROM note n
        WHERE n.thread_id = p_thread_id
            AND n.archived_at IS NULL
            AND n.mentions IS NOT NULL
        UNION
        -- Include thread creator when it's a source (priority_twist)
        SELECT t.created_by AS mention
        FROM thread t
        WHERE t.id = p_thread_id
            AND EXISTS (SELECT 1 FROM priority_twist pt WHERE pt.id = t.created_by)
    ) sub;
$$;
