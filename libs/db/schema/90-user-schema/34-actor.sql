-- user_actor view
-- Shows all actors accessible to each user with aggregated access information
-- One row per (user, actor) combination
CREATE OR REPLACE VIEW "user"."actor" --
AS
WITH upa_agg AS (
    SELECT
        upa.user_id,
        upa.actor_id,
        COALESCE(MIN(upa.updated_at) FILTER (WHERE upa.archived_at IS NULL), MAX(upa.archived_at)) AS updated_at,
        CASE WHEN COUNT(*) FILTER (WHERE upa.archived_at IS NULL) = 0 THEN
            MAX(upa.archived_at)
        ELSE
            NULL
        END AS archived_at,
        MIN(upa.depth) FILTER (WHERE upa.archived_at IS NULL) AS min_depth
    FROM
        "user".priority_actor upa
    GROUP BY
        upa.user_id,
        upa.actor_id
)
SELECT
    ua.user_id,
    a.id,
    a.created_at,
    GREATEST (ua.updated_at, a.updated_at) AS updated_at,
    COALESCE(a.archived_at, ua.archived_at) AS archived_at,
    ua.min_depth,
    a.type,
    a.name,
    a.email,
    a.avatar_url,
    EXISTS (
        SELECT 1
        FROM contact c
        WHERE c.id = a.id
            AND c.user_id = ua.user_id
    ) AS self
FROM
    upa_agg ua
    JOIN actor a ON a.id = ua.actor_id
UNION ALL
-- User's own non-primary contacts (ensures notes authored by
-- alternate contacts resolve to a name instead of "Unknown")
SELECT
    c.user_id,
    a.id,
    a.created_at,
    a.updated_at,
    a.archived_at,
    NULL::integer AS min_depth,
    a.type,
    a.name,
    a.email,
    a.avatar_url,
    true AS self
FROM
    contact c
    JOIN actor a ON a.id = c.id
WHERE
    c.user_id IS NOT NULL
    AND c."primary" = false;
