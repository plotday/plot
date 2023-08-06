DROP POLICY "Users can read their accounts" ON "public"."account";

ALTER TABLE "public"."user"
    ADD COLUMN "link_token" text;

ALTER TABLE "public"."user"
    ADD COLUMN "link_token_expiry" timestamp with time zone;

CREATE UNIQUE INDEX account_user_provider_unique ON public.account USING btree (user_id, auth_user_id, provider);

ALTER TABLE "public"."account"
    ADD CONSTRAINT "account_user_provider_unique" UNIQUE USING INDEX "account_user_provider_unique";

SET check_function_bodies = OFF;

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

CREATE OR REPLACE FUNCTION public.link_account_to_organization ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path TO 'public'
    AS $function$
BEGIN
    IF NEW.email IS NULL THEN
        RETURN NEW;
    END IF;
    UPDATE
        public.account
    SET
        organization_id = (
            SELECT
                public.get_or_create_organization_id (NEW.email))
    WHERE
        id = NEW.id;
    RETURN NEW;
END;
$function$;

CREATE POLICY "Users can read their accounts" ON "public"."account" AS permissive
    FOR SELECT TO authenticated
        USING (((auth_user_id = auth.uid ()) OR is_user_account (auth.uid (), id)));

