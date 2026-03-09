-- User-accessible priority twists filtered by priority access
CREATE OR REPLACE VIEW "user"."twist" --
AS
-- Priority-bound twists (existing behavior)
SELECT
    upe.user_id,
    pt.id,
    pt.created_at,
    pt.updated_at,
    pt.archived_at,
    pt.priority_id,
    pt.twist_id,
    t.environment AS twist_environment,
    t.is_source,
    pt.owner_id,
    pt.name,
    pt.config,
    t.logo_url,
    t.logo_url_dark,
    (
        SELECT
            jsonb_agg(lt)
        FROM
            jsonb_array_elements(t.permissions -> '_providers') AS p,
            jsonb_array_elements(p -> 'linkTypes') AS lt
    ) AS link_types,
    COALESCE((t.permissions ->> '_default_mention_created')::boolean, false) AS default_mention_created,
    COALESCE((t.permissions ->> '_default_mention_mentioned')::boolean, false) AS default_mention_mentioned
FROM
    priority_twist pt
    JOIN "user".priority_expanded upe ON upe.priority_id = pt.priority_id
    JOIN twist t ON pt.twist_id = t.id

UNION ALL

-- Source accounts (no priority, visible to owner)
SELECT
    pt.owner_id AS user_id,
    pt.id,
    pt.created_at,
    pt.updated_at,
    pt.archived_at,
    pt.priority_id,
    pt.twist_id,
    t.environment AS twist_environment,
    t.is_source,
    pt.owner_id,
    pt.name,
    pt.config,
    t.logo_url,
    t.logo_url_dark,
    (
        SELECT
            jsonb_agg(lt)
        FROM
            jsonb_array_elements(t.permissions -> '_providers') AS p,
            jsonb_array_elements(p -> 'linkTypes') AS lt
    ) AS link_types,
    COALESCE((t.permissions ->> '_default_mention_created')::boolean, false) AS default_mention_created,
    COALESCE((t.permissions ->> '_default_mention_mentioned')::boolean, false) AS default_mention_mentioned
FROM
    priority_twist pt
    JOIN twist t ON pt.twist_id = t.id
WHERE
    t.is_source = TRUE
    AND pt.priority_id IS NULL;
