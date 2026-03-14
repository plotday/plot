-- Create "upsert_priority_attention" function
CREATE FUNCTION "user"."upsert_priority_attention" ("p_user_id" uuid, "p_priority_id" uuid, "p_attention_window" jsonb DEFAULT NULL::jsonb, "p_set_attention_window" boolean DEFAULT false, "p_see_within_requests" jsonb DEFAULT NULL::jsonb, "p_see_within_updates" jsonb DEFAULT NULL::jsonb, "p_set_see_within_requests" boolean DEFAULT false, "p_set_see_within_updates" boolean DEFAULT false) RETURNS void LANGUAGE plpgsql SET "search_path" = public, "user" AS $$
BEGIN
    PERFORM "user".assert_priority_access(p_user_id, p_priority_id);
    IF p_set_attention_window THEN
        IF p_attention_window IS NOT NULL THEN
            INSERT INTO priority_setting (user_id, priority_id, key, value)
            VALUES (p_user_id, p_priority_id, 'attention_window', p_attention_window)
            ON CONFLICT (user_id, priority_id, key) DO UPDATE SET value = EXCLUDED.value;
        ELSE
            DELETE FROM priority_setting
            WHERE priority_setting.user_id = p_user_id
              AND priority_setting.priority_id = p_priority_id AND key = 'attention_window';
        END IF;
    END IF;
    IF p_set_see_within_requests THEN
        IF p_see_within_requests IS NOT NULL THEN
            INSERT INTO priority_setting (user_id, priority_id, key, value)
            VALUES (p_user_id, p_priority_id, 'see_within_requests', p_see_within_requests)
            ON CONFLICT (user_id, priority_id, key) DO UPDATE SET value = EXCLUDED.value;
        ELSE
            DELETE FROM priority_setting
            WHERE priority_setting.user_id = p_user_id
              AND priority_setting.priority_id = p_priority_id AND key = 'see_within_requests';
        END IF;
    END IF;
    IF p_set_see_within_updates THEN
        IF p_see_within_updates IS NOT NULL THEN
            INSERT INTO priority_setting (user_id, priority_id, key, value)
            VALUES (p_user_id, p_priority_id, 'see_within_updates', p_see_within_updates)
            ON CONFLICT (user_id, priority_id, key) DO UPDATE SET value = EXCLUDED.value;
        ELSE
            DELETE FROM priority_setting
            WHERE priority_setting.user_id = p_user_id
              AND priority_setting.priority_id = p_priority_id AND key = 'see_within_updates';
        END IF;
    END IF;
END;
$$;
-- Drop "priority" view
DROP VIEW IF EXISTS "user"."priority" CASCADE;
-- Modify "priority_setting_inherited" view
CREATE OR REPLACE VIEW "public"."priority_setting_inherited" (
  "user_id",
  "priority_id",
  "key",
  "value",
  "source_path"
) AS WITH all_sources AS (
         SELECT ps.user_id,
            p.id AS priority_id,
            ps.key,
            ps.value,
            parent.path AS source_path,
            public.nlevel(p.path) - public.nlevel(parent.path) AS distance,
            0 AS source_type
           FROM public.priority_setting ps
             JOIN public.priority parent ON ps.priority_id = parent.id
             JOIN public.priority p ON p.path OPERATOR(public.<@) parent.path
          WHERE ps.key = ANY (ARRAY['pomodoro'::text, 'color'::text, 'path'::text, 'attention_window'::text, 'see_within_requests'::text, 'see_within_updates'::text])
        UNION ALL
         SELECT pu.user_id,
            p.id AS priority_id,
            'color'::text AS key,
            to_jsonb(parent.color) AS value,
            parent.path AS source_path,
            public.nlevel(p.path) - public.nlevel(parent.path) AS distance,
            1 AS source_type
           FROM public.priority_user pu
             JOIN public.priority root ON pu.priority_id = root.id
             JOIN public.priority p ON p.path OPERATOR(public.<@) root.path
             JOIN public.priority parent ON p.path OPERATOR(public.<@) parent.path
          WHERE parent.color IS NOT NULL
        )
 SELECT DISTINCT ON (user_id, priority_id, key) user_id,
    priority_id,
    key,
    value,
    source_path
   FROM all_sources
  ORDER BY user_id, priority_id, key, distance, source_type;
