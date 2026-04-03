-- Drop "twist" view
DROP VIEW "user"."twist";
-- Modify "twist" table
ALTER TABLE "public"."twist" ADD COLUMN "shared" boolean NOT NULL DEFAULT false, ADD COLUMN "key_option" text NULL;
-- Modify "secure_option" table
ALTER TABLE "public"."secure_option" DROP CONSTRAINT "secure_option_priority_twist_id_key_key", ADD COLUMN "user_id" uuid NULL, ADD CONSTRAINT "secure_option_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."user" ("id") ON UPDATE NO ACTION ON DELETE CASCADE;
-- Create index "idx_secure_option_per_user" to table: "secure_option"
CREATE UNIQUE INDEX "idx_secure_option_per_user" ON "public"."secure_option" ("priority_twist_id", "key", "user_id") WHERE (user_id IS NOT NULL);
-- Create index "idx_secure_option_shared" to table: "secure_option"
CREATE UNIQUE INDEX "idx_secure_option_shared" ON "public"."secure_option" ("priority_twist_id", "key") WHERE (user_id IS NULL);
-- Create "twist" view
CREATE VIEW "user"."twist" (
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
  "config",
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
           FROM public.priority_twist_connection ptc2
          WHERE ptc2.priority_twist_id = pt.id AND ptc2.user_id = upe.user_id)) AS updated_at,
    pt.archived_at,
    pt.priority_id,
    pt.twist_id,
    t.environment AS twist_environment,
    t.is_source,
    t.shared,
    t.key_option,
    pt.owner_id,
    pt.name,
    pt.config,
    t.logo_url,
    t.logo_url_dark,
    ( SELECT jsonb_agg(lt.value) AS jsonb_agg
           FROM jsonb_array_elements(t.permissions -> '_providers'::text) p(value),
            LATERAL jsonb_array_elements(p.value -> 'linkTypes'::text) lt(value)) AS link_types,
    COALESCE((t.permissions ->> '_default_mention_created'::text)::boolean, false) AS default_mention_created,
    COALESCE((t.permissions ->> '_default_mention_mentioned'::text)::boolean, false) AS default_mention_mentioned,
        CASE
            WHEN t.shared THEN (EXISTS ( SELECT 1
               FROM public.priority_twist_connection ptc
              WHERE ptc.priority_twist_id = pt.id))
            ELSE (EXISTS ( SELECT 1
               FROM public.priority_twist_connection ptc
              WHERE ptc.priority_twist_id = pt.id AND ptc.user_id = upe.user_id))
        END AS user_connected
   FROM public.priority_twist pt
     JOIN "user".priority_expanded upe ON upe.priority_id = pt.priority_id
     JOIN public.twist t ON pt.twist_id = t.id
UNION ALL
 SELECT pt.owner_id AS user_id,
    pt.id,
    pt.created_at,
    GREATEST(pt.updated_at, t.updated_at, ( SELECT max(ptc2.connected_at) AS max
           FROM public.priority_twist_connection ptc2
          WHERE ptc2.priority_twist_id = pt.id AND ptc2.user_id = pt.owner_id)) AS updated_at,
    pt.archived_at,
    pt.priority_id,
    pt.twist_id,
    t.environment AS twist_environment,
    t.is_source,
    t.shared,
    t.key_option,
    pt.owner_id,
    pt.name,
    pt.config,
    t.logo_url,
    t.logo_url_dark,
    ( SELECT jsonb_agg(lt.value) AS jsonb_agg
           FROM jsonb_array_elements(t.permissions -> '_providers'::text) p(value),
            LATERAL jsonb_array_elements(p.value -> 'linkTypes'::text) lt(value)) AS link_types,
    COALESCE((t.permissions ->> '_default_mention_created'::text)::boolean, false) AS default_mention_created,
    COALESCE((t.permissions ->> '_default_mention_mentioned'::text)::boolean, false) AS default_mention_mentioned,
        CASE
            WHEN t.shared THEN (EXISTS ( SELECT 1
               FROM public.priority_twist_connection ptc
              WHERE ptc.priority_twist_id = pt.id))
            ELSE (EXISTS ( SELECT 1
               FROM public.priority_twist_connection ptc
              WHERE ptc.priority_twist_id = pt.id AND ptc.user_id = pt.owner_id))
        END AS user_connected
   FROM public.priority_twist pt
     JOIN public.twist t ON pt.twist_id = t.id
  WHERE t.is_source = true AND pt.priority_id IS NULL;

-- Backfill: mark existing no-provider sources as shared
UPDATE twist SET shared = true
WHERE is_source = true
  AND (permissions -> '_providers' IS NULL
       OR jsonb_array_length(COALESCE(permissions -> '_providers', '[]'::jsonb)) = 0);

-- Backfill: infer key_option from options schema for shared sources
UPDATE twist SET key_option = so.key
FROM (
    SELECT DISTINCT ON (t.id) t.id AS twist_id, so_key.key
    FROM twist t, jsonb_each(t.options::jsonb) AS so_key(key, value)
    WHERE t.shared = true
      AND t.options IS NOT NULL
      AND (so_key.value ->> 'secure')::boolean = true
    ORDER BY t.id
) so
WHERE twist.id = so.twist_id AND twist.key_option IS NULL;

-- Backfill: create connection rows for existing shared sources with config
INSERT INTO priority_twist_connection (priority_twist_id, user_id, provider, actor_id)
SELECT pt.id, pt.owner_id, '_key', pt.owner_id
FROM priority_twist pt
JOIN twist t ON pt.twist_id = t.id
WHERE t.shared = true
  AND pt.config IS NOT NULL AND pt.config::text != '{}'
  AND pt.archived_at IS NULL
ON CONFLICT DO NOTHING;
