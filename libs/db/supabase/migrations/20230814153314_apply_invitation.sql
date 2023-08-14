SET check_function_bodies = OFF;

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

