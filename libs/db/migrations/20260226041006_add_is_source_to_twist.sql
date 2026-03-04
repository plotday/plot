-- Drop "priority_twist_thread_tag_change" view
DROP VIEW "public"."priority_twist_thread_tag_change";
-- Drop "priority_child_twist" view
DROP VIEW "public"."priority_child_twist";
-- Drop "twist" view
DROP VIEW "user"."twist";
-- Modify "twist" table
ALTER TABLE "public"."twist" ADD COLUMN "is_source" boolean NOT NULL DEFAULT false;
-- Backfill: mark existing twists that declare integration providers as sources
UPDATE "public"."twist" SET is_source = true WHERE permissions::jsonb ? '_providers';
-- Create "priority_child_twist" view
CREATE VIEW "public"."priority_child_twist" (
  "id",
  "priority_id",
  "twist_id",
  "owner_id",
  "name",
  "config",
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
    pt.config,
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
    pc.child_id AS priority_child_id
   FROM public.priority_twist pt
     JOIN public.priority_child pc ON pt.priority_id = pc.priority_id
     JOIN public.twist t ON pt.twist_id = t.id
     JOIN public.twist_admin ta ON t.twist_admin_id = ta.id
     LEFT JOIN public.publisher p ON ta.publisher_id = p.id
  WHERE pt.archived_at IS NULL;
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
  "owner_id",
  "name",
  "config"
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
    pt.config
   FROM public.priority_twist pt
     JOIN "user".priority_expanded upe ON upe.priority_id = pt.priority_id
     JOIN public.twist t ON pt.twist_id = t.id;
-- Create "priority_twist_thread_tag_change" view
CREATE VIEW "public"."priority_twist_thread_tag_change" (
  "priority_twist_id",
  "thread_id",
  "occurrence",
  "tag_id",
  "actor_id",
  "updated_at",
  "change_type"
) AS SELECT a.created_by AS priority_twist_id,
    at.thread_id,
    at.occurrence,
    at.tag_id,
    at.actor_id,
    at.updated_at,
        CASE
            WHEN at.archived_at IS NULL THEN 'added'::text
            ELSE 'removed'::text
        END AS change_type
   FROM public.thread_tag at
     JOIN public.thread a ON a.id = at.thread_id
     JOIN public.priority_child_twist pct ON pct.priority_child_id = a.priority_id AND pct.id = a.created_by
  WHERE a.draft = false;
