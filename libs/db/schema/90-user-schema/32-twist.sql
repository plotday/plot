-- User-accessible twist instances. Twists are workspace-level: every
-- active twist_instance is visible to its owner across all of their
-- priorities, and only to the owner.
CREATE OR REPLACE VIEW "user"."twist" --
AS
SELECT
    pt.owner_id AS user_id,
    pt.id,
    pt.created_at,
    GREATEST(pt.updated_at, t.updated_at, (
        SELECT MAX(ptc2.connected_at)
        FROM twist_instance_connection ptc2
        WHERE ptc2.twist_instance_id = pt.id
          AND ptc2.user_id = pt.owner_id
    )) AS updated_at,
    pt.archived_at,
    pt.twist_id,
    t.environment AS twist_environment,
    t.is_source,
    t.multiple_instances,
    t.shared,
    t.key_option,
    pt.owner_id,
    pt.name,
    pt.options,
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
    COALESCE((t.permissions ->> '_default_mention_mentioned')::boolean, false) AS default_mention_mentioned,
    CASE
        WHEN t.shared THEN
            EXISTS (
                SELECT 1
                FROM twist_instance_connection ptc
                WHERE ptc.twist_instance_id = pt.id
            )
        ELSE
            EXISTS (
                SELECT 1
                FROM twist_instance_connection ptc
                WHERE ptc.twist_instance_id = pt.id
                  AND ptc.user_id = pt.owner_id
            )
    END AS user_connected,
    (ta.twist_package_id = '0199b6f4-ae64-7718-8a02-44716f30358f') AS is_builtin
FROM
    twist_instance pt
    JOIN twist t ON pt.twist_id = t.id
    JOIN twist_admin ta ON t.twist_admin_id = ta.id;
