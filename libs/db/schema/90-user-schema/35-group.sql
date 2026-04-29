CREATE OR REPLACE VIEW "user"."group"
AS
SELECT
    u.id AS user_id,
    g.id,
    g.created_at,
    g.updated_at,
    g.seq,
    g.archived_at,
    g.name,
    g.type,
    g.join_policy,
    g.team_id,
    g.auto_maintained,
    EXISTS (
        SELECT 1 FROM group_admin ga
        WHERE ga.group_id = g.id AND ga.user_id = u.id
    ) AS is_admin,
    EXISTS (
        SELECT 1 FROM group_member gm
        JOIN user_contact uc ON uc.contact_id = gm.contact_id
            AND uc.linked = TRUE AND uc.archived_at IS NULL
        WHERE gm.group_id = g.id AND uc.user_id = u.id
    ) AS is_member,
    CASE
        WHEN EXISTS (
            SELECT 1 FROM group_admin ga
            WHERE ga.group_id = g.id AND ga.user_id = u.id
        ) THEN (
            SELECT COALESCE(array_agg(gm2.contact_id), ARRAY[]::uuid[])
            FROM group_member gm2 WHERE gm2.group_id = g.id
        )
        WHEN g.type IN ('private', 'team') AND EXISTS (
            SELECT 1 FROM group_member gm
            JOIN user_contact uc ON uc.contact_id = gm.contact_id
                AND uc.linked = TRUE AND uc.archived_at IS NULL
            WHERE gm.group_id = g.id AND uc.user_id = u.id
        ) THEN (
            SELECT COALESCE(array_agg(gm2.contact_id), ARRAY[]::uuid[])
            FROM group_member gm2 WHERE gm2.group_id = g.id
        )
        ELSE ARRAY[]::uuid[]
    END AS member_contact_ids
FROM
    public."user" u
    CROSS JOIN "group" g
WHERE
    g.archived_at IS NULL
    AND (
        g.type IN ('public', 'announce')
        -- Key-identified broadcast groups: visible to every user so they can
        -- address them as recipients (e.g. submitting feedback to Plot Team).
        -- Membership and thread-receiving semantics are unchanged — non-members
        -- still don't see existing threads sent to the group.
        OR g.key = '@plot.team'
        OR (g.type = 'team' AND EXISTS (
            SELECT 1 FROM team_user tu
            WHERE tu.team_id = g.team_id AND tu.user_id = u.id
        ))
        OR (g.type = 'private' AND (
            EXISTS (
                SELECT 1 FROM group_admin ga
                WHERE ga.group_id = g.id AND ga.user_id = u.id
            )
            OR EXISTS (
                SELECT 1 FROM group_member gm
                JOIN user_contact uc ON uc.contact_id = gm.contact_id
                    AND uc.linked = TRUE AND uc.archived_at IS NULL
                WHERE gm.group_id = g.id AND uc.user_id = u.id
            )
        ))
    );

