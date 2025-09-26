DROP TABLE IF EXISTS "public"."priority_contact" CASCADE;

DROP TABLE IF EXISTS "public"."contact" CASCADE;

CREATE TABLE "public"."contact" (
    "id" uuid NOT NULL DEFAULT gen_random_uuid_v7 (),
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    "deleted_at" timestamp with time zone,
    "email" text NOT NULL,
    "name" text,
    "avatar_url" text
);

ALTER TABLE "public"."contact" ENABLE ROW LEVEL SECURITY;

CREATE TABLE "public"."priority_contact" (
    "id" bigint GENERATED ALWAYS AS IDENTITY NOT NULL,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "deleted_at" timestamp with time zone,
    "priority_id" uuid NOT NULL,
    "contact_id" uuid NOT NULL
);

ALTER TABLE "public"."priority_contact" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."priority_agent"
    ALTER COLUMN "id" SET DEFAULT gen_random_uuid_v7 ();

CREATE UNIQUE INDEX contact_pkey ON public.contact USING btree (id);

CREATE UNIQUE INDEX contact_user_email_unique ON public.contact USING btree (email);

CREATE UNIQUE INDEX priority_contact_pkey ON public.priority_contact USING btree (id);

CREATE UNIQUE INDEX priority_contact_unique ON public.priority_contact USING btree (priority_id, contact_id);

ALTER TABLE "public"."contact"
    ADD CONSTRAINT "contact_pkey" PRIMARY KEY USING INDEX "contact_pkey";

ALTER TABLE "public"."priority_contact"
    ADD CONSTRAINT "priority_contact_pkey" PRIMARY KEY USING INDEX "priority_contact_pkey";

ALTER TABLE "public"."contact"
    ADD CONSTRAINT "contact_email_check" CHECK (is_lower (email)) NOT valid;

ALTER TABLE "public"."contact" validate CONSTRAINT "contact_email_check";

ALTER TABLE "public"."contact"
    ADD CONSTRAINT "contact_user_email_unique" UNIQUE USING INDEX "contact_user_email_unique";

ALTER TABLE "public"."priority_contact"
    ADD CONSTRAINT "priority_contact_contact_id_fkey" FOREIGN KEY (contact_id) REFERENCES contact (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."priority_contact" validate CONSTRAINT "priority_contact_contact_id_fkey";

ALTER TABLE "public"."priority_contact"
    ADD CONSTRAINT "priority_contact_priority_id_fkey" FOREIGN KEY (priority_id) REFERENCES priority (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."priority_contact" validate CONSTRAINT "priority_contact_priority_id_fkey";

ALTER TABLE "public"."priority_contact"
    ADD CONSTRAINT "priority_contact_unique" UNIQUE USING INDEX "priority_contact_unique";

SET check_function_bodies = OFF;

CREATE OR REPLACE VIEW "public"."actor" AS
SELECT
    (u.id)::text AS id,
    'user'::text AS type,
    COALESCE((u.raw_user_meta_data ->> 'full_name'::text), (u.raw_user_meta_data ->> 'name'::text), (u.email)::text) AS name,
    u.email,
    (u.raw_user_meta_data ->> 'avatar_url'::text) AS avatar_url
FROM
    auth.users u
WHERE (u.deleted_at IS NULL)
UNION ALL
SELECT
    (c.id)::text AS id,
    'contact'::text AS type,
    COALESCE(c.name, c.email) AS name,
    c.email,
    c.avatar_url
FROM
    contact c
WHERE (c.deleted_at IS NULL)
UNION ALL
SELECT
    (pa.id)::text AS id,
    'priority_agent'::text AS type,
    pa.name,
    NULL::text AS email,
    NULL::text AS avatar_url
FROM
    priority_agent pa
WHERE (pa.deleted_at IS NULL);

CREATE OR REPLACE FUNCTION public.organization (contact)
    RETURNS SETOF organization
    LANGUAGE sql
    STABLE ROWS 1
    AS $function$
    SELECT
        organization.*
    FROM
        organization
        JOIN "domain" ON organization.id = domain.organization_id
    WHERE
        domain.name = get_domain ($1.email)
$function$;

CREATE POLICY "Users can view contacts linked to their priorities" ON "public"."contact" AS permissive
    FOR SELECT TO authenticated
        USING ((EXISTS (
            SELECT
                1
            FROM
                priority_contact pc
            WHERE ((pc.contact_id = contact.id) AND (pc.deleted_at IS NULL) AND user_has_priority_access (auth.uid (), pc.priority_id)))));

CREATE POLICY "Users can access priority contacts for their priorities" ON "public"."priority_contact" AS permissive
    FOR ALL TO authenticated
        USING (user_has_priority_access (auth.uid (), priority_id));

CREATE TRIGGER on_contact_created
    AFTER INSERT ON public.contact
    FOR EACH ROW
    EXECUTE FUNCTION insert_email_domain ();

DROP FUNCTION IF EXISTS "public"."agent_uuid" ();

ALTER VIEW "public"."activity_tags" SET (security_invoker = TRUE);

ALTER VIEW "public"."activity_children" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_activity" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_activity_exception" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_activity_tags" SET (security_invoker = TRUE);

ALTER VIEW "admin"."invitation" SET (security_invoker = FALSE);

ALTER VIEW "public"."priority_tags" SET (security_invoker = TRUE);

ALTER VIEW "public"."priority_child" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_priority" SET (security_invoker = TRUE);

ALTER VIEW "public"."priority_child_agent" SET (security_invoker = TRUE);

ALTER VIEW "public"."actor" SET (security_invoker = TRUE);

