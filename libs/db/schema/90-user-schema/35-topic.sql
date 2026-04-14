CREATE OR REPLACE VIEW "user"."topic"
AS
SELECT
    u.id AS user_id,
    t.id,
    t.created_at,
    t.updated_at,
    t.archived_at,
    t.name,
    t.type,
    t.join_policy,
    t.team_id,
    t.auto_maintained,
    EXISTS (
        SELECT 1 FROM topic_admin ta
        WHERE ta.topic_id = t.id AND ta.user_id = u.id
    ) AS is_admin,
    EXISTS (
        SELECT 1 FROM topic_member tm
        JOIN user_contact uc ON uc.contact_id = tm.contact_id
            AND uc.linked = TRUE AND uc.archived_at IS NULL
        WHERE tm.topic_id = t.id AND uc.user_id = u.id
    ) AS is_member,
    CASE
        WHEN EXISTS (
            SELECT 1 FROM topic_admin ta
            WHERE ta.topic_id = t.id AND ta.user_id = u.id
        ) THEN (
            SELECT COALESCE(array_agg(tm2.contact_id), ARRAY[]::uuid[])
            FROM topic_member tm2 WHERE tm2.topic_id = t.id
        )
        WHEN t.type IN ('private', 'team') AND EXISTS (
            SELECT 1 FROM topic_member tm
            JOIN user_contact uc ON uc.contact_id = tm.contact_id
                AND uc.linked = TRUE AND uc.archived_at IS NULL
            WHERE tm.topic_id = t.id AND uc.user_id = u.id
        ) THEN (
            SELECT COALESCE(array_agg(tm2.contact_id), ARRAY[]::uuid[])
            FROM topic_member tm2 WHERE tm2.topic_id = t.id
        )
        ELSE ARRAY[]::uuid[]
    END AS member_contact_ids
FROM
    public."user" u
    CROSS JOIN topic t
WHERE
    t.archived_at IS NULL
    AND (
        t.type IN ('public', 'announce')
        OR (t.type = 'team' AND EXISTS (
            SELECT 1 FROM team_user tu
            WHERE tu.team_id = t.team_id AND tu.user_id = u.id
        ))
        OR (t.type = 'private' AND (
            EXISTS (
                SELECT 1 FROM topic_admin ta
                WHERE ta.topic_id = t.id AND ta.user_id = u.id
            )
            OR EXISTS (
                SELECT 1 FROM topic_member tm
                JOIN user_contact uc ON uc.contact_id = tm.contact_id
                    AND uc.linked = TRUE AND uc.archived_at IS NULL
                WHERE tm.topic_id = t.id AND uc.user_id = u.id
            )
        ))
    );

ALTER VIEW "user"."topic" OWNER TO postgres;
