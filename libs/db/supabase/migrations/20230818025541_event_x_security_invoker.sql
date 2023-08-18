ALTER VIEW "public"."event_x" SET (security_invoker = TRUE);

DROP POLICY "Users can read their accounts" ON "public"."account";

DROP FUNCTION IF EXISTS "public"."is_user_account" (auth_user_id uuid, account_id bigint);

SET check_function_bodies = OFF;

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

CREATE POLICY "Users can read their accounts" ON "public"."account" AS permissive
    FOR SELECT TO authenticated
        USING (((auth_user_id = auth.uid ()) OR is_user_account (auth.uid (), user_id)));

