-- Modify "twist" table
ALTER TABLE "public"."twist" ADD COLUMN "seq" xid8 NOT NULL DEFAULT pg_current_xact_id();
-- Create index "idx_twist_seq" to table: "twist"
CREATE INDEX "idx_twist_seq" ON "public"."twist" ("seq");
-- Modify "set_twist_updated_at" trigger
CREATE OR REPLACE TRIGGER "set_twist_updated_at" BEFORE INSERT OR UPDATE ON "public"."twist" FOR EACH ROW EXECUTE FUNCTION "public"."update_seq_and_updated_at"();
-- Modify "twist" view
CREATE OR REPLACE VIEW "user"."twist" (
  "user_id",
  "id",
  "created_at",
  "updated_at",
  "seq",
  "archived_at",
  "twist_id",
  "twist_environment",
  "is_source",
  "multiple_instances",
  "shared",
  "key_option",
  "owner_id",
  "team_id",
  "name",
  "account_label",
  "options",
  "logo_url",
  "logo_url_dark",
  "link_types",
  "default_mention_created",
  "default_mention_mentioned",
  "user_connected",
  "is_builtin"
) AS SELECT pt.owner_id AS user_id,
    pt.id,
    pt.created_at,
    GREATEST(pt.updated_at, t.updated_at, ( SELECT max(ptc2.connected_at) AS max
           FROM public.twist_instance_connection ptc2
          WHERE ptc2.twist_instance_id = pt.id AND ptc2.user_id = pt.owner_id)) AS updated_at,
    GREATEST(pt.seq, t.seq, COALESCE(( SELECT max(ptc2.seq) AS max
           FROM public.twist_instance_connection ptc2
          WHERE ptc2.twist_instance_id = pt.id AND ptc2.user_id = pt.owner_id), '0'::xid8)) AS seq,
    pt.archived_at,
    pt.twist_id,
    t.environment AS twist_environment,
    t.is_source,
    t.multiple_instances,
    t.shared,
    t.key_option,
    pt.owner_id,
    pt.team_id,
    pt.name,
    pt.account_label,
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
        END AS user_connected,
    t.twist_package_id = '0199b6f4-ae64-7718-8a02-44716f30358f'::uuid AS is_builtin
   FROM public.twist_instance pt
     JOIN public.twist t ON pt.twist_id = t.id;
