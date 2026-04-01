-- Modify "priority_expanded" view
CREATE OR REPLACE VIEW "user"."priority_expanded" (
  "user_id",
  "priority_id",
  "joined_at",
  "archived_at",
  "role",
  "path"
) AS WITH base AS (
         SELECT pu.user_id,
            c.child_id AS priority_id,
            min(pu.created_at) AS joined_at,
                CASE
                    WHEN bool_or(pu.archived_at IS NULL AND c.archived_at IS NULL) THEN NULL::timestamp with time zone
                    ELSE LEAST(min(pu.archived_at), min(c.archived_at))
                END AS archived_at,
                CASE
                    WHEN bool_or(pu.role = 'member'::text) THEN 'member'::text
                    ELSE 'viewer'::text
                END AS role
           FROM public.priority_user pu
             JOIN public.priority_child c ON pu.priority_id = c.priority_id
          GROUP BY pu.user_id, c.child_id
        )
 SELECT b.user_id,
    b.priority_id,
    b.joined_at,
    b.archived_at,
    b.role,
        CASE
            WHEN inherited.path_value IS NOT NULL THEN
            CASE
                WHEN inherited.path_source IS NOT NULL AND p.path OPERATOR(public.<>) inherited.path_source::public.ltree AND public.subpath(p.path, public.nlevel(inherited.path_source::public.ltree)) OPERATOR(public.<>) ''::public.ltree THEN inherited.path_value::public.ltree OPERATOR(public.||) public.subpath(p.path, public.nlevel(inherited.path_source::public.ltree))
                ELSE inherited.path_value::public.ltree
            END
            WHEN user_root.path OPERATOR(public.@>) p.path THEN p.path
            ELSE user_root.path OPERATOR(public.||) p.path
        END AS path
   FROM base b
     LEFT JOIN public.priority p ON p.id = b.priority_id
     LEFT JOIN public.priority_user pu_root ON b.user_id = pu_root.user_id AND pu_root.personal = true
     LEFT JOIN public.priority user_root ON pu_root.priority_id = user_root.id
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
          GROUP BY priority_setting_inherited.user_id, priority_setting_inherited.priority_id) inherited ON inherited.user_id = b.user_id AND inherited.priority_id = b.priority_id;
