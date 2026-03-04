CREATE OR REPLACE VIEW "user"."priority_unread" --
AS
SELECT
    upe.user_id,
    upe.priority_id,
    TRUE AS unread,
    -- The latest updated_at across relevant threads in the priority
    MAX(GREATEST (COALESCE(ar.updated_at, 'epoch'), CASE
        WHEN a.created_by = upe.user_id THEN COALESCE(a.last_note_created_at, 'epoch')
        ELSE COALESCE(a.last_note_created_at, a.created_at)
    END)) AS updated_at
FROM
    "user".priority_expanded upe
    -- All non-archived threads for the priority after the user joined
    JOIN thread a ON a.priority_id = upe.priority_id
        AND a.archived_at IS NULL
        -- For self-created threads: only include if there are notes
        -- For others: use standard logic
        AND ((a.created_by = upe.user_id AND a.last_note_created_at IS NOT NULL AND a.last_note_created_at > upe.joined_at)
            OR ((a.created_by IS NULL OR a.created_by != upe.user_id) AND COALESCE(a.last_note_created_at, a.created_at) > upe.joined_at))
    LEFT JOIN thread_read ar ON ar.user_id = upe.user_id
        AND ar.thread_id = a.id
GROUP BY
    upe.user_id,
    upe.priority_id;
