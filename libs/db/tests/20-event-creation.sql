BEGIN;
-- Indicate the number of tests
SELECT
    plan (0);
-- lint upsert_event
-- SELECT
--     is_empty ('SELECT plpgsql_check_function (''public.upsert_event'')', 'lint');
-- Indicate tests complete
-- SELECT
--     *
-- FROM
--     finish ();
ROLLBACK;

