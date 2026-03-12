-- Create enum type "ai_provider"
CREATE TYPE "public"."ai_provider" AS ENUM ('openai', 'anthropic', 'google');
-- Create "ai_key" table
CREATE TABLE "public"."ai_key" (
  "id" bigint NOT NULL GENERATED ALWAYS AS IDENTITY,
  "created_at" timestamptz NOT NULL DEFAULT now(),
  "updated_at" timestamptz NOT NULL DEFAULT now(),
  "user_id" uuid NULL,
  "organization_id" bigint NULL,
  "provider" "public"."ai_provider" NOT NULL,
  "encrypted_key" text NOT NULL,
  "key_suffix" text NOT NULL,
  "iv" text NOT NULL,
  PRIMARY KEY ("id"),
  CONSTRAINT "ai_key_organization_id_fkey" FOREIGN KEY ("organization_id") REFERENCES "public"."organization" ("id") ON UPDATE NO ACTION ON DELETE CASCADE,
  CONSTRAINT "ai_key_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."user" ("id") ON UPDATE NO ACTION ON DELETE CASCADE,
  CONSTRAINT "ai_key_scope_check" CHECK (((user_id IS NOT NULL) AND (organization_id IS NULL)) OR ((user_id IS NULL) AND (organization_id IS NOT NULL)))
);
-- Create index "idx_ai_key_org_id" to table: "ai_key"
CREATE INDEX "idx_ai_key_org_id" ON "public"."ai_key" ("organization_id") WHERE (organization_id IS NOT NULL);
-- Create index "idx_ai_key_org_provider" to table: "ai_key"
CREATE UNIQUE INDEX "idx_ai_key_org_provider" ON "public"."ai_key" ("organization_id", "provider") WHERE (organization_id IS NOT NULL);
-- Create index "idx_ai_key_user_id" to table: "ai_key"
CREATE INDEX "idx_ai_key_user_id" ON "public"."ai_key" ("user_id") WHERE (user_id IS NOT NULL);
-- Create index "idx_ai_key_user_provider" to table: "ai_key"
CREATE UNIQUE INDEX "idx_ai_key_user_provider" ON "public"."ai_key" ("user_id", "provider") WHERE (user_id IS NOT NULL);
-- Create trigger "set_ai_key_updated_at"
CREATE TRIGGER "set_ai_key_updated_at" BEFORE INSERT OR UPDATE ON "public"."ai_key" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at"();
-- Create "sync_user_for_priority_twist_connection" function
CREATE FUNCTION "public"."sync_user_for_priority_twist_connection" () RETURNS trigger LANGUAGE plpgsql SET "search_path" = public AS $$
DECLARE
    v_max_connected_at timestamptz;
    v_user_id uuid;
BEGIN
    SELECT
        MAX(connected_at) INTO v_max_connected_at
    FROM
        new_table;
    -- Notify each affected user directly
    FOR v_user_id IN SELECT DISTINCT
        user_id
    FROM
        new_table
    ORDER BY
        user_id LOOP
            INSERT INTO user_sync (user_id, entity, last_update_at)
                VALUES (v_user_id, 'priority_twist', v_max_connected_at)
            ON CONFLICT (user_id, entity)
                DO UPDATE SET
                    last_update_at = GREATEST (user_sync.last_update_at, EXCLUDED.last_update_at);
        END LOOP;
    RETURN NULL;
END;
$$;
-- Create "priority_twist_connection" table
CREATE TABLE "public"."priority_twist_connection" (
  "priority_twist_id" uuid NOT NULL,
  "user_id" uuid NOT NULL,
  "provider" text NOT NULL,
  "actor_id" uuid NOT NULL,
  "connected_at" timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY ("priority_twist_id", "user_id", "provider"),
  CONSTRAINT "priority_twist_connection_priority_twist_id_fkey" FOREIGN KEY ("priority_twist_id") REFERENCES "public"."priority_twist" ("id") ON UPDATE NO ACTION ON DELETE CASCADE,
  CONSTRAINT "priority_twist_connection_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."user" ("id") ON UPDATE NO ACTION ON DELETE CASCADE
);
-- Create index "idx_ptc_priority_twist" to table: "priority_twist_connection"
CREATE INDEX "idx_ptc_priority_twist" ON "public"."priority_twist_connection" ("priority_twist_id");
-- Create index "idx_ptc_user" to table: "priority_twist_connection"
CREATE INDEX "idx_ptc_user" ON "public"."priority_twist_connection" ("user_id");
-- Create trigger "user_sync_priority_twist_connection_delete"
CREATE TRIGGER "user_sync_priority_twist_connection_delete" AFTER DELETE ON "public"."priority_twist_connection" REFERENCING OLD TABLE AS "new_table" FOR EACH STATEMENT EXECUTE FUNCTION "public"."sync_user_for_priority_twist_connection"();
-- Create trigger "user_sync_priority_twist_connection_insert"
CREATE TRIGGER "user_sync_priority_twist_connection_insert" AFTER INSERT ON "public"."priority_twist_connection" REFERENCING NEW TABLE AS "new_table" FOR EACH STATEMENT EXECUTE FUNCTION "public"."sync_user_for_priority_twist_connection"();
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
  "logo_url",
  "logo_url_dark",
  "link_types",
  "default_mention_created",
  "default_mention_mentioned",
  "user_connected"
) AS SELECT upe.user_id,
    pt.id,
    pt.created_at,
    GREATEST(pt.updated_at, t.updated_at) AS updated_at,
    pt.archived_at,
    pt.priority_id,
    pt.twist_id,
    t.environment AS twist_environment,
    t.is_source,
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
    (EXISTS ( SELECT 1
           FROM public.priority_twist_connection ptc
          WHERE ptc.priority_twist_id = pt.id AND ptc.user_id = upe.user_id)) AS user_connected
   FROM public.priority_twist pt
     JOIN "user".priority_expanded upe ON upe.priority_id = pt.priority_id
     JOIN public.twist t ON pt.twist_id = t.id
UNION ALL
 SELECT pt.owner_id AS user_id,
    pt.id,
    pt.created_at,
    GREATEST(pt.updated_at, t.updated_at) AS updated_at,
    pt.archived_at,
    pt.priority_id,
    pt.twist_id,
    t.environment AS twist_environment,
    t.is_source,
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
    (EXISTS ( SELECT 1
           FROM public.priority_twist_connection ptc
          WHERE ptc.priority_twist_id = pt.id AND ptc.user_id = pt.owner_id)) AS user_connected
   FROM public.priority_twist pt
     JOIN public.twist t ON pt.twist_id = t.id
  WHERE t.is_source = true AND pt.priority_id IS NULL;
