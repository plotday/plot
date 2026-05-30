-- Returns the priority a thread should appear under *right now*, given its
-- stored thread_priority.priority_id. This is the root/Inbox when:
--   (a) priority_id IS NULL  — pending/unclassified (case-A fallback), or
--   (b) the filed priority is archived — "archiving a focus releases its
--       threads back to the Inbox".
-- Otherwise it returns the stored priority_id unchanged.
--
-- Crucially this is a *read-time* projection: thread_priority.priority_id is
-- never mutated, so un-archiving the focus restores its threads for free.
-- Replaces the previous COALESCE(tp.priority_id, root_priority_id(user)) in
-- the user.* views (user.thread, user.priority_unread, user.link, user.schedule).
CREATE OR REPLACE FUNCTION "user".effective_priority_id (p_priority_id uuid, p_user_id uuid)
    RETURNS uuid
    LANGUAGE sql
    STABLE
    AS $$
    SELECT
        CASE
        WHEN p_priority_id IS NULL THEN "user".root_priority_id (p_user_id)
        WHEN EXISTS (
            SELECT 1 FROM priority p
            WHERE p.id = p_priority_id AND p.archived_at IS NOT NULL
        ) THEN "user".root_priority_id (p_user_id)
        ELSE p_priority_id
        END;
$$;
