-- Modify "twist" view
CREATE OR REPLACE VIEW "user"."twist" (
  "user_id",
  "id",
  "created_at",
  "updated_at",
  "archived_at",
  "priority_id",
  "twist_id",
  "twist_environment",
  "is_source",
  "owner_id",
  "name",
  "config",
  "link_types"
) AS SELECT upe.user_id,
    pt.id,
    pt.created_at,
    pt.updated_at,
    pt.archived_at,
    pt.priority_id,
    pt.twist_id,
    t.environment AS twist_environment,
    t.is_source,
    pt.owner_id,
    pt.name,
    pt.config,
    ( SELECT jsonb_agg(lt.value) AS jsonb_agg
           FROM jsonb_array_elements(t.permissions -> '_providers'::text) p(value),
            LATERAL jsonb_array_elements(p.value -> 'linkTypes'::text) lt(value)) AS link_types
   FROM public.priority_twist pt
     JOIN "user".priority_expanded upe ON upe.priority_id = pt.priority_id
     JOIN public.twist t ON pt.twist_id = t.id;
