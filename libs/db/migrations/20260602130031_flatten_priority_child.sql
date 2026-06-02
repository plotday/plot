-- Modify "priority_child" view
CREATE OR REPLACE VIEW "public"."priority_child" (
  "priority_id",
  "child_id",
  "archived_at"
) AS SELECT id AS priority_id,
    id AS child_id,
    archived_at
   FROM public.priority p;
