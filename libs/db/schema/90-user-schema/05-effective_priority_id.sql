-- Returns the priority a thread should appear under *right now*, given its
-- stored thread_priority.priority_id. This resolves to a role Inbox when:
--   (a) priority_id IS NULL  — pending/unclassified (case-A fallback) → the
--       user's fallback Inbox (oldest non-archived role's Inbox), or
--   (b) the filed priority is archived — "archiving a focus releases its
--       threads back to the Inbox" → that focus's own role's Inbox, falling
--       back to the user's fallback Inbox if the role/Inbox is gone.
-- Otherwise it returns the stored priority_id unchanged.
--
-- Crucially this is a *read-time* projection: thread_priority.priority_id is
-- never mutated, so un-archiving the focus restores its threads for free.
-- Used by the user.* views (user.thread, user.priority_unread, user.link,
-- user.schedule).
CREATE OR REPLACE FUNCTION "user".effective_priority_id (p_priority_id uuid, p_user_id uuid)
    RETURNS uuid
    LANGUAGE sql
    STABLE
    AS $$
    SELECT
        CASE
        WHEN p_priority_id IS NULL THEN "user".fallback_inbox_id (p_user_id)
        WHEN EXISTS (
            SELECT 1 FROM priority p
            WHERE p.id = p_priority_id AND p.archived_at IS NOT NULL
        ) THEN COALESCE(
            (SELECT inbox.id
                FROM priority arch
                JOIN priority inbox
                    ON inbox.role_id = arch.role_id
                    AND inbox.is_inbox
                    AND inbox.archived_at IS NULL
                WHERE arch.id = p_priority_id),
            "user".fallback_inbox_id (p_user_id))
        ELSE p_priority_id
        END;
$$;
