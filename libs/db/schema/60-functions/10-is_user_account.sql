CREATE OR REPLACE FUNCTION public.is_user_account (auth_user_id uuid, account_id bigint)
    RETURNS boolean
    LANGUAGE sql
    SECURITY DEFINER
    AS $function$
    SELECT
        EXISTS (
            SELECT
                1
            FROM
                account account_2
            WHERE
                account_2.auth_user_id = is_user_account.auth_user_id
                AND account_2.user_id = (
                    SELECT
                        account.user_id
                    FROM
                        account account
                    WHERE
                        account.id = is_user_account.account_id));
$function$;

