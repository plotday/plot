-- Returns the user's primary linked contact, or NULL if none is set.
CREATE OR REPLACE FUNCTION "user".user_contact_id (p_user_id uuid)
    RETURNS uuid
    LANGUAGE sql
    STABLE
    AS $$
    SELECT uc.contact_id
    FROM user_contact uc
    WHERE uc.user_id = p_user_id
      AND uc."primary" = TRUE
      AND uc.linked = TRUE
      AND uc.archived_at IS NULL
    LIMIT 1;
$$;

-- Returns every non-archived contact linked to the user. Access checks and
-- count-tag ownership must use this so a user can access threads (and modify
-- their own tags) through any of their linked contacts, not just the primary.
CREATE OR REPLACE FUNCTION "user".user_contact_ids (p_user_id uuid)
    RETURNS uuid[]
    LANGUAGE sql
    STABLE
    AS $$
    SELECT COALESCE(array_agg(uc.contact_id), ARRAY[]::uuid[])
    FROM user_contact uc
    WHERE uc.user_id = p_user_id
      AND uc.linked = TRUE
      AND uc.archived_at IS NULL;
$$;

-- Resolves a contact_id to the canonical actor for its underlying user: the
-- user's current primary linked contact. For contacts not linked to any user
-- (external contacts, twists), returns the input unchanged.
--
-- WARNING: per-row use in a SELECT/UPDATE list will produce N+1 lookups
-- against user_contact. For sets, prefer joining user_contact directly:
--
--     SELECT t.id, COALESCE(uc_p.contact_id, t.actor_id) AS canonical_id
--     FROM some_table t
--     LEFT JOIN user_contact uc_self
--       ON uc_self.contact_id = t.actor_id AND uc_self.linked = TRUE
--      AND uc_self.archived_at IS NULL
--     LEFT JOIN user_contact uc_p
--       ON uc_p.user_id = uc_self.user_id AND uc_p."primary" = TRUE
--      AND uc_p.linked = TRUE AND uc_p.archived_at IS NULL
--
-- Use this helper only for single-row lookups (RPC bodies, scalar guards).
CREATE OR REPLACE FUNCTION "user".canonical_contact_id (p_contact_id uuid)
    RETURNS uuid
    LANGUAGE sql
    STABLE
    AS $$
    SELECT COALESCE(
        (SELECT uc_p.contact_id
           FROM user_contact uc_self
           JOIN user_contact uc_p ON uc_p.user_id = uc_self.user_id
            AND uc_p."primary" = TRUE
            AND uc_p.linked = TRUE
            AND uc_p.archived_at IS NULL
          WHERE uc_self.contact_id = p_contact_id
            AND uc_self.linked = TRUE
            AND uc_self.archived_at IS NULL
          LIMIT 1),
        p_contact_id
    );
$$;

-- Returns every linked contact for the user that owns p_contact_id (treating
-- linked contacts as equivalent identities). For contacts not linked to any
-- user, returns ARRAY[p_contact_id]. Useful for "archive every row that
-- belongs to the same person" patterns.
CREATE OR REPLACE FUNCTION "user".sibling_contact_ids (p_contact_id uuid)
    RETURNS uuid[]
    LANGUAGE sql
    STABLE
    AS $$
    SELECT COALESCE(
        (SELECT array_agg(uc_sib.contact_id)
           FROM user_contact uc_self
           JOIN user_contact uc_sib ON uc_sib.user_id = uc_self.user_id
            AND uc_sib.linked = TRUE
            AND uc_sib.archived_at IS NULL
          WHERE uc_self.contact_id = p_contact_id
            AND uc_self.linked = TRUE
            AND uc_self.archived_at IS NULL),
        ARRAY[p_contact_id]
    );
$$;
