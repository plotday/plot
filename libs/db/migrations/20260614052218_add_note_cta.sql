-- Drop "note" view
DROP VIEW "user"."note";
-- Drop "note_redacted" view
DROP VIEW "user"."note_redacted";
-- Modify "note" table
ALTER TABLE "public"."note" ADD COLUMN "cta" jsonb NULL;
-- Set comment to column: "cta" on table: "note"
COMMENT ON COLUMN "public"."note"."cta" IS 'Time-sensitive call-to-action extracted at ingest (OTP code or confirm link): {kind:"otp"|"confirm", service, code, url}. NULL when none. Set by the twist runtime from connector extraction; drives the client''s ephemeral OTP/confirm toast and push.';
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
  "cta",
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
    n.cta,
    n.mentions,
    n.re_note_id,
    n.merged_from_thread_id
   FROM public.note n
     JOIN public.thread a ON a.id = n.thread_id
     JOIN public.thread_priority tp ON tp.thread_id = a.id AND tp.revoked_at IS NULL AND (tp.priority_id IS NOT NULL OR tp.classify_at < (now() - public.classify_visibility_window()))
  WHERE (n.draft = false OR n.created_by = tp.user_id) AND (n.created_by = tp.user_id OR n.access_contacts IS NULL AND n.access_groups IS NULL OR n.access_contacts IS NOT NULL AND n.access_contacts && "user".user_contact_ids(tp.user_id) OR n.access_groups IS NOT NULL AND n.access_groups && "user".user_group_ids(tp.user_id)) AND (a.draft = false OR a.created_by = tp.user_id) AND (a.contacts && "user".user_contact_ids(tp.user_id) OR a.groups && "user".user_group_ids(tp.user_id) OR a.topic_id IS NOT NULL AND (a.topic_id = ANY ("user".user_topic_ids(tp.user_id))));
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
  "cta",
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
    NULL::jsonb AS cta,
    NULL::uuid[] AS mentions,
    n.re_note_id,
    n.merged_from_thread_id
   FROM public.note n
     JOIN public.thread a ON a.id = n.thread_id
     JOIN public.thread_priority tp ON tp.thread_id = a.id AND tp.revoked_at IS NULL AND (tp.priority_id IS NOT NULL OR tp.classify_at < (now() - public.classify_visibility_window()))
  WHERE (n.draft = false OR n.created_by = tp.user_id) AND (a.draft = false OR a.created_by = tp.user_id) AND (a.contacts && "user".user_contact_ids(tp.user_id) OR a.groups && "user".user_group_ids(tp.user_id) OR a.topic_id IS NOT NULL AND (a.topic_id = ANY ("user".user_topic_ids(tp.user_id)))) AND n.created_by <> tp.user_id AND (n.access_contacts IS NOT NULL OR n.access_groups IS NOT NULL) AND NOT (n.access_contacts IS NOT NULL AND n.access_contacts && "user".user_contact_ids(tp.user_id) OR n.access_groups IS NOT NULL AND n.access_groups && "user".user_group_ids(tp.user_id)) AND NOT (a.dropped_contacts IS NOT NULL AND cardinality(a.dropped_contacts) > 0 AND a.dropped_contacts && "user".user_contact_ids(tp.user_id));
-- Bump note rows so clients re-pull and receive the new cta column.
UPDATE note SET updated_at = now() WHERE archived_at IS NULL;
