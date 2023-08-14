DO $do$
BEGIN
    IF EXISTS (
        SELECT
        FROM
            pg_catalog.pg_roles
        WHERE
            rolname = 'retool') THEN
    RAISE NOTICE 'Role "my_user" already exists. Skipping.';
ELSE
    CREATE ROLE retool;
END IF;
END
$do$;

CREATE POLICY "Retool can access all invitations" ON "public"."invitation" AS permissive
    FOR ALL TO retool
        USING (TRUE);

CREATE POLICY "Retool can view all users" ON "public"."invitation" AS permissive
    FOR SELECT TO retool
        USING (TRUE);

CREATE POLICY "Retool can access full waitlist" ON "public"."waitlist" AS permissive
    FOR ALL TO retool
        USING (TRUE);

