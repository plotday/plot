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

