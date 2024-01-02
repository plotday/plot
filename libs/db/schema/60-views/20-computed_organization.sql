CREATE OR REPLACE FUNCTION public.organization (contact)
    RETURNS SETOF organization ROWS 1
    LANGUAGE sql
    STABLE
    AS $function$
    SELECT
        organization.*
    FROM
        organization
        JOIN "domain" ON organization.id = domain.organization_id
    WHERE
        domain.id = $1.domain_id
$function$;

CREATE OR REPLACE FUNCTION public.organization (account)
    RETURNS SETOF organization ROWS 1
    LANGUAGE sql
    STABLE
    AS $function$
    SELECT
        organization.*
    FROM
        organization
        JOIN "domain" ON organization.id = domain.organization_id
    WHERE
        domain.id = $1.domain_id
$function$;

