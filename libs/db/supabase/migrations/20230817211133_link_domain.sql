DROP FUNCTION public.invitee;

DROP FUNCTION public.label;

DROP TRIGGER IF EXISTS "on_account_created" ON "public"."account";

DROP TRIGGER IF EXISTS "on_contact_created" ON "public"."contact";

ALTER TABLE "public"."account"
    DROP CONSTRAINT "account_organization_id_fkey";

ALTER TABLE "public"."contact"
    DROP CONSTRAINT "contact_organization_id_fkey";

DROP FUNCTION IF EXISTS "public"."get_or_create_organization_id" (email text);

DROP FUNCTION IF EXISTS "public"."link_account_to_organization" ();

DROP FUNCTION IF EXISTS "public"."link_contact_to_organization" ();

DROP VIEW IF EXISTS "public"."event_x";

ALTER TABLE "public"."account"
    DROP COLUMN "organization_id";

ALTER TABLE "public"."account"
    ADD COLUMN "domain_id" bigint;

ALTER TABLE "public"."contact"
    DROP COLUMN "organization_id";

ALTER TABLE "public"."contact"
    ADD COLUMN "domain_id" bigint;

ALTER TABLE "public"."account"
    ADD CONSTRAINT "account_domain_id_fkey" FOREIGN KEY (domain_id) REFERENCES DOMAIN (id) ON DELETE SET NULL NOT valid;

ALTER TABLE "public"."account" validate CONSTRAINT "account_domain_id_fkey";

ALTER TABLE "public"."contact"
    ADD CONSTRAINT "contact_domain_id_fkey" FOREIGN KEY (domain_id) REFERENCES DOMAIN (id) ON DELETE SET NULL NOT valid;

ALTER TABLE "public"."contact" validate CONSTRAINT "contact_domain_id_fkey";

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
        "public"."domain"
    WHERE
        "domain" = domain_name;
    IF FOUND THEN
        RETURN domain_id;
    ELSE
        INSERT INTO organization (name)
            VALUES (domain_name)
        RETURNING
            id INTO org_id;
        INSERT INTO "public"."domain" (organization_id, "domain")
            VALUES (org_id, domain_name);
        RETURN domain_id;
    END IF;
END;
$function$;

CREATE OR REPLACE FUNCTION public.link_account_to_domain ()
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
        domain_id = (
            SELECT
                public.get_or_create_domain_id (NEW.email))
    WHERE
        id = NEW.id;
    RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.link_contact_to_domain ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path TO 'public'
    AS $function$
BEGIN
    IF NEW.email IS NOT NULL THEN
        NEW.domain_id = (
            SELECT
                public.get_or_create_domain_id (NEW.email));
    END IF;
    RETURN NEW;
END
$function$;

CREATE OR REPLACE VIEW "public"."event_x" AS
SELECT
    u.id AS user_id,
    min(e.id) AS id,
    e.name,
    e.at,
    min(e.calendar_id) AS calendar_id,
    min(e.provider_id) AS provider_id,
    min(e.series) AS series,
    min(e.created_at) AS created_at,
    min(e.status) AS status,
    min(e.provider_link) AS provider_link,
    min(e.summary) AS summary,
    min(e.description) AS description,
    min(e.visibility) AS visibility,
    min(e.availability) AS availability,
    min(e.conferencing_url) AS conferencing_url,
    min(e.organizer) AS organizer,
    min(i.response) FILTER (WHERE (ct.contact_user_id = u.id)) AS response,
(round((EXTRACT(epoch FROM (upper(e.at) - lower(e.at))) / (60)::numeric)))::integer AS minutes,
count(DISTINCT i.contact_id) FILTER (WHERE (i.response = 'accepted'::event_response)) AS attendee_count,
count(DISTINCT i.contact_id) AS invitee_count
FROM (((((event e
                    JOIN calendar c ON (e.calendar_id = c.id))
                JOIN account a ON (c.account_id = a.id))
            JOIN "user" u ON (a.user_id = u.id))
        JOIN invitee i ON (e.id = i.event_id))
    JOIN contact ct ON (i.contact_id = ct.id))
GROUP BY
    u.id,
    e.name,
    e.at;

CREATE TRIGGER on_account_created
    AFTER INSERT ON public.account
    FOR EACH ROW
    EXECUTE FUNCTION link_account_to_domain ();

CREATE TRIGGER on_contact_created
    BEFORE INSERT ON public.contact
    FOR EACH ROW
    EXECUTE FUNCTION link_contact_to_domain ();

CREATE OR REPLACE FUNCTION public.invitee (event_x)
    RETURNS SETOF invitee
    LANGUAGE sql
    STABLE
    AS $function$
    SELECT
        *
    FROM
        invitee
    WHERE
        event_id = $1.id
$function$;

CREATE OR REPLACE FUNCTION public.label (event_x)
    RETURNS SETOF label
    LANGUAGE sql
    STABLE
    AS $function$
    SELECT
        label.*
    FROM
        label
        JOIN event_label ON label.id = event_label.label_id
    WHERE
        event_label.event_id = $1.id
$function$;

ALTER TABLE "public"."domain"
    ADD CONSTRAINT "domain_organization_id_fkey" FOREIGN KEY (organization_id) REFERENCES organization (id) ON DELETE SET NULL NOT valid;

ALTER TABLE "public"."domain" validate CONSTRAINT "domain_organization_id_fkey";

CREATE OR REPLACE FUNCTION public.organization (contact)
    RETURNS SETOF organization ROWS 1
    LANGUAGE sql
    STABLE
    AS $function$
    SELECT
        organization.*
    FROM
        organization
        JOIN DOMAIN ON organization.id = domain.organization_id
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
        JOIN DOMAIN ON organization.id = domain.organization_id
    WHERE
        domain.id = $1.domain_id
$function$;

UPDATE
    account
SET
    domain_id = get_or_create_domain_id (account.email);

UPDATE
    contact
SET
    domain_id = get_or_create_domain_id (contact.email);

CREATE POLICY "Everyone can view all domains" ON "public"."domain" AS permissive
    FOR SELECT TO authenticated
        USING (TRUE);

CREATE POLICY "Everyone can view all organizations" ON "public"."organization" AS permissive
    FOR SELECT TO authenticated
        USING (TRUE);

