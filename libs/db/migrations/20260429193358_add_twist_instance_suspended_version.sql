-- Drop "twist_instance_thread_tag_change" view
DROP VIEW "public"."twist_instance_thread_tag_change";
-- Drop "twist_instance_details" view
DROP VIEW "public"."twist_instance_details";
-- Modify "twist_instance" table
ALTER TABLE "public"."twist_instance" ADD COLUMN "suspended_version" text NULL;
-- Create "twist_instance_details" view
CREATE VIEW "public"."twist_instance_details" (
  "id",
  "twist_id",
  "owner_id",
  "team_id",
  "name",
  "account_label",
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
