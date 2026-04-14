-- User-accessible notes filtered by thread_priority access
CREATE OR REPLACE VIEW "user"."note"
--
AS
SELECT
    tp.user_id,
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
    n.access_contacts,
    n.content,
    n.actions,
    n.mentions,
    n.re_note_id,
    n.merged_from_thread_id
FROM
    note n
    JOIN thread a ON a.id = n.thread_id
    JOIN thread_priority tp ON tp.thread_id = a.id
WHERE
    -- Note-level filtering
    (n.draft = FALSE OR n.created_by = tp.user_id)
    AND (n.access_contacts IS NULL
        OR n.created_by = tp.user_id
        OR n.access_contacts && "user".user_contact_ids(tp.user_id))
    -- Thread-level filtering
    AND (a.draft = FALSE OR a.created_by = tp.user_id)
    AND a.contacts && "user".user_contact_ids(tp.user_id)
UNION ALL
-- Redacted rows for private notes the user cannot see
SELECT
    tp.user_id,
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
    CAST(NULL AS uuid[]) AS access_contacts,
    NULL::text AS content,
    NULL::jsonb AS actions,
    CAST(NULL AS uuid[]) AS mentions,
    n.re_note_id,
    n.merged_from_thread_id
FROM
    note n
    JOIN thread a ON a.id = n.thread_id
    JOIN thread_priority tp ON tp.thread_id = a.id
WHERE
    (n.draft = FALSE OR n.created_by = tp.user_id)
    AND (a.draft = FALSE OR a.created_by = tp.user_id)
    AND a.contacts && "user".user_contact_ids(tp.user_id)
    -- Hidden by note-level access restriction
    AND (n.access_contacts IS NOT NULL
        AND n.created_by != tp.user_id
        AND NOT (COALESCE(n.access_contacts, ARRAY[]::uuid[]) && "user".user_contact_ids(tp.user_id)));

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
    AND (n.access_contacts IS NULL
        OR n.created_by = ua.user_id
        OR n.access_contacts && "user".user_contact_ids(ua.user_id));

ALTER VIEW "user"."note_tags" OWNER TO postgres;
