-- View that indicates whether a priority has any unread activities for each user
CREATE OR REPLACE VIEW "public"."priority_unread" WITH ( security_invoker = TRUE)
--
AS
SELECT
    upb.user_id,
    upb.id AS priority_id,
    COALESCE(unread_check.unread, FALSE) AS unread
FROM
    user_priority_base upb
    LEFT JOIN contact c ON c.user_id = upb.user_id
    -- Join to get when user was added to the priority root
    LEFT JOIN LATERAL (
        SELECT pu.created_at
        FROM priority_user pu
        JOIN priority p ON p.id = pu.priority_id
        WHERE pu.user_id = upb.user_id
          AND p.path @> upb.path
        ORDER BY nlevel(p.path) ASC
        LIMIT 1
    ) member ON TRUE
    LEFT JOIN LATERAL (
        SELECT
            TRUE AS unread
        FROM
            activity a
        LEFT JOIN activity_read ar ON ar.user_id = upb.user_id
            AND ar.activity_id = a.id
    WHERE
        a.priority_id = upb.id
        AND a.archived_at IS NULL
        AND a.draft = FALSE
        AND (
            -- Activity created by another author and not read
            (a.author_id <> c.id
                -- Only activities created after user joined
                AND (member.created_at IS NULL OR a.created_at >= member.created_at)
                AND ar.read_at IS NULL)
            -- OR activity has a note by another author newer than read_at
            OR EXISTS (
                SELECT
                    1
                FROM
                    note n
                WHERE
                    n.activity_id = a.id
                    AND n.archived_at IS NULL
                    AND n.author_id <> c.id
                    -- Only notes created after user joined
                    AND (member.created_at IS NULL OR n.created_at >= member.created_at)
                    AND (ar.read_at IS NULL
                        OR n.created_at > ar.read_at)))
    LIMIT 1) unread_check ON TRUE;
