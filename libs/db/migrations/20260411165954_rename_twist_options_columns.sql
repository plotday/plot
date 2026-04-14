-- Rename columns in place so any dependent views/functions follow the rename.
ALTER TABLE "public"."twist" RENAME COLUMN "options" TO "options_schema";
ALTER TABLE "public"."twist_instance" RENAME COLUMN "config" TO "options";
-- Rename a view column from "config" to "options"
ALTER VIEW "public"."priority_child_twist" RENAME COLUMN "config" TO "options";
-- Modify "priority_child_twist" view
CREATE OR REPLACE VIEW "public"."priority_child_twist" (
  "id",
  "priority_id",
  "twist_id",
  "owner_id",
  "name",
  "options",
  "created_at",
  "updated_at",
  "archived_at",
  "suspended_at",
  "version",
  "twist_environment",
  "is_source",
  "author_name",
  "author_email",
  "author_url",
  "priority_child_id"
) AS SELECT pt.id,
    pt.priority_id,
    pt.twist_id,
    pt.owner_id,
    pt.name,
    pt.options,
    pt.created_at,
    pt.updated_at,
    pt.archived_at,
    pt.suspended_at,
    t.version,
    t.environment AS twist_environment,
    t.is_source,
    p.name AS author_name,
    p.email AS author_email,
    p.url AS author_url,
    child_p.id AS priority_child_id
   FROM public.twist_instance pt
     JOIN public.priority install_p ON pt.priority_id = install_p.id
     JOIN public.priority child_p ON child_p.path OPERATOR(public.<@) install_p.path
     JOIN public.twist t ON pt.twist_id = t.id
     JOIN public.twist_admin ta ON t.twist_admin_id = ta.id
     LEFT JOIN public.publisher p ON ta.publisher_id = p.id
  WHERE pt.archived_at IS NULL;
-- Rename a view column from "config" to "options"
ALTER VIEW "user"."twist" RENAME COLUMN "config" TO "options";
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
  "shared",
  "key_option",
  "owner_id",
  "name",
  "options",
  "logo_url",
  "logo_url_dark",
  "link_types",
  "default_mention_created",
  "default_mention_mentioned",
  "user_connected"
) AS SELECT upe.user_id,
    pt.id,
    pt.created_at,
    GREATEST(pt.updated_at, t.updated_at, ( SELECT max(ptc2.connected_at) AS max
           FROM public.twist_instance_connection ptc2
          WHERE ptc2.twist_instance_id = pt.id AND ptc2.user_id = upe.user_id)) AS updated_at,
    pt.archived_at,
    pt.priority_id,
    pt.twist_id,
    t.environment AS twist_environment,
    t.is_source,
    t.shared,
    t.key_option,
    pt.owner_id,
    pt.name,
    pt.options,
    t.logo_url,
    t.logo_url_dark,
    ( SELECT jsonb_agg(lt.value) AS jsonb_agg
           FROM jsonb_array_elements(t.permissions -> '_providers'::text) p(value),
            LATERAL jsonb_array_elements(p.value -> 'linkTypes'::text) lt(value)) AS link_types,
    COALESCE((t.permissions ->> '_default_mention_created'::text)::boolean, false) AS default_mention_created,
    COALESCE((t.permissions ->> '_default_mention_mentioned'::text)::boolean, false) AS default_mention_mentioned,
        CASE
            WHEN t.shared THEN (EXISTS ( SELECT 1
               FROM public.twist_instance_connection ptc
              WHERE ptc.twist_instance_id = pt.id))
            ELSE (EXISTS ( SELECT 1
               FROM public.twist_instance_connection ptc
              WHERE ptc.twist_instance_id = pt.id AND ptc.user_id = upe.user_id))
        END AS user_connected
   FROM public.twist_instance pt
     JOIN "user".priority_expanded upe ON upe.priority_id = pt.priority_id
     JOIN public.twist t ON pt.twist_id = t.id
UNION ALL
 SELECT pt.owner_id AS user_id,
    pt.id,
    pt.created_at,
    GREATEST(pt.updated_at, t.updated_at, ( SELECT max(ptc2.connected_at) AS max
           FROM public.twist_instance_connection ptc2
          WHERE ptc2.twist_instance_id = pt.id AND ptc2.user_id = pt.owner_id)) AS updated_at,
    pt.archived_at,
    pt.priority_id,
    pt.twist_id,
    t.environment AS twist_environment,
    t.is_source,
    t.shared,
    t.key_option,
    pt.owner_id,
    pt.name,
    pt.options,
    t.logo_url,
    t.logo_url_dark,
    ( SELECT jsonb_agg(lt.value) AS jsonb_agg
           FROM jsonb_array_elements(t.permissions -> '_providers'::text) p(value),
            LATERAL jsonb_array_elements(p.value -> 'linkTypes'::text) lt(value)) AS link_types,
    COALESCE((t.permissions ->> '_default_mention_created'::text)::boolean, false) AS default_mention_created,
    COALESCE((t.permissions ->> '_default_mention_mentioned'::text)::boolean, false) AS default_mention_mentioned,
        CASE
            WHEN t.shared THEN (EXISTS ( SELECT 1
               FROM public.twist_instance_connection ptc
              WHERE ptc.twist_instance_id = pt.id))
            ELSE (EXISTS ( SELECT 1
               FROM public.twist_instance_connection ptc
              WHERE ptc.twist_instance_id = pt.id AND ptc.user_id = pt.owner_id))
        END AS user_connected
   FROM public.twist_instance pt
     JOIN public.twist t ON pt.twist_id = t.id
  WHERE t.is_source = true AND pt.priority_id IS NULL;
