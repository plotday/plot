-- user.priority — per-user view of every priority a user owns, with
-- titles, colours, per-user overrides, and unread status joined in.
--
-- In the per-user model a priority has exactly one owner (priority.user_id).
-- Walking descendants is a simple path filter within the user's own tree;
-- there are no shared priorities.
--
-- The `root` column is kept for the Flutter app's compatibility: `root`
-- is true only for the user's personal root priority (nlevel = 1).
-- All priorities owned by the user are now inherently personal.
DROP VIEW IF EXISTS "user"."priority" CASCADE;
CREATE OR REPLACE VIEW "user"."priority" -- for formatting
AS
WITH user_root AS (
    SELECT DISTINCT ON (p.user_id)
        p.user_id,
        p.id AS root_id,
        p.path AS root_path
    FROM priority p
    WHERE nlevel(p.path) = 1
    ORDER BY p.user_id, p.created_at ASC
),
direct_settings AS (
    SELECT user_id, priority_id,
        MAX(CASE WHEN key = 'top_order' THEN (value #>> '{}')::double precision END) AS top_order,
        MAX(CASE WHEN key = 'order' THEN (value #>> '{}')::double precision END) AS "order",
        MAX(CASE WHEN key = 'title' THEN value #>> '{}' END) AS title,
        (MAX(CASE WHEN key = 'attention_window' THEN 1 END) IS NOT NULL) AS attention_window_set,
        (MAX(CASE WHEN key = 'see_within_requests' THEN 1 END) IS NOT NULL) AS see_within_requests_set,
        (MAX(CASE WHEN key = 'see_within_updates' THEN 1 END) IS NOT NULL) AS see_within_updates_set,
        MAX(updated_at) AS updated_at
    FROM priority_setting
    GROUP BY user_id, priority_id
),
inherited_settings AS (
    SELECT user_id, priority_id,
        MAX(CASE WHEN key = 'pomodoro' THEN (value #>> '{}')::integer END) AS pomodoro,
        MAX(CASE WHEN key = 'color' THEN (value #>> '{}')::integer END) AS color,
        MAX(CASE WHEN key = 'attention_window' THEN value::text END)::jsonb AS attention_window,
        MAX(CASE WHEN key = 'see_within_requests' THEN value::text END)::jsonb AS see_within_requests,
        MAX(CASE WHEN key = 'see_within_updates' THEN value::text END)::jsonb AS see_within_updates,
        MAX(updated_at) AS updated_at
    FROM priority_setting_inherited
    GROUP BY user_id, priority_id
)
SELECT
    p.user_id,
    p.id,
    p.created_at,
    GREATEST (
        direct.updated_at,
        p.updated_at,
        COALESCE(upu.updated_at, 'epoch'::timestamptz),
        inh.updated_at
    ) AS updated_at,
    p.archived_at,
    p.created_by,
    p.updated_by,
    -- root is the user's single top-level priority
    p.id = ur.root_id AS root,
    COALESCE(direct.title, p.title) AS title,
    p.path AS path,
    p.path AS global_path,
    direct.top_order,
    COALESCE(direct."order", extract(epoch FROM p.created_at) * 1000) AS "order",
    inh.pomodoro,
    inh.color,
    p.key,
    COALESCE(upu.unread, FALSE) AS unread,
    'member'::text AS role,
    inh.attention_window,
    inh.see_within_requests,
    inh.see_within_updates,
    COALESCE(direct.attention_window_set, FALSE) AS attention_window_set,
    COALESCE(direct.see_within_requests_set, FALSE) AS see_within_requests_set,
    COALESCE(direct.see_within_updates_set, FALSE) AS see_within_updates_set,
    p.inherit_members
FROM priority p
    LEFT JOIN user_root ur ON ur.user_id = p.user_id
    LEFT JOIN direct_settings direct ON direct.user_id = p.user_id AND direct.priority_id = p.id
    LEFT JOIN inherited_settings inh ON inh.user_id = p.user_id AND inh.priority_id = p.id
    LEFT JOIN "user".priority_unread upu ON upu.user_id = p.user_id AND upu.priority_id = p.id;
