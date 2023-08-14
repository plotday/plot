DO $do$
BEGIN
    IF EXISTS (
        SELECT
        FROM
            pg_catalog.pg_roles
        WHERE
            rolname = 'internal_admin') THEN
    RAISE NOTICE 'Role "my_user" already exists. Skipping.';
ELSE
    CREATE ROLE internal_admin WITH LOGIN;
END IF;
END
$do$;

DROP POLICY "Retool can access all invitations" ON "public"."invitation";

DROP POLICY "Retool can view all users" ON "public"."invitation";

DROP POLICY "Retool can access full waitlist" ON "public"."waitlist";

CREATE POLICY "internal_admin can access all invitations" ON "public"."invitation" AS permissive
    FOR ALL TO internal_admin
        USING (TRUE);

CREATE POLICY "internal_admin can view all users" ON "public"."invitation" AS permissive
    FOR SELECT TO internal_admin
        USING (TRUE);

CREATE POLICY "internal_admin can access full waitlist" ON "public"."waitlist" AS permissive
    FOR ALL TO internal_admin
        USING (TRUE);

DROP ROLE retool;

GRANT ALL privileges ON ALL TABLES IN SCHEMA public TO internal_admin;

