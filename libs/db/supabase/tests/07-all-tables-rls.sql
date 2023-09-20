BEGIN;
SELECT
    -- Indicate the number of tests
    plan (1);
PREPARE all_tables_rls AS
SELECT
    relname,
    relrowsecurity
FROM
    pg_class
    JOIN pg_catalog.pg_namespace n ON n.oid = pg_class.relnamespace
WHERE
    n.nspname = 'public'
    AND relkind = 'r'
    AND relrowsecurity = FALSE;
SELECT
    is_empty ('all_tables_rls', 'All tables have RLS enabled');
-- Indicate tests complete
SELECT
    *
FROM
    finish ();
ROLLBACK;

