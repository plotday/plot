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
          WHERE ps.key = ANY (ARRAY['pomodoro'::text, 'color'::text, 'attention_window'::text, 'see_within_requests'::text, 'see_within_updates'::text])
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
-- Modify "priority_expanded" view
CREATE OR REPLACE VIEW "user"."priority_expanded" (
  "user_id",
  "priority_id",
  "joined_at",
  "archived_at",
  "role",
  "path"
) AS SELECT user_id,
    id AS priority_id,
    created_at AS joined_at,
    archived_at,
    'member'::text AS role,
    path
   FROM public.priority p;
-- Drop "upsert_priority_user" function
DROP FUNCTION "user"."upsert_priority_user";
-- Drop "priority_user" table
DROP TABLE "public"."priority_user";
-- Drop "sync_user_for_priority_user" function
DROP FUNCTION "public"."sync_user_for_priority_user";
