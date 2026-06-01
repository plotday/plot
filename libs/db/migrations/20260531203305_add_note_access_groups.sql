-- Drop "note" view
DROP VIEW "user"."note";
-- Drop "note_redacted" view
DROP VIEW "user"."note_redacted";
-- Modify "note" table
ALTER TABLE "public"."note" ADD COLUMN "access_groups" uuid[] NULL;
-- Create index "idx_note_access_groups" to table: "note"
CREATE INDEX "idx_note_access_groups" ON "public"."note" USING GIN ("access_groups") WHERE (access_groups IS NOT NULL);
-- Set comment to column: "access_groups" on table: "note"
COMMENT ON COLUMN "public"."note"."access_groups" IS 'Restricts note visibility within thread viewers via group membership, parallel to access_contacts. NULL = thread-default groups can see, array of group_ids = author + members of listed groups (subset of thread.groups). Combines with access_contacts via OR: a non-author user sees the note iff their contact ids overlap access_contacts (when non-null) OR their group ids overlap access_groups (when non-null). When both are NULL, all thread viewers see it.';
-- Create "note" view
CREATE VIEW "user"."note" (
  "user_id",
  "id",
  "created_at",
  "updated_at",
  "seq",
  "source_created_at",
  "author_id",
  "created_by",
  "updated_by",
  "archived_at",
  "thread_id",
  "draft",
  "access_contacts",
  "access_groups",
  "content",
  "actions",
  "mentions",
  "re_note_id",
  "merged_from_thread_id"
) AS SELECT tp.user_id,
    n.id,
    n.created_at,
    n.updated_at,
    n.seq,
    n.source_created_at,
    n.author_id,
    n.created_by,
    n.updated_by,
    n.archived_at,
    n.thread_id,
    n.draft,
    n.access_contacts,
    n.access_groups,
    n.content,
    n.actions,
    n.mentions,
    n.re_note_id,
    n.merged_from_thread_id
   FROM public.note n
     JOIN public.thread a ON a.id = n.thread_id
     JOIN public.thread_priority tp ON tp.thread_id = a.id AND tp.revoked_at IS NULL AND (tp.priority_id IS NOT NULL OR tp.classify_at < (now() - public.classify_visibility_window()))
  WHERE (n.draft = false OR n.created_by = tp.user_id) AND (n.created_by = tp.user_id OR n.access_contacts IS NULL AND n.access_groups IS NULL OR n.access_contacts IS NOT NULL AND n.access_contacts && "user".user_contact_ids(tp.user_id) OR n.access_groups IS NOT NULL AND n.access_groups && "user".user_group_ids(tp.user_id)) AND (a.draft = false OR a.created_by = tp.user_id) AND (a.contacts && "user".user_contact_ids(tp.user_id) OR a.groups && "user".user_group_ids(tp.user_id));
-- Create "note_redacted" view
CREATE VIEW "user"."note_redacted" (
  "user_id",
  "id",
  "created_at",
  "updated_at",
  "seq",
  "source_created_at",
  "author_id",
  "created_by",
  "updated_by",
  "archived_at",
  "thread_id",
  "draft",
  "access_contacts",
  "access_groups",
  "content",
  "actions",
  "mentions",
  "re_note_id",
  "merged_from_thread_id"
) AS SELECT tp.user_id,
    n.id,
    n.created_at,
    n.updated_at,
    n.seq,
    n.source_created_at,
    n.author_id,
    n.created_by,
    n.updated_by,
    COALESCE(n.archived_at, n.updated_at) AS archived_at,
    n.thread_id,
    n.draft,
    NULL::uuid[] AS access_contacts,
    NULL::uuid[] AS access_groups,
    NULL::text AS content,
    NULL::jsonb AS actions,
    NULL::uuid[] AS mentions,
    n.re_note_id,
    n.merged_from_thread_id
   FROM public.note n
     JOIN public.thread a ON a.id = n.thread_id
     JOIN public.thread_priority tp ON tp.thread_id = a.id AND tp.revoked_at IS NULL AND (tp.priority_id IS NOT NULL OR tp.classify_at < (now() - public.classify_visibility_window()))
  WHERE (n.draft = false OR n.created_by = tp.user_id) AND (a.draft = false OR a.created_by = tp.user_id) AND (a.contacts && "user".user_contact_ids(tp.user_id) OR a.groups && "user".user_group_ids(tp.user_id)) AND n.created_by <> tp.user_id AND (n.access_contacts IS NOT NULL OR n.access_groups IS NOT NULL) AND NOT (n.access_contacts IS NOT NULL AND n.access_contacts && "user".user_contact_ids(tp.user_id) OR n.access_groups IS NOT NULL AND n.access_groups && "user".user_group_ids(tp.user_id)) AND NOT (a.dropped_contacts IS NOT NULL AND cardinality(a.dropped_contacts) > 0 AND a.dropped_contacts && "user".user_contact_ids(tp.user_id));
-- Modify "note_tags" view
CREATE OR REPLACE VIEW "user"."note_tags" (
  "user_id",
  "id",
  "updated_at",
  "seq",
  "archived_at",
  "priority_id",
  "priority_path",
  "tags"
) AS SELECT ua.user_id,
    n.id,
    nt.updated_at,
    nt.seq,
    ua.archived_at,
    ua.priority_id,
    ua.priority_path,
    nt.tags
   FROM "user".thread ua
     JOIN public.note n ON n.thread_id = ua.id
     JOIN LATERAL ( SELECT jsonb_object_agg(sq.tag_id, sq.actor_ids) FILTER (WHERE sq.actor_ids IS NOT NULL AND jsonb_array_length(sq.actor_ids) > 0) AS tags,
            max(sq.updated_at) AS updated_at,
            max(sq.seq) AS seq
           FROM ( SELECT nt_1.tag_id,
                    jsonb_agg(nt_1.actor_id ORDER BY nt_1.actor_id) FILTER (WHERE nt_1.archived_at IS NULL) AS actor_ids,
                    max(COALESCE(nt_1.archived_at, nt_1.updated_at)) AS updated_at,
                    max(nt_1.seq) AS seq
                   FROM public.note_tag nt_1
                  WHERE nt_1.note_id = n.id
                  GROUP BY nt_1.tag_id) sq
         HAVING count(*) > 0) nt ON true
  WHERE (n.draft = false OR n.created_by = ua.user_id) AND (n.created_by = ua.user_id OR n.access_contacts IS NULL AND n.access_groups IS NULL OR n.access_contacts IS NOT NULL AND n.access_contacts && "user".user_contact_ids(ua.user_id) OR n.access_groups IS NOT NULL AND n.access_groups && "user".user_group_ids(ua.user_id));

-- Force re-sync of all existing notes so clients pick up the new access_groups
-- column. Without this bump, rows whose seq predates the migration would never
-- re-emit through /sync/notes. Filter to live notes only (matches the
-- 20260526183033 thread migration precedent) and disable statement_timeout for
-- the bulk write; SET LOCAL reverts at the end of Atlas's migration transaction.
SET LOCAL statement_timeout = 0;
UPDATE public.note SET updated_at = now() WHERE archived_at IS NULL;
