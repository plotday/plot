CREATE OR REPLACE VIEW "admin"."invitation" WITH ( security_invoker = FALSE)
-- for formatting
AS
SELECT
    min(i.id) AS id,
    min(i.created_at) AS created_at,
    min(i.code) AS code,
    min(i.remaining) AS remaining
FROM
    invitation i
GROUP BY
    i.id;

