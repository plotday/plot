-- Modify "actor" view
CREATE OR REPLACE VIEW "user"."actor" (
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
     JOIN public.actor a ON a.id = ua.actor_id
UNION ALL
 SELECT c.user_id,
    a.id,
    a.created_at,
    a.updated_at,
    a.archived_at,
    NULL::integer AS min_depth,
    a.type,
    a.name,
    a.email,
    a.avatar_url,
    true AS self
   FROM public.contact c
     JOIN public.actor a ON a.id = c.id
  WHERE c.user_id IS NOT NULL AND c."primary" = false;
