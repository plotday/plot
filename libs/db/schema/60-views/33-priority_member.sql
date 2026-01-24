CREATE OR REPLACE VIEW public.priority_member WITH ( security_invoker = TRUE)
--
AS
SELECT
    pc.contact_id,
    pc.priority_id,
    pc.created_at,
    GREATEST (pc.created_at, COALESCE(pu.updated_at, pc.created_at)) AS updated_at,
    COALESCE(pc.archived_at, pu.archived_at) AS archived_at,
    CASE WHEN c.user_id IS NOT NULL
        AND pu.user_id IS NOT NULL THEN
        'accepted'::text
    ELSE
        'invited'::text
    END AS status,
    pc.invited_by,
    COALESCE(pu.personal, FALSE) AS personal
FROM
    priority_contact pc
    JOIN contact c ON c.id = pc.contact_id
    LEFT JOIN priority_user pu ON pu.user_id = c.user_id
        AND pu.priority_id = pc.priority_id
        AND pu.archived_at IS NULL
WHERE (pu.user_id IS NOT NULL
    OR pc.invited_by IS NOT NULL)
AND pc.archived_at IS NULL;

