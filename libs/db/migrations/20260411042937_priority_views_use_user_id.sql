-- Modify "priority" table
ALTER TABLE "public"."priority" DROP CONSTRAINT "priority_path_key";
-- Create index "idx_priority_user_path_unique" to table: "priority"
CREATE UNIQUE INDEX "idx_priority_user_path_unique" ON "public"."priority" ("user_id", "path");
-- Modify "priority_child" view
CREATE OR REPLACE VIEW "public"."priority_child" (
  "priority_id",
  "child_id",
  "archived_at"
) AS SELECT p.id AS priority_id,
    c.id AS child_id,
    c.archived_at
   FROM public.priority p
     JOIN public.priority c ON c.path OPERATOR(public.<@) p.path AND c.user_id = p.user_id;
-- Modify "priority_setting_inherited" view
CREATE OR REPLACE VIEW "public"."priority_setting_inherited" (
  "user_id",
  "priority_id",
  "key",
  "value",
  "source_path",
  "updated_at"
) AS WITH all_sources AS (
         SELECT ps.user_id,
            p.id AS priority_id,
            ps.key,
            ps.value,
            parent.path AS source_path,
            ps.updated_at,
            public.nlevel(p.path) - public.nlevel(parent.path) AS distance,
            0 AS source_type
           FROM public.priority_setting ps
             JOIN public.priority parent ON ps.priority_id = parent.id
             JOIN public.priority p ON p.path OPERATOR(public.<@) parent.path AND p.user_id = parent.user_id
          WHERE ps.key = ANY (ARRAY['pomodoro'::text, 'color'::text, 'path'::text, 'attention_window'::text, 'see_within_requests'::text, 'see_within_updates'::text])
        UNION ALL
         SELECT p.user_id,
            p.id AS priority_id,
            'color'::text AS key,
            to_jsonb(parent.color) AS value,
            parent.path AS source_path,
            parent.updated_at,
            public.nlevel(p.path) - public.nlevel(parent.path) AS distance,
            1 AS source_type
           FROM public.priority p
             JOIN public.priority parent ON p.path OPERATOR(public.<@) parent.path AND parent.user_id = p.user_id
          WHERE parent.color IS NOT NULL
        )
 SELECT DISTINCT ON (user_id, priority_id, key) user_id,
    priority_id,
    key,
    value,
    source_path,
    updated_at
   FROM all_sources
  ORDER BY user_id, priority_id, key, distance, source_type;
