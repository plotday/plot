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

GRANT ALL privileges ON ALL TABLES IN SCHEMA public TO internal_admin;

