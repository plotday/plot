-- Drop "twist_instance_thread_tag_change" view
DROP VIEW "public"."twist_instance_thread_tag_change";
-- Drop "priority_child_twist" view
DROP VIEW "public"."priority_child_twist";
-- Modify "twist_instance" table
ALTER TABLE "public"."twist_instance" ADD COLUMN "team_id" bigint NULL, ADD CONSTRAINT "twist_instance_team_id_fkey" FOREIGN KEY ("team_id") REFERENCES "public"."team" ("id") ON UPDATE NO ACTION ON DELETE SET NULL;
-- Create index "idx_twist_instance_team_id" to table: "twist_instance"
CREATE INDEX "idx_twist_instance_team_id" ON "public"."twist_instance" ("team_id") WHERE (team_id IS NOT NULL);
-- Create "priority_child_twist" view
CREATE VIEW "public"."priority_child_twist" (
  "id",
  "twist_id",
  "owner_id",
  "team_id",
  "name",
  "options",
  "draft",
  "created_at",
  "updated_at",
  "archived_at",
  "suspended_at",
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
    pt.options,
    pt.draft,
    pt.created_at,
    pt.updated_at,
    pt.archived_at,
    pt.suspended_at,
    t.version,
    t.environment AS twist_environment,
    t.is_source,
    p.name AS author_name,
    p.email AS author_email,
    p.url AS author_url
   FROM public.twist_instance pt
     JOIN public.twist t ON pt.twist_id = t.id
     JOIN public.twist_admin ta ON t.twist_admin_id = ta.id
     LEFT JOIN public.publisher p ON ta.publisher_id = p.id
  WHERE pt.archived_at IS NULL;
-- Create "twist_instance_thread_tag_change" view
CREATE VIEW "public"."twist_instance_thread_tag_change" (
  "twist_instance_id",
  "thread_id",
  "occurrence",
  "tag_id",
  "actor_id",
  "updated_at",
  "change_type"
) AS SELECT a.created_by AS twist_instance_id,
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
     JOIN public.priority_child_twist pct ON pct.id = a.created_by
  WHERE a.draft = false;
