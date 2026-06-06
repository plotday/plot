-- Per-user topic read-model. Visible to members, admins, AND opted-out users
-- (so they can rejoin). member_contact_ids mirrors the user.group announce
-- gating: full composed roster for admins / non-announce members; empty for
-- announce-topic non-admins. (Fine-grained per-member-group privacy lands in
-- Plan 2.)
CREATE OR REPLACE VIEW "user"."topic"
AS
SELECT
    u.id AS user_id,
    t.id,
    t.created_at,
    t.updated_at,
    t.seq,
    t.archived_at,
    t.name,
    t.team_id,
    t.announce,
    t.join_policy,
    t.auto_maintained,
    t.key,
    EXISTS (SELECT 1 FROM topic_admin ta WHERE ta.topic_id = t.id AND ta.user_id = u.id) AS is_admin,
    (t.id = ANY("user".user_topic_ids(u.id))) AS is_member,
    EXISTS (SELECT 1 FROM topic_member_optout o WHERE o.topic_id = t.id AND o.user_id = u.id) AS opted_out,
    (
        EXISTS (SELECT 1 FROM topic_admin ta WHERE ta.topic_id = t.id AND ta.user_id = u.id)
        OR (t.announce = FALSE AND t.id = ANY("user".user_topic_ids(u.id)))
    ) AS can_post,
    (
        EXISTS (SELECT 1 FROM topic_admin ta WHERE ta.topic_id = t.id AND ta.user_id = u.id)
        OR (t.join_policy = 'open' AND t.id = ANY("user".user_topic_ids(u.id)))
    ) AS can_manage,
    CASE
        WHEN EXISTS (SELECT 1 FROM topic_admin ta WHERE ta.topic_id = t.id AND ta.user_id = u.id)
             OR (t.announce = FALSE AND t.id = ANY("user".user_topic_ids(u.id)))
        THEN (
            SELECT COALESCE(array_agg(DISTINCT cid), ARRAY[]::uuid[])
            FROM (
                SELECT tc.contact_id AS cid FROM topic_contact tc WHERE tc.topic_id = t.id
                UNION
                SELECT gm.contact_id FROM topic_group tg
                    JOIN group_member gm ON gm.group_id = tg.group_id
                    WHERE tg.topic_id = t.id
            ) roster
        )
        ELSE ARRAY[]::uuid[]
    END AS member_contact_ids
FROM
    public."user" u
    CROSS JOIN topic t
WHERE
    t.archived_at IS NULL
    AND (
        t.id = ANY("user".user_topic_ids(u.id))
        OR EXISTS (SELECT 1 FROM topic_member_optout o
                   WHERE o.topic_id = t.id AND o.user_id = u.id)
        OR EXISTS (SELECT 1 FROM topic_admin ta
                   WHERE ta.topic_id = t.id AND ta.user_id = u.id)
    );
