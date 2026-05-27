-- Resolves an actor (contact) to a twist_instance owned by the actor's user
-- with the same connector type (twist_id) as a reference twist_instance.
-- Returns NULL if the actor is not linked to any user, or if that user has
-- no matching (non-archived, non-draft) twist instance.
--
-- Used by dispatch views to route user-initiated changes on shared threads
-- (RSVP on a calendar event, reactions on a Slack message, etc.) back to
-- the acting user's own connector instance — only that instance has the
-- user's OAuth token and per-user KV state. Dispatching the change to the
-- thread's original creator (a different user) would write to the external
-- system with the wrong identity.
--
-- Parameters:
--   p_actor_contact_id — the acting user's contact_id (e.g. schedule_contact.contact_id)
--   p_reference_twist_instance_id — any twist_instance of the right connector
--     type for the shared entity (e.g. link.created_by). Used purely to read
--     its twist_id so we resolve to the same connector type.
CREATE OR REPLACE FUNCTION public.twist_instance_for_actor (
    p_actor_contact_id uuid,
    p_reference_twist_instance_id uuid
)
    RETURNS uuid
    LANGUAGE sql
    STABLE
    AS $$
    SELECT pt.id
    FROM twist_instance pt
    JOIN user_contact uc ON uc.user_id = pt.owner_id
    WHERE pt.twist_id = (
        SELECT twist_id FROM twist_instance
        WHERE id = p_reference_twist_instance_id
    )
      AND pt.archived_at IS NULL
      AND pt.draft = FALSE
      AND uc.contact_id = p_actor_contact_id
      AND uc.linked = TRUE
      AND uc.archived_at IS NULL
    LIMIT 1;
$$;
