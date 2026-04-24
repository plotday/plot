-- Data migration: strip Google Groups / mailing-list " via <group>" suffix
-- from existing contact names, plus any wrapping single/double quotes left
-- from RFC 5322 quoted display names. Matches the normalizeName() logic in
-- workers/api/src/twist/tools/plot/contacts.ts so existing poisoned rows
-- catch up with the new platform-level fix.
WITH "candidates" AS (
    SELECT
        "id",
        BTRIM(REGEXP_REPLACE("name", '\s+via\s+.+$', '', 'i')) AS "via_stripped"
    FROM "public"."contact"
    WHERE "name" ~* '\svia\s'
),
"cleaned" AS (
    SELECT
        "id",
        CASE
            WHEN "via_stripped" ~ '^''.*''$' OR "via_stripped" ~ '^".*"$'
                THEN BTRIM(SUBSTRING("via_stripped" FROM 2 FOR LENGTH("via_stripped") - 2))
            ELSE "via_stripped"
        END AS "name"
    FROM "candidates"
)
UPDATE "public"."contact"
SET "name" = NULLIF("cleaned"."name", '')
FROM "cleaned"
WHERE "contact"."id" = "cleaned"."id"
  AND "contact"."name" IS DISTINCT FROM NULLIF("cleaned"."name", '');
