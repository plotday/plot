SET check_function_bodies = OFF;

CREATE OR REPLACE FUNCTION public.get_or_create_domain_id (email text)
    RETURNS bigint
    LANGUAGE plpgsql
    AS $function$
DECLARE
    domain_name text := lower(regexp_replace(split_part(email, '@', 2), '\s+', '', 'g'));
    domain_id bigint;
    org_id bigint;
BEGIN
    SELECT
        id INTO domain_id
    FROM
        public.domain
    WHERE
        "domain" = domain_name;
    IF FOUND THEN
        RETURN domain_id;
    ELSE
        INSERT INTO organization (name)
            VALUES (domain_name)
        RETURNING
            id INTO org_id;
        INSERT INTO public.domain (organization_id, "domain")
            VALUES (org_id, domain_name);
        RETURN domain_id;
    END IF;
END;
$function$;

