-- Get contact ID for a priority_twist owner using the primary contact
CREATE OR REPLACE FUNCTION public.get_priority_twist_owner_contact (p_priority_twist_id uuid)
    RETURNS uuid
    AS $$
    SELECT
        public.get_primary_contact_id(pt.owner_id)
    FROM
        priority_twist pt
    WHERE
        pt.id = p_priority_twist_id;
$$
LANGUAGE sql
STABLE;
