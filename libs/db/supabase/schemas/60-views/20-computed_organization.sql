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
        domain.name = get_domain ($1.email)
$function$;

