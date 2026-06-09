-- Drop "twist_instance_thread_tag_change" view
DROP VIEW "public"."twist_instance_thread_tag_change";
-- Drop "twist_instance_details" view
DROP VIEW "public"."twist_instance_details";
-- Drop "twist" view
DROP VIEW "user"."twist";
-- Modify "twist_instance" table
ALTER TABLE "public"."twist_instance" ADD COLUMN "custom_emoji_scope" text NULL;
-- Create "twist_instance_details" view
CREATE VIEW "public"."twist_instance_details" (
  "id",
  "twist_id",
  "owner_id",
  "team_id",
  "name",
  "account_label",
  "custom_emoji_scope",
  "options",
  "draft",
  "created_at",
  "updated_at",
  "archived_at",
  "suspended_at",
  "suspended_version",
  "seq",
  "version",
  "twist_environment",
  "is_source",
  "author_name",
  "author_email",
  "author_url"
) AS SELECT pt.id,
    pt.twist_id,
    pt.owner_id,
    pt.team_id,
    pt.name,
    pt.account_label,
    pt.custom_emoji_scope,
    pt.options,
    pt.draft,
    pt.created_at,
    pt.updated_at,
    pt.archived_at,
    pt.suspended_at,
    pt.suspended_version,
    pt.seq,
    t.version,
    t.environment AS twist_environment,
    t.is_source,
    p.name AS author_name,
    p.email AS author_email,
    p.url AS author_url
   FROM public.twist_instance pt
     JOIN public.twist t ON pt.twist_id = t.id
     LEFT JOIN public.publisher p ON t.publisher_id = p.id
  WHERE pt.archived_at IS NULL;
-- Create "twist" view
CREATE VIEW "user"."twist" (
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
  "custom_emoji_scope",
  "reaction_capabilities",
  "options",
  "logo_url",
  "logo_url_dark",
  "handle",
  "thread_type",
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
    pt.custom_emoji_scope,
    t.reaction_capabilities,
    pt.options,
    t.logo_url,
    t.logo_url_dark,
    t.handle,
    t.thread_type,
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
-- Create "twist_instance_thread_tag_change" view
CREATE VIEW "public"."twist_instance_thread_tag_change" (
  "twist_instance_id",
  "thread_id",
  "occurrence",
  "tag_id",
  "actor_id",
  "updated_at",
  "seq",
  "change_type"
) AS SELECT a.created_by AS twist_instance_id,
    at.thread_id,
    at.occurrence,
    at.tag_id,
    at.actor_id,
    at.updated_at,
    at.seq,
        CASE
            WHEN at.archived_at IS NULL THEN 'added'::text
            ELSE 'removed'::text
        END AS change_type
   FROM public.thread_tag at
     JOIN public.thread a ON a.id = at.thread_id
     JOIN public.twist_instance_details tid ON tid.id = a.created_by
  WHERE a.draft = false;
-- Bump twist_instance seq so existing rows re-emit through user.twist and
-- clients pick up the newly-added custom_emoji_scope column.
UPDATE "public"."twist_instance" SET "updated_at" = now();
