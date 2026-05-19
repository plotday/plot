-- User-accessible source channels.
--
-- Two branches:
--   1. Owned: the channel's twist_instance is owned by the user. Authoritative —
--      only the owner can enable/disable, and their client drives refresh.
--   2. Shared: the user has access (via thread_priority) to a thread whose link
--      references the channel. Exposed read-only so shared-thread viewers can
--      resolve status labels, icons, and done-state from channel.link_types
--      without owning the source connector. Triggers on thread_priority INSERT
--      and link INSERT bump channel.updated_at so the viewer's incremental
--      sync cursor picks up newly-relevant channels.
-- Note: `sc.*` includes the new `seq` column on channel automatically. Sync
-- queries against user.channel filter and order on `seq` for the new
-- xid8-based cursor.
CREATE OR REPLACE VIEW "user"."channel" AS
SELECT
    pt.owner_id AS user_id,
    sc.*
FROM
    channel sc
    JOIN twist_instance pt ON pt.id = sc.twist_instance_id
UNION
SELECT DISTINCT
    tp.user_id,
    sc.*
FROM
    channel sc
    JOIN link l
        ON l.channel_id = sc.channel_id
        AND l.created_by = sc.twist_instance_id
    JOIN thread_priority tp ON tp.thread_id = l.thread_id
        AND (
            tp.priority_id IS NOT NULL
            OR tp.classify_at < now() - public.classify_visibility_window()
        )
    JOIN twist_instance pt ON pt.id = sc.twist_instance_id
WHERE
    tp.user_id <> pt.owner_id;
