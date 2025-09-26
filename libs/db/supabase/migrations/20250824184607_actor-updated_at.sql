DROP VIEW IF EXISTS "public"."actor";

CREATE OR REPLACE VIEW "public"."actor" AS
SELECT
    u.id,
    u.created_at,
    u.updated_at,
    'user'::text AS type,
    COALESCE((u.raw_user_meta_data ->> 'full_name'::text), (u.raw_user_meta_data ->> 'name'::text), (u.email)::text) AS name,
    u.email,
    (u.raw_user_meta_data ->> 'avatar_url'::text) AS avatar_url
FROM
    auth.users u
UNION ALL
SELECT
    c.id,
    c.created_at,
    c.updated_at,
    'contact'::text AS type,
    COALESCE(c.name, c.email) AS name,
    c.email,
    c.avatar_url
FROM
    contact c
UNION ALL
SELECT
    pa.id,
    pa.created_at,
    pa.updated_at,
    'priority_agent'::text AS type,
    pa.name,
    NULL::text AS email,
    NULL::text AS avatar_url
FROM
    priority_agent pa;

ALTER VIEW "public"."activity_tags" SET ( security_invoker = TRUE);
ALTER VIEW "public"."activity_children" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_activity" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_activity_exception" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_activity_tags" SET ( security_invoker = TRUE);
ALTER VIEW "admin"."invitation" SET ( security_invoker = FALSE);
ALTER VIEW "public"."priority_tags" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_child" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_priority" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_child_agent" SET ( security_invoker = TRUE);
ALTER VIEW "public"."actor" SET ( security_invoker = TRUE);
