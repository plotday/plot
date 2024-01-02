CREATE OR REPLACE VIEW "public"."invitation_admin" WITH ( security_invoker = FALSE)
-- for formatting
AS
SELECT
    min(i.id) AS id,
    min(i.created_at) AS created_at,
    min(i.code) AS code,
    min(i.remaining) AS remaining,
    COUNT(w.invitation) AS uses
FROM
    invitation i
    LEFT OUTER JOIN "waitlist" w ON (w.invitation = i.code)
GROUP BY
    i.id;

REVOKE ALL ON invitation_admin FROM PUBLIC;

GRANT SELECT ON invitation_admin TO internal_admin;

