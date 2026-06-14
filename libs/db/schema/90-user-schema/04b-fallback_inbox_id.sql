-- The user's default Inbox: the Inbox focus of their oldest non-archived role.
-- Replaces root_priority_id as the universal "no specific focus" fallback for
-- pending/archived thread filings (see effective_priority_id). root_priority_id
-- (04) stays for now — still used by apply_mute / activate_invited_user.
CREATE OR REPLACE FUNCTION "user".fallback_inbox_id (p_user_id uuid)
    RETURNS uuid
    LANGUAGE sql
    STABLE
    AS $$
    SELECT inbox.id
    FROM public.role r
    JOIN public.priority inbox
        ON inbox.role_id = r.id
        AND inbox.is_inbox
        AND inbox.archived_at IS NULL
    WHERE r.user_id = p_user_id
        AND r.archived_at IS NULL
    ORDER BY r.created_at ASC
    LIMIT 1;
$$;
