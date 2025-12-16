CREATE OR REPLACE VIEW "public"."priority_unread" AS
SELECT
    upb.user_id,
    upb.id AS priority_id,
    COALESCE(unread_check.unread, FALSE) AS unread
FROM (((user_priority_base upb
        LEFT JOIN contact c ON (c.user_id = upb.user_id))
    LEFT JOIN LATERAL (
        SELECT
            pu.created_at
        FROM (priority_user pu
            JOIN priority p ON (p.id = pu.priority_id))
    WHERE ((pu.user_id = upb.user_id)
        AND (p.path @> upb.path))
ORDER BY
    (nlevel (p.path))
LIMIT 1) member ON (TRUE))
    LEFT JOIN LATERAL (
        SELECT
            TRUE AS unread
        FROM (activity a
            LEFT JOIN activity_read ar ON (((ar.user_id = upb.user_id)
                        AND (ar.activity_id = a.id))))
    WHERE ((a.priority_id = upb.id)
        AND (a.archived_at IS NULL)
        AND (a.draft = FALSE)
        AND (((a.author_id <> c.id)
                AND ((member.created_at IS NULL)
                    OR (a.created_at >= member.created_at))
                AND (ar.read_at IS NULL))
            OR (EXISTS (
                    SELECT
                        1
                    FROM
                        note n
                    WHERE ((n.activity_id = a.id)
                        AND (n.archived_at IS NULL)
                        AND (n.author_id <> c.id)
                        AND ((member.created_at IS NULL)
                            OR (n.created_at >= member.created_at))
                        AND ((ar.read_at IS NULL)
                            OR (n.created_at > ar.read_at)))))))
LIMIT 1) unread_check ON (TRUE));

CREATE OR REPLACE VIEW "public"."user_activity_unread" AS
SELECT
    up.user_id,
    a.id AS activity_id,
    (unread.updated_at IS NOT NULL) AS unread,
    COALESCE(ar.updated_at, unread.updated_at) AS updated_at
FROM (((((user_priority up
                    JOIN contact c ON (c.user_id = up.user_id))
                JOIN activity a ON (a.priority_id = up.id))
            LEFT JOIN activity_read ar ON (((ar.user_id = up.user_id)
                        AND (ar.activity_id = a.id))))
        LEFT JOIN LATERAL (
            SELECT
                pu.created_at
            FROM ((priority_user pu
                    JOIN priority p ON (p.id = pu.priority_id))
                JOIN priority ap ON (ap.id = a.priority_id))
        WHERE ((pu.user_id = up.user_id)
            AND (p.path @> ap.path))
    ORDER BY
        (nlevel (p.path))
    LIMIT 1) member ON (TRUE))
    LEFT JOIN LATERAL (
        SELECT
            max(GREATEST (a.updated_at, n.updated_at)) AS updated_at
        FROM
            note n
        WHERE ((n.activity_id = a.id)
            AND (n.archived_at IS NULL)
            AND (n.author_id <> c.id)
            AND ((member.created_at IS NULL)
                OR (n.created_at >= member.created_at))
            AND ((ar.read_at IS NULL)
                OR (n.created_at > ar.read_at)))
    UNION ALL
    SELECT
        a.updated_at
    WHERE ((a.author_id <> c.id)
        AND ((member.created_at IS NULL)
            OR (a.created_at >= member.created_at))
        AND (ar.read_at IS NULL))) unread ON (TRUE))
WHERE (up.archived_at IS NULL);

ALTER VIEW "public"."user_note" SET ( security_invoker = TRUE);
ALTER VIEW "public"."note_tags" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_note_tags" SET ( security_invoker = TRUE);
ALTER VIEW "public"."activity_tags" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_activity_unread" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_activity" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_activity_exception" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_activity_tags" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_priority" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_unread" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_tags" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_child" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_settings_inherited" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_priority_base" SET ( security_invoker = TRUE);
ALTER VIEW "public"."actor" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_child_twist" SET ( security_invoker = TRUE);
