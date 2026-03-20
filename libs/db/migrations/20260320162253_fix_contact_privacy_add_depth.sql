-- Drop "actor" view
DROP VIEW "user"."actor";
-- Drop "priority_actor" view
DROP VIEW "user"."priority_actor";
-- Create "priority_actor" view
CREATE VIEW "user"."priority_actor" (
  "user_id",
  "priority_path",
  "actor_id",
  "depth",
  "created_at",
  "updated_at",
  "archived_at"
) AS SELECT user_id,
    priority_path,
    actor_id,
    depth,
    created_at,
    updated_at,
    archived_at
   FROM ( SELECT ancestor_contacts.user_id,
            ancestor_contacts.priority_path,
            ancestor_contacts.actor_id,
            ancestor_contacts.depth,
            ancestor_contacts.created_at,
            ancestor_contacts.updated_at,
            ancestor_contacts.archived_at
           FROM ( SELECT DISTINCT ON (upe.user_id, upe.path, pc.contact_id) upe.user_id,
                    upe.path AS priority_path,
                    pc.contact_id AS actor_id,
                    public.nlevel(p.path) - public.nlevel(ancestor.path) AS depth,
                    LEAST(COALESCE(pc.created_at, c.created_at), COALESCE(c.created_at, pc.created_at)) AS created_at,
                    GREATEST(pc.updated_at, c.updated_at) AS updated_at,
                        CASE
                            WHEN pc.invited_by IS NOT NULL AND pc.invited_at IS NULL THEN pc.updated_at
                            ELSE c.archived_at
                        END AS archived_at
                   FROM "user".priority_expanded upe
                     JOIN public.priority p ON p.id = upe.priority_id
                     JOIN public.priority ancestor ON p.path OPERATOR(public.<@) ancestor.path
                     JOIN "user".priority_expanded upe_ancestor ON upe_ancestor.user_id = upe.user_id AND upe_ancestor.priority_id = ancestor.id
                     JOIN public.priority_contact pc ON pc.priority_id = ancestor.id
                     JOIN public.contact c ON c.id = pc.contact_id
                  WHERE NOT (upe.role = 'viewer'::text AND c.user_id IS NOT NULL AND "user".get_effective_role(c.user_id, upe.priority_id) = 'viewer'::text) AND (c.user_id IS NULL OR c."primary" = true)
                  ORDER BY upe.user_id, upe.path, pc.contact_id, (public.nlevel(ancestor.path)) DESC) ancestor_contacts
        UNION ALL
         SELECT upe.user_id,
            upe.path AS priority_path,
            pt.id AS actor_id,
            0 AS depth,
            pt.created_at,
            pt.updated_at,
            pt.archived_at
           FROM "user".priority_expanded upe
             JOIN public.priority_twist pt ON pt.priority_id = upe.priority_id
        UNION ALL
         SELECT upe.user_id,
            upe.path AS priority_path,
            pt.id AS actor_id,
            0 AS depth,
            pt.created_at,
            GREATEST(pt.updated_at, sc.updated_at) AS updated_at,
            pt.archived_at
           FROM "user".priority_expanded upe
             JOIN public.source_channel sc ON sc.priority_id = upe.priority_id
             JOIN public.priority_twist pt ON pt.id = sc.priority_twist_id AND pt.priority_id IS NULL) actors;
-- Create "actor" view
CREATE VIEW "user"."actor" (
  "user_id",
  "id",
  "created_at",
  "updated_at",
  "archived_at",
  "min_depth",
  "type",
  "name",
  "email",
  "avatar_url",
  "self"
) AS WITH upa_agg AS (
         SELECT upa.user_id,
            upa.actor_id,
            COALESCE(min(upa.updated_at) FILTER (WHERE upa.archived_at IS NULL), max(upa.archived_at)) AS updated_at,
                CASE
                    WHEN count(*) FILTER (WHERE upa.archived_at IS NULL) = 0 THEN max(upa.archived_at)
                    ELSE NULL::timestamp with time zone
                END AS archived_at,
            min(upa.depth) FILTER (WHERE upa.archived_at IS NULL) AS min_depth
           FROM "user".priority_actor upa
          GROUP BY upa.user_id, upa.actor_id
        )
 SELECT ua.user_id,
    a.id,
    a.created_at,
    GREATEST(ua.updated_at, a.updated_at) AS updated_at,
    COALESCE(a.archived_at, ua.archived_at) AS archived_at,
    ua.min_depth,
    a.type,
    a.name,
    a.email,
    a.avatar_url,
    (EXISTS ( SELECT 1
           FROM public.contact c
          WHERE c.id = a.id AND c.user_id = ua.user_id)) AS self
   FROM upa_agg ua
     JOIN public.actor a ON a.id = ua.actor_id;
