CREATE OR REPLACE VIEW "public"."waitlist_admin" WITH ( security_invoker = FALSE)
-- for formatting
AS
SELECT
    min(w.id) AS id,
    min(w.created_at) AS created_at,
    min(w.email) AS email,
    min(a.created_at) AS account_created_at
FROM
    waitlist w
    LEFT OUTER JOIN account a ON (LOWER(a.email) = LOWER(w.email))
GROUP BY
    w.id;

REVOKE ALL ON waitlist_admin FROM PUBLIC;

GRANT SELECT ON waitlist_admin TO internal_admin;

