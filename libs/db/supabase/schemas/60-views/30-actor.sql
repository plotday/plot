CREATE OR REPLACE VIEW "public"."actor" WITH ( security_invoker = TRUE)
-- Aggregates contacts and priority_twists into a unified actor view
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
    c.name,
    c.email,
    c.avatar_url,
    c.archived_at
FROM
    "public"."contact" c
UNION ALL
-- Twists from public.priority_twist
SELECT
    pt.id AS id,
    pt.created_at,
    pt.updated_at,
    'priority_twist'::text AS type,
    pt.name,
    NULL::text AS email,
    NULL::text AS avatar_url,
    pt.archived_at
FROM
    "public"."priority_twist" pt;

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

CREATE OR REPLACE FUNCTION public.actor (note)
    RETURNS SETOF actor
    LANGUAGE sql
    STABLE ROWS 1
    AS $function$
    SELECT
        actor.*
    FROM
        actor
    WHERE
        actor.id = $1.author_id
$function$;

CREATE OR REPLACE FUNCTION public.actor (user_activity)
    RETURNS SETOF actor
    LANGUAGE sql
    STABLE ROWS 1
    AS $function$
    SELECT
        actor.*
    FROM
        actor
    WHERE
        actor.id = $1.author_id
$function$;

CREATE OR REPLACE FUNCTION public.actor (activity_x)
    RETURNS SETOF actor
    LANGUAGE sql
    STABLE ROWS 1
    AS $function$
    SELECT
        actor.*
    FROM
        actor
    WHERE
        actor.id = $1.author_id
$function$;

-- Computed relationship for activity assignee
CREATE OR REPLACE FUNCTION public.assignee (activity)
    RETURNS SETOF actor
    LANGUAGE sql
    STABLE ROWS 1
    AS $function$
    SELECT
        actor.*
    FROM
        actor
    WHERE
        actor.id = $1.assignee_id
$function$;

