-- Get contact ID for a twist_instance owner using the primary contact
CREATE OR REPLACE FUNCTION public.get_twist_instance_owner_contact (p_twist_instance_id uuid)
    RETURNS uuid
    AS $$
    SELECT
        public.get_primary_contact_id(pt.owner_id)
    FROM
        twist_instance pt
    WHERE
        pt.id = p_twist_instance_id;
$$
LANGUAGE sql
STABLE;
