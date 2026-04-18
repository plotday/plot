-- user.actor view
-- Shows all actors accessible to each user: contacts via user_contact,
-- non-primary contacts via their primary contact's visibility, and
-- twist instances owned by the user.
CREATE OR REPLACE VIEW "user"."actor" --
AS
-- Contacts visible via user_contact (primary or external contacts)
SELECT
    uc.user_id,
    a.id,
    a.created_at,
    GREATEST(uc.updated_at, a.updated_at) AS updated_at,
    COALESCE(a.archived_at, uc.archived_at) AS archived_at,
    a.type,
    a.name,
    a.email,
    a.avatar_url,
    EXISTS (
        SELECT 1
        FROM contact c
        WHERE c.id = a.id
            AND c.user_id = uc.user_id
    ) AS self,
    a.inviteable
FROM
    user_contact uc
    JOIN contact c ON c.id = uc.contact_id
    JOIN actor a ON a.id = c.id
WHERE
    (c.user_id IS NULL OR c."primary" = true)
UNION ALL
-- Non-primary contacts: include for any user who can already see
-- the primary contact, so notes authored by alternate contact IDs
-- resolve to a name instead of "Unknown" for all viewers
SELECT
    uc_primary.user_id,
    a.id,
    a.created_at,
    a.updated_at,
    a.archived_at,
    a.type,
    a.name,
    a.email,
    a.avatar_url,
    (c.user_id = uc_primary.user_id) AS self,
    a.inviteable
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
    a.archived_at,
    a.type,
    a.name,
    a.email,
    a.avatar_url,
    false AS self,
    a.inviteable
FROM
    "public"."user" u
    JOIN twist_instance pt ON pt.owner_id = u.id
    JOIN actor a ON a.id = pt.id;
