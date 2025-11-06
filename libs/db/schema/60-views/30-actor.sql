CREATE OR REPLACE VIEW "public"."actor" WITH ( security_invoker = TRUE)
-- Aggregates contacts and priority_agents into a unified actor view
-- Users are now represented through the contacts table via user_id
AS
-- Contacts from public.contact (includes both regular contacts and user-linked contacts)
SELECT
    c.id AS id,
    c.created_at,
    c.updated_at,
    CASE WHEN c.user_id IS NOT NULL THEN
        'user'::text
    ELSE
        'contact'::text
    END AS type,
    COALESCE(c.name, c.email) AS name,
    c.email,
    c.avatar_url,
    c.archived_at
FROM
    "public"."contact" c
UNION ALL
-- Agents from public.priority_agent
SELECT
    pa.id AS id,
    pa.created_at,
    pa.updated_at,
    'priority_agent'::text AS type,
    pa.name,
    NULL::text AS email,
    NULL::text AS avatar_url,
    pa.archived_at
FROM
    "public"."priority_agent" pa;

-- Define a computed relation for PostgREST joins
-- https://postgrest.org/en/stable/references/api/resource_embedding.html#computed-relationships
CREATE OR REPLACE FUNCTION public.actor (activity)
    RETURNS SETOF actor ROWS 1
    LANGUAGE sql
    STABLE
    AS $function$
    SELECT
        actor.*
    FROM
        actor
    WHERE
        actor.id = $1.author_id
$function$;

CREATE OR REPLACE FUNCTION public.actor (user_activity)
    RETURNS SETOF actor ROWS 1
    LANGUAGE sql
    STABLE
    AS $function$
    SELECT
        actor.*
    FROM
        actor
    WHERE
        actor.id = $1.author_id
$function$;

