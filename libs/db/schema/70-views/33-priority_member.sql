CREATE OR REPLACE VIEW public.priority_member --
AS
SELECT
    pc.contact_id,
    pc.priority_id,
    pc.created_at,
    GREATEST (pc.updated_at, COALESCE(pu.updated_at, pc.created_at), COALESCE(c.updated_at, pc.created_at)) AS updated_at,
    CASE WHEN pc.invited_by IS NOT NULL
        AND pc.invited_at IS NULL THEN
        pc.updated_at
    ELSE
        pu.archived_at
    END AS archived_at,
    CASE WHEN c.user_id IS NOT NULL
        AND pu.user_id IS NOT NULL THEN
        'accepted'::text
    ELSE
        'invited'::text
    END AS status,
    pc.invited_by,
    COALESCE(pu.personal, FALSE) AS personal,
    COALESCE(pu.role, 'member') AS role
FROM
    priority_contact pc
    JOIN contact c ON c.id = pc.contact_id
    LEFT JOIN priority_user pu ON pu.user_id = c.user_id
        AND pu.priority_id = pc.priority_id
WHERE
    (pu.user_id IS NOT NULL
    OR pc.invited_by IS NOT NULL)
    AND (c.user_id IS NULL OR c."primary" = true);