-- Modify "priority" view
CREATE OR REPLACE VIEW "user"."priority" (
  "user_id",
  "id",
  "created_at",
  "updated_at",
  "archived_at",
  "created_by",
  "updated_by",
  "root",
  "personal",
  "title",
  "path",
  "global_path",
  "top_order",
  "order",
  "pomodoro",
  "color",
  "key",
  "team_id",
  "unread",
  "role",
  "attention_window",
  "see_within_requests",
  "see_within_updates",
  "attention_window_set",
  "see_within_requests_set",
  "see_within_updates_set",
  "inherit_members"
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
                    WHEN priority_setting.key = 'attention_window'::text THEN 1
                    ELSE NULL::integer
                END) IS NOT NULL AS attention_window_set,
            max(
                CASE
                    WHEN priority_setting.key = 'see_within_requests'::text THEN 1
                    ELSE NULL::integer
                END) IS NOT NULL AS see_within_requests_set,
            max(
                CASE
                    WHEN priority_setting.key = 'see_within_updates'::text THEN 1
                    ELSE NULL::integer
                END) IS NOT NULL AS see_within_updates_set,
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
            max(
                CASE
                    WHEN priority_setting_inherited.key = 'color'::text THEN (priority_setting_inherited.value #>> '{}'::text[])::integer
                    ELSE NULL::integer
                END) AS color,
            max(
                CASE
                    WHEN priority_setting_inherited.key = 'attention_window'::text THEN priority_setting_inherited.value::text
                    ELSE NULL::text
                END)::jsonb AS attention_window,
            max(
                CASE
                    WHEN priority_setting_inherited.key = 'see_within_requests'::text THEN priority_setting_inherited.value::text
                    ELSE NULL::text
                END)::jsonb AS see_within_requests,
            max(
                CASE
                    WHEN priority_setting_inherited.key = 'see_within_updates'::text THEN priority_setting_inherited.value::text
                    ELSE NULL::text
                END)::jsonb AS see_within_updates,
            max(
                CASE
                    WHEN priority_setting_inherited.key = 'path'::text THEN priority_setting_inherited.value #>> '{}'::text[]
                    ELSE NULL::text
                END) AS path_value,
            max(
                CASE
                    WHEN priority_setting_inherited.key = 'path'::text THEN priority_setting_inherited.source_path::text
                    ELSE NULL::text
                END) AS path_source,
            max(priority_setting_inherited.updated_at) AS updated_at
           FROM public.priority_setting_inherited
          GROUP BY priority_setting_inherited.user_id, priority_setting_inherited.priority_id
        )
 SELECT p.user_id,
    p.id,
    p.created_at,
    GREATEST(direct.updated_at, p.updated_at, COALESCE(upu.updated_at, '1970-01-01 00:00:00+00'::timestamp with time zone), inh.updated_at) AS updated_at,
    p.archived_at,
    p.created_by,
    p.updated_by,
    p.id = ur.root_id AS root,
    ur.root_path OPERATOR(public.@>) p.path AS personal,
    COALESCE(direct.title, p.title) AS title,
        CASE
            WHEN inh.path_value IS NOT NULL THEN
            CASE
                WHEN inh.path_source IS NOT NULL AND p.path OPERATOR(public.<>) inh.path_source::public.ltree AND public.subpath(p.path, public.nlevel(inh.path_source::public.ltree)) OPERATOR(public.<>) ''::public.ltree THEN inh.path_value::public.ltree OPERATOR(public.||) public.subpath(p.path, public.nlevel(inh.path_source::public.ltree))
                ELSE inh.path_value::public.ltree
            END
            ELSE p.path
        END AS path,
    p.path AS global_path,
    direct.top_order,
    COALESCE(direct."order", (EXTRACT(epoch FROM p.created_at) * 1000::numeric)::double precision) AS "order",
    inh.pomodoro,
    inh.color,
    p.key,
    p.team_id,
    COALESCE(upu.unread, false) AS unread,
    'member'::text AS role,
    inh.attention_window,
    inh.see_within_requests,
    inh.see_within_updates,
    COALESCE(direct.attention_window_set, false) AS attention_window_set,
    COALESCE(direct.see_within_requests_set, false) AS see_within_requests_set,
    COALESCE(direct.see_within_updates_set, false) AS see_within_updates_set,
    p.inherit_members
   FROM public.priority p
     LEFT JOIN user_root ur ON ur.user_id = p.user_id
     LEFT JOIN direct_settings direct ON direct.user_id = p.user_id AND direct.priority_id = p.id
     LEFT JOIN inherited_settings inh ON inh.user_id = p.user_id AND inh.priority_id = p.id
     LEFT JOIN "user".priority_unread upu ON upu.user_id = p.user_id AND upu.priority_id = p.id;
-- Modify "priority_expanded" view
CREATE OR REPLACE VIEW "user"."priority_expanded" (
  "user_id",
  "priority_id",
  "joined_at",
  "archived_at",
  "role",
  "path"
) AS SELECT p.user_id,
    p.id AS priority_id,
    p.created_at AS joined_at,
    p.archived_at,
    'member'::text AS role,
        CASE
            WHEN inherited.path_value IS NOT NULL THEN
            CASE
                WHEN inherited.path_source IS NOT NULL AND p.path OPERATOR(public.<>) inherited.path_source::public.ltree AND public.subpath(p.path, public.nlevel(inherited.path_source::public.ltree)) OPERATOR(public.<>) ''::public.ltree THEN inherited.path_value::public.ltree OPERATOR(public.||) public.subpath(p.path, public.nlevel(inherited.path_source::public.ltree))
                ELSE inherited.path_value::public.ltree
            END
            ELSE p.path
        END AS path
   FROM public.priority p
     LEFT JOIN ( SELECT priority_setting_inherited.user_id,
            priority_setting_inherited.priority_id,
            max(
                CASE
                    WHEN priority_setting_inherited.key = 'path'::text THEN priority_setting_inherited.value #>> '{}'::text[]
                    ELSE NULL::text
                END) AS path_value,
            max(
                CASE
                    WHEN priority_setting_inherited.key = 'path'::text THEN priority_setting_inherited.source_path::text
                    ELSE NULL::text
                END) AS path_source
           FROM public.priority_setting_inherited
          GROUP BY priority_setting_inherited.user_id, priority_setting_inherited.priority_id) inherited ON inherited.user_id = p.user_id AND inherited.priority_id = p.id;
