-- Modify "priority_child_twist" view
CREATE OR REPLACE VIEW "public"."priority_child_twist" (
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
    child_p.id AS priority_child_id
   FROM public.priority_twist pt
     JOIN public.priority install_p ON pt.priority_id = install_p.id
     JOIN public.priority child_p ON child_p.path OPERATOR(public.<@) install_p.path
     JOIN public.twist t ON pt.twist_id = t.id
     JOIN public.twist_admin ta ON t.twist_admin_id = ta.id
     LEFT JOIN public.publisher p ON ta.publisher_id = p.id
  WHERE pt.archived_at IS NULL;