-- Create "priority" view
CREATE VIEW "user"."priority" (
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
  "organization_id",
  "unread",
  "role",
  "attention_window",
  "see_within_requests",
  "see_within_updates",
  "attention_window_set",
  "see_within_requests_set",
  "see_within_updates_set"
) AS SELECT pu.user_id,
    p.id,
    p.created_at,
    GREATEST(settings.updated_at, pu.updated_at, p.updated_at, COALESCE(upu.updated_at, '1970-01-01 00:00:00+00'::timestamp with time zone)) AS updated_at,
    GREATEST(pu.archived_at, p.archived_at) AS archived_at,
    p.created_by,
    p.updated_by,
    (pu.personal = true OR p.organization_id IS NOT NULL) AND p.id = root.id AS root,
    user_root.path OPERATOR(public.@>) p.path AS personal,
    COALESCE(settings.title, p.title) AS title,
        CASE
            WHEN inherited.path_value IS NOT NULL THEN
            CASE
                WHEN inherited.path_source IS NOT NULL AND p.path OPERATOR(public.<>) inherited.path_source::public.ltree AND public.subpath(p.path, public.nlevel(inherited.path_source::public.ltree)) OPERATOR(public.<>) ''::public.ltree THEN inherited.path_value::public.ltree OPERATOR(public.||) public.subpath(p.path, public.nlevel(inherited.path_source::public.ltree))
                ELSE inherited.path_value::public.ltree
            END
            WHEN user_root.path OPERATOR(public.@>) p.path THEN p.path
            ELSE user_root.path OPERATOR(public.||) p.path
        END AS path,
    p.path AS global_path,
    settings.top_order,
    COALESCE(settings."order", (EXTRACT(epoch FROM p.created_at) * 1000::numeric)::double precision) AS "order",
    inherited.pomodoro,
    inherited.color,
    p.key,
    p.organization_id,
    COALESCE(upu.unread, false) AS unread,
    "user".get_effective_role(pu.user_id, p.id) AS role,
    inherited.attention_window,
    inherited.see_within_requests,
    inherited.see_within_updates,
    COALESCE(settings.attention_window_set, false) AS attention_window_set,
    COALESCE(settings.see_within_requests_set, false) AS see_within_requests_set,
    COALESCE(settings.see_within_updates_set, false) AS see_within_updates_set
   FROM public.priority_user pu
     JOIN public.priority root ON pu.priority_id = root.id
     JOIN public.priority_user pu_root ON pu.user_id = pu_root.user_id AND pu_root.personal = true
     JOIN public.priority user_root ON pu_root.priority_id = user_root.id
     JOIN public.priority p ON root.path OPERATOR(public.@>) p.path
     LEFT JOIN ( SELECT priority_setting.user_id,
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
          GROUP BY priority_setting.user_id, priority_setting.priority_id) settings ON settings.user_id = pu.user_id AND settings.priority_id = p.id
     LEFT JOIN ( SELECT priority_setting_inherited.user_id,
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
                END) AS path_source
           FROM public.priority_setting_inherited
          GROUP BY priority_setting_inherited.user_id, priority_setting_inherited.priority_id) inherited ON inherited.user_id = pu.user_id AND inherited.priority_id = p.id
     LEFT JOIN "user".priority_unread upu ON upu.user_id = pu.user_id AND upu.priority_id = p.id
  WHERE pu.archived_at IS NULL;
-- Drop "upsert_priority_attention" function
DROP FUNCTION "user"."upsert_priority_attention" (uuid, uuid, jsonb, jsonb, boolean, boolean, jsonb, jsonb, boolean, boolean);
