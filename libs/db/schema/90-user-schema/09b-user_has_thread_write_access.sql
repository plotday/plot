-- Returns TRUE iff the caller has write access to the thread.
--
-- A user has write access when ANY of the following is true:
--   1. One of their linked contacts is in thread.contacts.
--   2. They are a member (via any linked contact) of any non-announce
--      group in thread.groups.
--   3. They are an admin of any announce group in thread.groups.
--   4. The thread has a topic_id and the user is an effective topic member
--      (via user_topic_ids) AND the topic is not announce-only.
--   5. The thread has a topic_id and the user is a topic_admin of that topic
--      (admins can post even to announce topics).
--
-- A user who reaches the thread purely via an announce topic is a read-only
-- viewer (same semantics as announce groups).
CREATE OR REPLACE FUNCTION "user".user_has_thread_write_access (
    p_user_id uuid,
    p_thread_id uuid
)
    RETURNS boolean
    LANGUAGE sql
    STABLE
    AS $$
    WITH t AS (
        SELECT contacts, groups, topic_id FROM thread WHERE id = p_thread_id
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
    )
    -- Topic path (non-announce): effective member of a non-announce topic.
    OR EXISTS (
        SELECT 1
        FROM t
        JOIN topic tp ON tp.id = t.topic_id
        WHERE t.topic_id IS NOT NULL
          AND t.topic_id = ANY ("user".user_topic_ids(p_user_id))
          AND tp.announce = FALSE
    )
    -- Topic path (admin override): topic admins may post even to announce topics.
    OR EXISTS (
        SELECT 1
        FROM t
        JOIN topic_admin ta ON ta.topic_id = t.topic_id
        WHERE t.topic_id IS NOT NULL
          AND ta.user_id = p_user_id
    );
$$;
