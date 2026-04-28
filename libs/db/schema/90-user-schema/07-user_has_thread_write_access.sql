-- Returns TRUE iff the caller has write access to the thread.
--
-- A user has write access when ANY of the following is true:
--   1. One of their linked contacts is in thread.contacts.
--   2. They are a member (via any linked contact) of any non-announce
--      group in thread.groups.
--   3. They are an admin of any announce group in thread.groups.
--
-- A user with no listed contact who reaches the thread purely via an
-- announce-group membership is a read-only viewer.
CREATE OR REPLACE FUNCTION "user".user_has_thread_write_access (
    p_user_id uuid,
    p_thread_id uuid
)
    RETURNS boolean
    LANGUAGE sql
    STABLE
    AS $$
    WITH t AS (
        SELECT contacts, groups FROM thread WHERE id = p_thread_id
    )
    SELECT EXISTS (
        SELECT 1
        FROM t
        WHERE t.contacts && "user".user_contact_ids(p_user_id)
    )
    OR EXISTS (
        SELECT 1
        FROM t
        JOIN unnest(t.groups) AS g(id) ON TRUE
        JOIN "group" gr ON gr.id = g.id
        WHERE gr.type <> 'announce'
          AND g.id = ANY ("user".user_group_ids(p_user_id))
    )
    OR EXISTS (
        SELECT 1
        FROM t
        JOIN unnest(t.groups) AS g(id) ON TRUE
        JOIN "group" gr ON gr.id = g.id
        JOIN group_admin ga ON ga.group_id = g.id
        WHERE gr.type = 'announce'
          AND ga.user_id = p_user_id
    );
$$;
