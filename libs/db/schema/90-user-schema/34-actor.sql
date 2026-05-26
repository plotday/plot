-- user.actor view
-- Shows all actors accessible to each user: contacts via user_contact,
-- non-primary contacts via their primary contact's visibility, and
-- twist instances owned by the user.
--
-- The "primary" column marks the canonical actor to surface in user-facing
-- pickers (one per person). Non-primary linked contacts are still returned
-- so historical content authored by alternate contact IDs resolves to a
-- name, but they MUST be filtered out of mention/share/assign pickers.
--
-- The "linked_user_id" column carries the contact's underlying user_id
-- (i.e. the human this contact is one of the identities of). Multiple
-- contact rows on the same thread that share a linked_user_id represent
-- the same person and must be deduped in client-side rendering. NULL for
-- unlinked external contacts and twist instances.
--
-- The "external_accounts" column aggregates contact_external_account rows
-- for this contact as a JSON array of {twist_instance_id, provider,
-- account_id} objects. The load-bearing key for the DM picker filter is
-- twist_instance_id — it scopes a contact to a specific connection (one
-- Slack workspace, one Gmail account, etc.). `provider` is kept for
-- display only. Always an empty array for twist instances (which are
-- not contacts).
CREATE OR REPLACE VIEW "user"."actor" --
AS
-- Contacts visible via user_contact (primary or external contacts).
-- The tombstone (a row with archived_at IS NOT NULL) is always emitted
-- without PII: when EITHER the contact itself (a.archived_at) OR the
-- recipient's user_contact (uc.archived_at) is archived, name / email /
-- avatar are returned as NULL. This is the canonical revocation
-- mechanism — clients pull the tombstone via the seq cursor, mark the
-- row archived in their local cache, and never see the PII again.
SELECT
    uc.user_id,
    a.id,
    a.created_at,
    GREATEST(uc.updated_at, a.updated_at) AS updated_at,
    GREATEST(uc.seq, a.seq) AS seq,
    COALESCE(a.archived_at, uc.archived_at) AS archived_at,
    a.type,
    CASE WHEN a.archived_at IS NULL AND uc.archived_at IS NULL THEN a.name       ELSE NULL END AS name,
    CASE WHEN a.archived_at IS NULL AND uc.archived_at IS NULL THEN a.email      ELSE NULL END AS email,
    CASE WHEN a.archived_at IS NULL AND uc.archived_at IS NULL THEN a.avatar_url ELSE NULL END AS avatar_url,
    EXISTS (
        SELECT 1
        FROM contact c
        WHERE c.id = a.id
            AND c.user_id = uc.user_id
    ) AS self,
    a.inviteable,
    true AS "primary",
    c.user_id AS linked_user_id,
    COALESCE(
        (
            SELECT json_agg(json_build_object('twist_instance_id', cea.twist_instance_id, 'provider', cea.provider, 'account_id', cea.account_id))
            FROM contact_external_account cea
            WHERE cea.contact_id = a.id
        ),
        '[]'::json
    ) AS external_accounts
FROM
    user_contact uc
    JOIN contact c ON c.id = uc.contact_id
    JOIN actor a ON a.id = c.id
WHERE
    (c.user_id IS NULL OR c."primary" = true)
UNION ALL
-- Non-primary contacts: include for any user who can already see
-- the primary contact, so notes authored by alternate contact IDs
-- resolve to a name instead of "Unknown" for all viewers. seq /
-- updated_at / archived_at incorporate uc_primary so revoking the
-- primary's user_contact propagates redaction to the alias too.
SELECT
    uc_primary.user_id,
    a.id,
    a.created_at,
    GREATEST(uc_primary.updated_at, a.updated_at) AS updated_at,
    GREATEST(uc_primary.seq, a.seq) AS seq,
    COALESCE(a.archived_at, uc_primary.archived_at) AS archived_at,
    a.type,
    CASE WHEN a.archived_at IS NULL AND uc_primary.archived_at IS NULL THEN a.name       ELSE NULL END AS name,
    CASE WHEN a.archived_at IS NULL AND uc_primary.archived_at IS NULL THEN a.email      ELSE NULL END AS email,
    CASE WHEN a.archived_at IS NULL AND uc_primary.archived_at IS NULL THEN a.avatar_url ELSE NULL END AS avatar_url,
    (c.user_id = uc_primary.user_id) AS self,
    a.inviteable,
    false AS "primary",
    c.user_id AS linked_user_id,
    COALESCE(
        (
            SELECT json_agg(json_build_object('twist_instance_id', cea.twist_instance_id, 'provider', cea.provider, 'account_id', cea.account_id))
            FROM contact_external_account cea
            WHERE cea.contact_id = a.id
        ),
        '[]'::json
    ) AS external_accounts
FROM
    contact c
    JOIN actor a ON a.id = c.id
    JOIN contact c_primary ON c_primary.user_id = c.user_id AND c_primary."primary" = true
    JOIN user_contact uc_primary ON uc_primary.contact_id = c_primary.id
WHERE
    c."primary" = false
UNION ALL
-- Twist instances owned by each user
SELECT
    u.id AS user_id,
    a.id,
    a.created_at,
    a.updated_at,
    a.seq,
    a.archived_at,
    a.type,
    a.name,
    a.email,
    a.avatar_url,
    false AS self,
    a.inviteable,
    true AS "primary",
    NULL::uuid AS linked_user_id,
    '[]'::json AS external_accounts
FROM
    "public"."user" u
    JOIN twist_instance pt ON pt.owner_id = u.id
    JOIN actor a ON a.id = pt.id;
