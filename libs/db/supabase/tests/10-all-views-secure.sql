BEGIN;
SELECT
    -- Indicate the number of tests
    plan (1);
SELECT
    ok (public.all_views_secure (),
        'all views have security_invoker');
-- Indicate tests complete
SELECT
    *
FROM
    finish ();
ROLLBACK;

