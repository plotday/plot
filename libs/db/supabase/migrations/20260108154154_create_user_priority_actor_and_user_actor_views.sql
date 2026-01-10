CREATE OR REPLACE VIEW "public"."user_priority_actor" WITH ( security_invoker = TRUE)
--
AS
SELECT
    user_id,
    priority_path,
    actor_id,
    updated_at,
    archived_at
FROM (
    -- Contacts associated with priorities via priority_contact
    SELECT
        upe.user_id,
        p.path AS priority_path,
        pc.contact_id AS actor_id,
        GREATEST (COALESCE(pc.created_at, c.updated_at), COALESCE(c.updated_at, pc.created_at)) AS updated_at,
        GREATEST (COALESCE(pc.archived_at, c.archived_at), COALESCE(c.archived_at, pc.archived_at)) AS archived_at
    FROM
        user_priority_expanded upe
        JOIN priority_contact pc ON pc.priority_id = upe.priority_id
        JOIN contact c ON c.id = pc.contact_id
        JOIN priority p ON p.id = pc.priority_id
UNION ALL
-- Priority twists (which are actors themselves)
SELECT
    upe.user_id,
    p.path AS priority_path,
    pt.id AS actor_id,
    pt.updated_at,
    pt.archived_at
FROM
    user_priority_expanded upe
    JOIN priority_twist pt ON pt.priority_id = upe.priority_id
    JOIN priority p ON p.id = pt.priority_id) AS actors;

CREATE OR REPLACE VIEW "public"."user_actor" WITH ( security_invoker = TRUE)
--
AS
WITH upa_agg AS (
    SELECT
        upa.user_id,
        upa.actor_id,
        COALESCE(MIN(upa.updated_at) FILTER (WHERE upa.archived_at IS NULL), MAX(upa.archived_at)) AS updated_at,
        CASE WHEN COUNT(*) FILTER (WHERE upa.archived_at IS NULL) = 0 THEN
            MAX(upa.archived_at)
        ELSE
            NULL
        END AS archived_at
    FROM
        user_priority_actor upa
    GROUP BY
        upa.user_id,
        upa.actor_id
)
SELECT
    ua.user_id,
    a.id,
    a.created_at,
    GREATEST (ua.updated_at, a.updated_at) AS updated_at,
    COALESCE(a.archived_at, ua.archived_at) AS archived_at,
    a.type,
    a.name,
    a.email,
    a.avatar_url
FROM
    upa_agg ua
    JOIN actor a ON a.id = ua.actor_id;

ALTER VIEW "public"."user_note" SET (security_invoker = TRUE);

ALTER VIEW "public"."note_tags" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_note_tags" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_twist" SET (security_invoker = TRUE);

ALTER VIEW "public"."activity_tags" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_activity_unread" SET (security_invoker = TRUE);

ALTER VIEW "public"."activity_x" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_activity" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_activity_exception" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_activity_tags" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_priority" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_priority_unread" SET (security_invoker = TRUE);

ALTER VIEW "public"."priority_tags" SET (security_invoker = TRUE);

ALTER VIEW "public"."priority_child" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_priority_expanded" SET (security_invoker = TRUE);

ALTER VIEW "public"."priority_settings_inherited" SET (security_invoker = TRUE);

ALTER VIEW "public"."actor" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_priority_actor" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_actor" SET (security_invoker = TRUE);

ALTER VIEW "public"."priority_child_twist" SET (security_invoker = TRUE);

