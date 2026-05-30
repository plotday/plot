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
        MAX(CASE WHEN key = 'color' THEN (value #>> '{}')::integer END) AS color,
        (MAX(CASE WHEN key = 'respond_schedule_enabled' THEN 1 END) IS NOT NULL) AS respond_schedule_enabled_set,
        (MAX(CASE WHEN key = 'respond_window' THEN 1 END) IS NOT NULL) AS respond_window_set,
        (MAX(CASE WHEN key = 'respond_within' THEN 1 END) IS NOT NULL) AS respond_within_set,
        (MAX(CASE WHEN key = 'early_notifications_enabled' THEN 1 END) IS NOT NULL) AS early_notifications_enabled_set,
        (MAX(CASE WHEN key = 'notify_window' THEN 1 END) IS NOT NULL) AS notify_window_set,
        (MAX(CASE WHEN key = 'see_within' THEN 1 END) IS NOT NULL) AS see_within_set,
        MAX(updated_at) AS updated_at
    FROM priority_setting
    GROUP BY user_id, priority_id
),
inherited_settings AS (
    SELECT user_id, priority_id,
        MAX(CASE WHEN key = 'pomodoro' THEN (value #>> '{}')::integer END) AS pomodoro,
        BOOL_OR(CASE WHEN key = 'respond_schedule_enabled' THEN (value #>> '{}')::boolean END) AS respond_schedule_enabled,
        MAX(CASE WHEN key = 'respond_window' THEN value::text END)::jsonb AS respond_window,
        MAX(CASE WHEN key = 'respond_within' THEN value::text END)::jsonb AS respond_within,
        BOOL_OR(CASE WHEN key = 'early_notifications_enabled' THEN (value #>> '{}')::boolean END) AS early_notifications_enabled,
        MAX(CASE WHEN key = 'notify_window' THEN value::text END)::jsonb AS notify_window,
        MAX(CASE WHEN key = 'see_within' THEN value::text END)::jsonb AS see_within,
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
    -- seq: xid8 cursor counterpart. priority_setting / priority_setting_inherited
    -- aren't synced individually, so we only project priority.seq here. If a
    -- setting changes, the priority row itself isn't bumped — that's
    -- consistent with current behavior (settings live in their own RPCs).
    p.seq,
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
    -- color returns the priority's own color (direct setting, then priority.color, then NULL=inherit).
    -- Ancestor inheritance is computed client-side so the client can distinguish
    -- "explicitly set" from "inherited" — otherwise the edit form pre-fills with
    -- the inherited value and saves it back as a specific color, losing inherit.
    COALESCE(direct.color, p.color) AS color,
    p.key,
    COALESCE(upu.unread, FALSE) AS unread,
    'member'::text AS role,
    inh.respond_schedule_enabled,
    inh.respond_window,
    inh.respond_within,
    inh.early_notifications_enabled,
    inh.notify_window,
    inh.see_within,
    COALESCE(direct.respond_schedule_enabled_set, FALSE) AS respond_schedule_enabled_set,
    COALESCE(direct.respond_window_set, FALSE) AS respond_window_set,
    COALESCE(direct.respond_within_set, FALSE) AS respond_within_set,
    COALESCE(direct.early_notifications_enabled_set, FALSE) AS early_notifications_enabled_set,
    COALESCE(direct.notify_window_set, FALSE) AS notify_window_set,
    COALESCE(direct.see_within_set, FALSE) AS see_within_set,
    p.inherit_members,
    p.config,
    p.default_contacts,
    p.default_groups,
    p.default_invite_emails,
    -- New columns appended at the END so CREATE OR REPLACE VIEW works without
    -- dropping dependents. Order is irrelevant: clients map by column name.
    p.icon,
    -- flat_title: the ancestry label ("Work › Marketing") used by flat
    -- (apiVersion >= 4) clients that render priorities as a flat list. Joins
    -- the titles of this priority and its non-root ancestors. For a genuinely
    -- top-level focus this equals the title; the root's flat_title is NULL
    -- (the flat projection labels the root "Inbox"). Nested clients ignore it.
    (
        SELECT
            string_agg(a.title, ' › ' ORDER BY nlevel(a.path))
        FROM priority a
        WHERE a.user_id = p.user_id
            AND a.path @> p.path
            AND nlevel(a.path) >= 2
    ) AS flat_title
FROM priority p
    LEFT JOIN user_root ur ON ur.user_id = p.user_id
    LEFT JOIN direct_settings direct ON direct.user_id = p.user_id AND direct.priority_id = p.id
    LEFT JOIN inherited_settings inh ON inh.user_id = p.user_id AND inh.priority_id = p.id
    LEFT JOIN "user".priority_unread upu ON upu.user_id = p.user_id AND upu.priority_id = p.id;
