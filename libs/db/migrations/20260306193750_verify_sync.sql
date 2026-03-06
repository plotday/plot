-- Modify "priority_actor" view
CREATE OR REPLACE VIEW "user"."priority_actor" (
  "user_id",
  "priority_path",
  "actor_id",
  "created_at",
  "updated_at",
  "archived_at"
) AS SELECT user_id,
    priority_path,
    actor_id,
    created_at,
    updated_at,
    archived_at
   FROM ( SELECT upe.user_id,
            upe.path AS priority_path,
            pc.contact_id AS actor_id,
            LEAST(COALESCE(pc.created_at, c.created_at), COALESCE(c.created_at, pc.created_at)) AS created_at,
            GREATEST(pc.updated_at, c.updated_at) AS updated_at,
                CASE
                    WHEN pc.invited_by IS NOT NULL AND pc.invited_at IS NULL THEN pc.updated_at
                    ELSE c.archived_at
                END AS archived_at
           FROM "user".priority_expanded upe
             JOIN public.priority_contact pc ON pc.priority_id = upe.priority_id
             JOIN public.contact c ON c.id = pc.contact_id
        UNION ALL
         SELECT upe.user_id,
            upe.path AS priority_path,
            pt.id AS actor_id,
            pt.created_at,
            pt.updated_at,
            pt.archived_at
           FROM "user".priority_expanded upe
             JOIN public.priority_twist pt ON pt.priority_id = upe.priority_id
        UNION ALL
         SELECT upe.user_id,
            upe.path AS priority_path,
            pt.id AS actor_id,
            pt.created_at,
            GREATEST(pt.updated_at, sc.updated_at) AS updated_at,
            pt.archived_at
           FROM "user".priority_expanded upe
             JOIN public.source_channel sc ON sc.priority_id = upe.priority_id
             JOIN public.priority_twist pt ON pt.id = sc.priority_twist_id AND pt.priority_id IS NULL) actors;
