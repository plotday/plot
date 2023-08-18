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
        INSERT INTO "public.domain" (organization_id, "domain")
            VALUES (org_id, domain_name);
        RETURN domain_id;
    END IF;
END;
$function$;

CREATE OR REPLACE FUNCTION public.insert_user (_name text, _email text, _avatar_url text, _invitation text)
    RETURNS integer
    LANGUAGE plpgsql
    AS $function$
DECLARE
    new_id integer;
BEGIN
    UPDATE
        INVITATION
    SET
        remaining = remaining - 1
    WHERE
        code = _invitation
        AND remaining > 0;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Invitation code not found';
    END IF;
    BEGIN
        INSERT INTO public.user (name, email, avatar_url, invitation)
            VALUES (_name, _email, _avatar_url, _invitation)
        ON CONFLICT (email)
            DO UPDATE SET
                name = EXCLUDED.name, avatar_url = EXCLUDED.avatar_url, invitation = EXCLUDED.invitation
            RETURNING
                id INTO new_id;
    EXCEPTION
        WHEN OTHERS THEN
            UPDATE
                INVITATION
            SET
                remaining = remaining + 1
            WHERE
                code = _invitation;
    RAISE;
    END;
    RETURN new_id;
END;

$function$;

