CREATE OR REPLACE FUNCTION public.get_or_create_organization_id (email text)
    RETURNS bigint
    LANGUAGE plpgsql
    AS $function$
DECLARE
    domain_name text := lower(regexp_replace(split_part(email, '@', 2), '\s+', '', 'g'));
    org_id bigint;
BEGIN
    SELECT
        organization_id INTO org_id
    FROM
        DOMAIN
    WHERE
        DOMAIN = domain_name;
    IF FOUND THEN
        RETURN org_id;
    ELSE
        INSERT INTO organization (name)
            VALUES (domain_name)
        RETURNING
            id INTO org_id;
        INSERT INTO DOMAIN (organization_id, DOMAIN)
            VALUES (org_id, domain_name);
        RETURN org_id;
    END IF;
END;
$function$;

