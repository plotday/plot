-- Normalize Google contact_external_account rows so Drive's `permissionId`,
-- Google Chat's `users/{numericId}` resource name, and the OIDC `sub` claim
-- all map to the same `account_id`. Going forward, every Google connector
-- emits the bare numeric ID; the `users/` prefix Chat used to ship is
-- stripped here so existing prefixed rows merge with the canonical form.

-- Update non-conflicting rows in place.
UPDATE "public"."contact_external_account" cea
SET account_id = SUBSTRING(account_id FROM 7)
WHERE provider = 'google'
  AND account_id LIKE 'users/%'
  AND NOT EXISTS (
    SELECT 1 FROM "public"."contact_external_account" cea2
    WHERE cea2.provider = 'google'
      AND cea2.account_id = SUBSTRING(cea.account_id FROM 7)
  );

-- For conflicts (both prefixed and bare-numeric rows exist for the same
-- user), the bare-numeric row wins. The prefixed mapping is dropped so
-- future Chat syncs resolve the user via the bare-numeric mapping. The
-- `contact` row the prefixed mapping pointed at is left in place; any
-- existing notes still reference it, matching the platform's pre-existing
-- behaviour when `addContacts` re-points an external_account on
-- ON CONFLICT.
DELETE FROM "public"."contact_external_account"
WHERE provider = 'google'
  AND account_id LIKE 'users/%';
