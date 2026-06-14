-- Modify "priority" table
ALTER TABLE "public"."priority" ADD COLUMN "is_fyi" boolean NOT NULL DEFAULT false;
-- Create index "idx_priority_user_fyi" to table: "priority"
CREATE UNIQUE INDEX "idx_priority_user_fyi" ON "public"."priority" ("user_id") WHERE (is_fyi AND (archived_at IS NULL));
-- Create "author_has_real_focus_home" function
CREATE FUNCTION "public"."author_has_real_focus_home" ("p_user_id" uuid, "p_author_id" uuid) RETURNS boolean LANGUAGE sql STABLE AS $$
SELECT p_author_id IS NOT NULL AND EXISTS (
        SELECT 1
        FROM public.thread_priority tp
        JOIN public.thread t ON t.id = tp.thread_id
        JOIN public.priority p ON p.id = tp.priority_id
        WHERE tp.user_id = p_user_id
          AND (tp.user_moved = TRUE OR t.created_by = p_user_id)
          AND p_author_id = ANY(t.contacts)
          AND p.is_inbox = FALSE
          AND p.is_fyi = FALSE
          AND p.archived_at IS NULL
    );
$$;
-- Set comment to function: "author_has_real_focus_home"
COMMENT ON FUNCTION "public"."author_has_real_focus_home" IS 'True when the author has a learned home in a real (non-Inbox, non-FYI) focus — the user moved into or composed a thread this author participates in. The FYI stage yields to that learned focus.';
-- Modify "priority" view
CREATE OR REPLACE VIEW "user"."priority" (
  "user_id",
  "id",
  "created_at",
  "updated_at",
  "seq",
  "archived_at",
  "created_by",
  "updated_by",
  "root",
  "title",
  "path",
  "global_path",
  "top_order",
  "order",
  "pomodoro",
  "color",
  "key",
  "unread",
  "role",
  "respond_schedule_enabled",
  "respond_window",
  "respond_within",
  "early_notifications_enabled",
  "notify_window",
  "see_within",
  "respond_schedule_enabled_set",
  "respond_window_set",
  "respond_within_set",
  "early_notifications_enabled_set",
  "notify_window_set",
  "see_within_set",
  "inherit_members",
  "config",
  "icon",
  "notification_cleared_at",
  "role_id",
  "is_inbox",
  "is_fyi"
) AS WITH user_root AS (
         SELECT DISTINCT ON (p_1.user_id) p_1.user_id,
            p_1.id AS root_id,
            p_1.path AS root_path
           FROM public.priority p_1
          WHERE public.nlevel(p_1.path) = 1
          ORDER BY p_1.user_id, p_1.created_at
        ), direct_settings AS (
         SELECT priority_setting.user_id,
            priority_setting.priority_id,
            max(
                CASE
                    WHEN priority_setting.key = 'top_order'::text THEN (priority_setting.value #>> '{}'::text[])::double precision
                    ELSE NULL::double precision
                END) AS top_order,
            max(
                CASE
                    WHEN priority_setting.key = 'order'::text THEN (priority_setting.value #>> '{}'::text[])::double precision
                    ELSE NULL::double precision
                END) AS "order",
            max(
                CASE
                    WHEN priority_setting.key = 'title'::text THEN priority_setting.value #>> '{}'::text[]
                    ELSE NULL::text
                END) AS title,
            max(
                CASE
                    WHEN priority_setting.key = 'color'::text THEN (priority_setting.value #>> '{}'::text[])::integer
                    ELSE NULL::integer
                END) AS color,
            max(
                CASE
                    WHEN priority_setting.key = 'respond_schedule_enabled'::text THEN 1
                    ELSE NULL::integer
                END) IS NOT NULL AS respond_schedule_enabled_set,
            max(
                CASE
                    WHEN priority_setting.key = 'respond_window'::text THEN 1
                    ELSE NULL::integer
                END) IS NOT NULL AS respond_window_set,
            max(
                CASE
                    WHEN priority_setting.key = 'respond_within'::text THEN 1
                    ELSE NULL::integer
                END) IS NOT NULL AS respond_within_set,
            max(priority_setting.updated_at) AS updated_at
           FROM public.priority_setting
          GROUP BY priority_setting.user_id, priority_setting.priority_id
        ), inherited_settings AS (
         SELECT priority_setting_inherited.user_id,
            priority_setting_inherited.priority_id,
            max(
                CASE
                    WHEN priority_setting_inherited.key = 'pomodoro'::text THEN (priority_setting_inherited.value #>> '{}'::text[])::integer
                    ELSE NULL::integer
                END) AS pomodoro,
            bool_or(
                CASE
                    WHEN priority_setting_inherited.key = 'respond_schedule_enabled'::text THEN (priority_setting_inherited.value #>> '{}'::text[])::boolean
                    ELSE NULL::boolean
                END) AS respond_schedule_enabled,
            max(
                CASE
                    WHEN priority_setting_inherited.key = 'respond_window'::text THEN priority_setting_inherited.value::text
                    ELSE NULL::text
                END)::jsonb AS respond_window,
            max(
                CASE
                    WHEN priority_setting_inherited.key = 'respond_within'::text THEN priority_setting_inherited.value::text
                    ELSE NULL::text
                END)::jsonb AS respond_within,
            bool_or(
                CASE
                    WHEN priority_setting_inherited.key = 'early_notifications_enabled'::text THEN (priority_setting_inherited.value #>> '{}'::text[])::boolean
                    ELSE NULL::boolean
                END) AS early_notifications_enabled,
            max(
                CASE
                    WHEN priority_setting_inherited.key = 'notify_window'::text THEN priority_setting_inherited.value::text
                    ELSE NULL::text
                END)::jsonb AS notify_window,
            max(
                CASE
                    WHEN priority_setting_inherited.key = 'see_within'::text THEN priority_setting_inherited.value::text
                    ELSE NULL::text
                END)::jsonb AS see_within,
            max(priority_setting_inherited.updated_at) AS updated_at
           FROM public.priority_setting_inherited
          GROUP BY priority_setting_inherited.user_id, priority_setting_inherited.priority_id
        )
 SELECT p.user_id,
    p.id,
    p.created_at,
    GREATEST(direct.updated_at, p.updated_at, COALESCE(upu.updated_at, '1970-01-01 00:00:00+00'::timestamp with time zone), inh.updated_at) AS updated_at,
    p.seq,
    p.archived_at,
    p.created_by,
    p.updated_by,
    p.id = ur.root_id AS root,
    COALESCE(direct.title, p.title) AS title,
    p.path,
    p.path AS global_path,
    direct.top_order,
    COALESCE(direct."order", (EXTRACT(epoch FROM p.created_at) * 1000::numeric)::double precision) AS "order",
    inh.pomodoro,
    COALESCE(direct.color, p.color) AS color,
    p.key,
    COALESCE(upu.unread, false) AS unread,
    'member'::text AS role,
    inh.respond_schedule_enabled,
    inh.respond_window,
    inh.respond_within,
    p.early_notifications_enabled,
    p.notify_window,
    p.see_within,
    COALESCE(direct.respond_schedule_enabled_set, false) AS respond_schedule_enabled_set,
    COALESCE(direct.respond_window_set, false) AS respond_window_set,
    COALESCE(direct.respond_within_set, false) AS respond_within_set,
    p.early_notifications_enabled IS NOT NULL AS early_notifications_enabled_set,
    p.notify_window IS NOT NULL AS notify_window_set,
    p.see_within IS NOT NULL AS see_within_set,
    p.inherit_members,
    p.config,
    p.icon,
    p.notification_cleared_at,
    p.role_id,
    p.is_inbox,
    p.is_fyi
   FROM public.priority p
     LEFT JOIN user_root ur ON ur.user_id = p.user_id
     LEFT JOIN direct_settings direct ON direct.user_id = p.user_id AND direct.priority_id = p.id
     LEFT JOIN inherited_settings inh ON inh.user_id = p.user_id AND inh.priority_id = p.id
     LEFT JOIN "user".priority_unread upu ON upu.user_id = p.user_id AND upu.priority_id = p.id;
