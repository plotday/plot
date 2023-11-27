CREATE OR REPLACE FUNCTION public.is_user_account (auth_user_id uuid, user_id bigint)
    RETURNS boolean
    LANGUAGE sql
    SECURITY DEFINER
    AS $function$
    SELECT
        user_id IN (
            SELECT
                user_id
            FROM
                account a
            WHERE
                a.auth_user_id = is_user_account.auth_user_id);
$function$;

CREATE OR REPLACE FUNCTION public.get_user_id ()
    RETURNS bigint
    LANGUAGE sql
    SECURITY DEFINER
    AS $function$
    SELECT
        user_id
    FROM
        "public"."account"
    WHERE
        auth_user_id = auth.uid ()
    LIMIT 1;
$function$;

