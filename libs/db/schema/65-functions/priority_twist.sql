-- Get contact ID for a priority_twist owner using a single query with join
CREATE OR REPLACE FUNCTION public.get_priority_twist_owner_contact (p_priority_twist_id uuid)
    RETURNS uuid
    AS $$
    SELECT
        c.id
    FROM
        priority_twist pt
        INNER JOIN contact c ON c.user_id = pt.owner_id
    WHERE
        pt.id = p_priority_twist_id
    LIMIT 1;
$$
LANGUAGE sql
STABLE;
