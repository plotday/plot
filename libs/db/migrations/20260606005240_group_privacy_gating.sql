-- Drop "group" view
DROP VIEW "user"."group";
-- Create "group" view
CREATE VIEW "user"."group" (
  "user_id",
  "id",
  "created_at",
  "updated_at",
  "seq",
  "archived_at",
  "name",
  "type",
  "privacy",
  "key",
  "join_policy",
  "team_id",
  "auto_maintained",
  "is_admin",
  "is_member",
  "can_post",
  "can_address",
  "member_contact_ids"
) AS SELECT u.id AS user_id,
    g.id,
    g.created_at,
    g.updated_at,
    g.seq,
    g.archived_at,
    g.name,
    g.type,
    g.privacy,
    g.key,
    g.join_policy,
    g.team_id,
    g.auto_maintained,
    (EXISTS ( SELECT 1
           FROM public.group_admin ga
          WHERE ga.group_id = g.id AND ga.user_id = u.id)) AS is_admin,
    (EXISTS ( SELECT 1
           FROM public.group_member gm
             JOIN public.user_contact uc ON uc.contact_id = gm.contact_id AND uc.linked = true AND uc.archived_at IS NULL
          WHERE gm.group_id = g.id AND uc.user_id = u.id)) AS is_member,
    (EXISTS ( SELECT 1
           FROM public.group_admin ga
          WHERE ga.group_id = g.id AND ga.user_id = u.id)) OR g.privacy = 'open'::public.group_privacy AND (EXISTS ( SELECT 1
           FROM public.group_member gm
             JOIN public.user_contact uc ON uc.contact_id = gm.contact_id AND uc.linked = true AND uc.archived_at IS NULL
          WHERE gm.group_id = g.id AND uc.user_id = u.id)) AS can_post,
    (EXISTS ( SELECT 1
           FROM public.group_admin ga
          WHERE ga.group_id = g.id AND ga.user_id = u.id)) OR g.privacy = 'open'::public.group_privacy AND (EXISTS ( SELECT 1
           FROM public.group_member gm
             JOIN public.user_contact uc ON uc.contact_id = gm.contact_id AND uc.linked = true AND uc.archived_at IS NULL
          WHERE gm.group_id = g.id AND uc.user_id = u.id)) AS can_address,
        CASE
            WHEN (EXISTS ( SELECT 1
               FROM public.group_admin ga
              WHERE ga.group_id = g.id AND ga.user_id = u.id)) THEN ( SELECT COALESCE(array_agg(gm2.contact_id), ARRAY[]::uuid[]) AS "coalesce"
               FROM public.group_member gm2
              WHERE gm2.group_id = g.id)
            WHEN g.privacy = 'open'::public.group_privacy AND (EXISTS ( SELECT 1
               FROM public.group_member gm
                 JOIN public.user_contact uc ON uc.contact_id = gm.contact_id AND uc.linked = true AND uc.archived_at IS NULL
              WHERE gm.group_id = g.id AND uc.user_id = u.id)) THEN ( SELECT COALESCE(array_agg(gm2.contact_id), ARRAY[]::uuid[]) AS "coalesce"
               FROM public.group_member gm2
              WHERE gm2.group_id = g.id)
            ELSE ARRAY[]::uuid[]
        END AS member_contact_ids
   FROM public."user" u
     CROSS JOIN public."group" g
  WHERE g.archived_at IS NULL AND ((g.type = ANY (ARRAY['public'::public.group_type, 'announce'::public.group_type])) OR g.key = '@plot.team'::text OR g.type = 'team'::public.group_type AND (EXISTS ( SELECT 1
           FROM public.team_user tu
          WHERE tu.team_id = g.team_id AND tu.user_id = u.id)) OR g.type = 'private'::public.group_type AND ((EXISTS ( SELECT 1
           FROM public.group_admin ga
          WHERE ga.group_id = g.id AND ga.user_id = u.id)) OR (EXISTS ( SELECT 1
           FROM public.group_member gm
             JOIN public.user_contact uc ON uc.contact_id = gm.contact_id AND uc.linked = true AND uc.archived_at IS NULL
          WHERE gm.group_id = g.id AND uc.user_id = u.id))));
