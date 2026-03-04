-- User-accessible notes filtered by priority access
CREATE OR REPLACE VIEW "user"."note"
--
AS
SELECT
    upe.user_id,
    n.id,
    n.created_at,
    n.updated_at,
    n.source_created_at,
    n.author_id,
    n.created_by,
    n.updated_by,
    n.archived_at,
    n.thread_id,
    n.draft,
    n.private,
    n.content,
    n.actions,
    n.mentions,
    n.re_note_id
FROM
    note n
    JOIN thread a ON a.id = n.thread_id
    JOIN "user".priority_expanded upe ON upe.priority_id = a.priority_id
WHERE
    -- Note-level filtering
    (n.draft = FALSE OR n.created_by = upe.user_id)
    AND (n.private = FALSE
        OR n.created_by = upe.user_id
        OR upe.user_id = ANY(n.mentions))
    -- Thread-level filtering (thread draft/private affects note visibility)
    AND (a.draft = FALSE OR a.created_by = upe.user_id)
    AND (CASE WHEN a.private = FALSE THEN TRUE
        WHEN a.created_by = upe.user_id THEN TRUE
        ELSE "user".mentioned_in_thread(upe.user_id, a.id)
    END)
UNION ALL
-- Redacted rows for private notes the user cannot see
SELECT
    upe.user_id,
    n.id,
    n.created_at,
    n.updated_at,
    n.source_created_at,
    n.author_id,
    n.created_by,
    n.updated_by,
    COALESCE(n.archived_at, n.updated_at) AS archived_at,
    n.thread_id,
    n.draft,
    n.private,
    NULL::text AS content,
    NULL::jsonb AS actions,
    CAST(NULL AS uuid[]) AS mentions,
    n.re_note_id
FROM
    note n
    JOIN thread a ON a.id = n.thread_id
    JOIN "user".priority_expanded upe ON upe.priority_id = a.priority_id
WHERE
    (n.draft = FALSE OR n.created_by = upe.user_id)
    AND (a.draft = FALSE OR a.created_by = upe.user_id)
    -- Hidden by note-level OR thread-level privacy
    AND (
        -- Note is private and user can't see it
        (n.private = TRUE
            AND n.created_by != upe.user_id
            AND NOT (upe.user_id = ANY(COALESCE(n.mentions, CAST('{}' AS uuid[])))))
        OR
        -- Thread is private and user can't see it
        (a.private = TRUE
            AND a.created_by != upe.user_id
            AND NOT "user".mentioned_in_thread(upe.user_id, a.id))
    );

ALTER VIEW "user"."note" OWNER TO postgres;

-- User-accessible note tags
CREATE OR REPLACE VIEW "user"."note_tags"
--
AS
SELECT
    ua.user_id,
    n.id,
    nt.updated_at,
    ua.archived_at,
    ua.priority_id,
    ua.priority_path,
    nt.tags
FROM
    note_tags nt
    JOIN note n ON n.id = nt.note_id
    JOIN "user".thread ua ON ua.id = n.thread_id
WHERE
    (n.draft = FALSE OR n.created_by = ua.user_id)
    AND (n.private = FALSE
        OR n.created_by = ua.user_id
        OR ua.user_id = ANY(n.mentions));

ALTER VIEW "user"."note_tags" OWNER TO postgres;
