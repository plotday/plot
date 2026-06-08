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
    -- seq: GREATEST across twist_instance, the parent twist (so redeploys
    -- that rewrite permissions/link_types propagate to clients), and the
    -- owner's twist_instance_connection rows (so user_connected /
    -- needs_reauth changes drive incremental sync of this view).
    GREATEST(pt.seq, t.seq, COALESCE(
        (SELECT MAX(ptc2.seq) FROM twist_instance_connection ptc2
         WHERE ptc2.twist_instance_id = pt.id AND ptc2.user_id = pt.owner_id),
        '0'::xid8
    )) AS seq,
    pt.archived_at,
    pt.twist_id,
    t.environment AS twist_environment,
    t.is_source,
    t.multiple_instances,
    t.shared,
    t.key_option,
    pt.owner_id,
    pt.team_id,
    pt.name,
    pt.account_label,
    pt.custom_emoji_scope,
    t.reaction_capabilities,
    pt.options,
    t.logo_url,
    t.logo_url_dark,
    t.handle,
    t.thread_type,
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
    (t.twist_package_id = '0199b6f4-ae64-7718-8a02-44716f30358f') AS is_builtin
FROM
    twist_instance pt
    JOIN twist t ON pt.twist_id = t.id;
