CREATE OR REPLACE VIEW "public"."actor" -- Aggregates contacts and twist_instances into a unified actor view
-- Users are now represented through the contacts table via user_id
AS
-- Contacts from public.contact (includes both regular contacts and user-linked contacts)
SELECT
    c.id AS id,
    c.created_at,
    c.updated_at,
    c.seq,
    CASE WHEN c.user_id IS NOT NULL THEN
        'user'::text
    ELSE
        'contact'::text
    END AS type,
    c.name,
    c.email,
    c.avatar_url,
    c.archived_at,
    c.inviteable
FROM
    "public"."contact" c
UNION ALL
-- Twists from public.twist_instance
SELECT
    pt.id AS id,
    pt.created_at,
    pt.updated_at,
    pt.seq,
    'twist_instance'::text AS type,
    CASE
        WHEN pt.account_label IS NOT NULL AND pt.account_label <> ''
            THEN pt.name || ' (' || pt.account_label || ')'
        ELSE pt.name
    END AS name,
    NULL::text AS email,
    NULL::text AS avatar_url,
    pt.archived_at,
    true AS inviteable
FROM
    "public"."twist_instance" pt;
