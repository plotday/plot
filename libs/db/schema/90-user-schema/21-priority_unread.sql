CREATE OR REPLACE VIEW "user"."priority_unread" --
AS
SELECT
    upe.user_id,
    upe.priority_id,
    TRUE AS unread,
    MAX(tu.updated_at) AS updated_at
FROM
    "user".priority_expanded upe
    JOIN thread a ON a.priority_id = upe.priority_id
        AND a.archived_at IS NULL
    JOIN thread_unread tu ON tu.user_id = upe.user_id
        AND tu.thread_id = a.id
        AND tu.read_at IS NULL
GROUP BY
    upe.user_id,
    upe.priority_id;
