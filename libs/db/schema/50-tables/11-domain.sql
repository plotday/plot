CREATE TABLE "public"."domain" (
    "id" bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY NOT NULL,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "name" text UNIQUE NOT NULL CHECK ("name" = lower("name")),
    "organization_id" bigint REFERENCES organization ON DELETE SET NULL
);

CREATE INDEX "name" ON "public"."domain" USING btree ("name");

CREATE OR REPLACE FUNCTION public.insert_domain (email text)
    RETURNS bigint
    LANGUAGE plpgsql
    AS $function$
DECLARE
    domain_name text := get_domain (email);
    domain_id bigint;
    org_id bigint;
BEGIN
    SELECT
        id INTO domain_id
    FROM
        public.domain
    WHERE
        "name" = domain_name;
    IF NOT FOUND THEN
        INSERT INTO organization (name)
            VALUES (domain_name)
        RETURNING
            id INTO org_id;
        INSERT INTO public.domain (organization_id, "name")
            VALUES (org_id, domain_name);
    END IF;
    RETURN domain_id;
END;
$function$;

