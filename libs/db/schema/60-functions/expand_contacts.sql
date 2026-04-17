-- Expand a contact array to include every linked alias belonging to any
-- user that owns one of the input contacts.
--
-- Used by classify_thread_for_user when comparing contact overlap between a
-- candidate thread and the user's explicitly-moved training threads. Without
-- expansion, two threads that reference the same human via different linked
-- contact rows (e.g. work + personal email) would score zero overlap.
--
-- Contacts not linked to any user are returned as-is.
CREATE OR REPLACE FUNCTION public.expand_contacts (p_contacts uuid[])
    RETURNS uuid[]
    LANGUAGE sql
    STABLE
    PARALLEL SAFE
    AS $$
    SELECT COALESCE(array_agg(DISTINCT c), ARRAY[]::uuid[])
    FROM (
        SELECT unnest(p_contacts) AS c
        UNION
        SELECT uc2.contact_id
        FROM unnest(p_contacts) raw
        JOIN public.user_contact uc1
            ON uc1.contact_id = raw
           AND uc1.linked = TRUE
           AND uc1.archived_at IS NULL
        JOIN public.user_contact uc2
            ON uc2.user_id = uc1.user_id
           AND uc2.linked = TRUE
           AND uc2.archived_at IS NULL
    ) u;
$$;

COMMENT ON FUNCTION public.expand_contacts IS 'Expand a contact array to include every linked alias of any user that owns one of the input contacts.';
