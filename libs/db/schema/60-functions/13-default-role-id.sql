-- Returns the user's default role: their oldest non-archived role. This is the
-- fallback role for newly-created focuses whose creator doesn't specify one —
-- twist-created focuses (which don't know about roles), the REST create
-- endpoint, and sync upserts from clients that send no role_id. Using it
-- guarantees every focus is grouped under a role (the priority_role_or_fyi
-- CHECK on priority requires role_id OR is_fyi).
--
-- Mirrors the "oldest live role" selection used by classify-thread.ts
-- (rootPriorityId picks the oldest live role's Inbox) and by upsert_priority's
-- new-focus role default. Returns NULL only when the user has no live role
-- (i.e. before activate_invited_user has run); callers that must satisfy the
-- CHECK should ensure the user is activated first.
CREATE OR REPLACE FUNCTION public.default_role_id (p_user_id uuid)
    RETURNS uuid
    LANGUAGE sql
    STABLE
    SET search_path TO 'public'
    AS $$
    SELECT id
    FROM public.role
    WHERE user_id = p_user_id
      AND archived_at IS NULL
    ORDER BY created_at ASC
    LIMIT 1
$$;
