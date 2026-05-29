-- Disable statement timeout for this migration transaction. The data-migration
-- UPDATEs below (backfill canonical_source, dedup notes, bump every link and
-- schedule row) touch large tables and exceed the default per-statement budget
-- on production. The whole migration runs in one transaction, so SET LOCAL
-- scopes the override to this migration only.
SET LOCAL statement_timeout = '0';

-- Modify "note" table
ALTER TABLE "public"."note" ADD COLUMN "canonical_source" text NULL;
-- Create index "note_thread_canonical_key_unique" to table: "note"
CREATE UNIQUE INDEX "note_thread_canonical_key_unique" ON "public"."note" ("thread_id", "canonical_source", "key") WHERE ((canonical_source IS NOT NULL) AND (key IS NOT NULL));
-- Set comment to column: "link_id" on table: "note"
COMMENT ON COLUMN "public"."note"."link_id" IS 'The connector-created link this note was first written through. Informational attribution — note visibility is thread-scoped, not link-scoped. Cross-connection dedup is keyed on canonical_source, not link_id. NULL for user/Plot-tool authored notes.';
-- Set comment to column: "canonical_source" on table: "note"
COMMENT ON COLUMN "public"."note"."canonical_source" IS 'The link.source of the link this note was first written through (copied at note write time by createNote). Drives cross-connection dedup: when two users'' connections of the same external resource each write a note with the same key, the partial unique index on (thread_id, canonical_source, key) collapses them to one row. NULL when no link or the link has no source.';
-- Modify "link" view
CREATE OR REPLACE VIEW "user"."link" (
  "user_id",
  "id",
  "created_at",
  "updated_at",
  "seq",
  "thread_id",
  "source",
  "source_created_at",
  "author_id",
  "twist_id",
  "created_by",
  "updated_by",
  "sync_depth",
  "title",
  "preview",
  "assignee_id",
  "type",
  "status",
  "actions",
  "meta",
  "source_url",
  "channel_id",
  "logo",
  "priority_id",
  "merged_from_thread_id",
  "priority_path"
) AS SELECT COALESCE(tp.user_id, p.user_id) AS user_id,
    l.id,
    l.created_at,
    l.updated_at,
    l.seq,
    l.thread_id,
    l.source,
    l.source_created_at,
    l.author_id,
    l.twist_id,
    l.created_by,
    l.updated_by,
    l.sync_depth,
    l.title,
    l.preview,
    l.assignee_id,
    l.type,
    l.status,
    l.actions,
    l.meta,
    l.source_url,
    l.channel_id,
    l.logo,
    COALESCE(tp.priority_id, "user".root_priority_id(tp.user_id), l.priority_id) AS priority_id,
    l.merged_from_thread_id,
    COALESCE(upe.path, pp.path) AS priority_path
   FROM public.link l
     LEFT JOIN public.twist_instance ti ON ti.id = l.created_by AND l.twist_id IS NOT NULL AND ti.archived_at IS NULL
     LEFT JOIN public.thread_priority tp ON tp.thread_id = l.thread_id AND tp.revoked_at IS NULL AND (tp.priority_id IS NOT NULL OR tp.classify_at < (now() - public.classify_visibility_window())) AND (l.twist_id IS NULL OR ti.owner_id = tp.user_id)
     LEFT JOIN "user".priority_expanded upe ON upe.user_id = tp.user_id AND upe.priority_id = COALESCE(tp.priority_id, "user".root_priority_id(tp.user_id))
     LEFT JOIN public.priority pp ON pp.id = l.priority_id AND l.thread_id IS NULL
     LEFT JOIN public.priority p ON p.id = l.priority_id AND l.thread_id IS NULL
  WHERE tp.user_id IS NOT NULL OR p.user_id IS NOT NULL;
-- Modify "schedule" view
CREATE OR REPLACE VIEW "user"."schedule" (
  "user_id",
  "id",
  "created_at",
  "updated_at",
  "seq",
  "archived_at",
  "schedule_user_id",
  "order",
  "at",
  "on",
  "recurrence_rule",
  "duration",
  "recurrence_exdates",
  "occurrence",
  "thread_id",
  "link_id",
  "reason",
  "outstanding_tasks",
  "priority_path",
  "range_at",
  "range_on",
  "contacts"
) AS SELECT tp.user_id,
    s.id,
    s.created_at,
    s.updated_at,
    s.seq,
    COALESCE(s.archived_at, upe.archived_at) AS archived_at,
    s.user_id AS schedule_user_id,
    s."order",
    s.at,
    s."on",
    s.recurrence_rule,
    s.duration,
    s.recurrence_exdates,
    s.occurrence,
    s.thread_id,
    s.link_id,
    s.reason,
    s.outstanding_tasks,
    upe.path AS priority_path,
        CASE
            WHEN s.at IS NOT NULL THEN s.at
            ELSE NULL::tstzrange
        END AS range_at,
        CASE
            WHEN s."on" IS NOT NULL THEN s."on"
            ELSE NULL::daterange
        END AS range_on,
    COALESCE(( SELECT jsonb_agg(jsonb_build_object('id', sc.id, 'contact_id', sc.contact_id, 'contact_email', c.email, 'contact_name', c.name, 'contact_user_id', c.user_id, 'status', sc.status, 'role', sc.role, 'archived_at', sc.archived_at, 'updated_at', sc.updated_at) ORDER BY sc.created_at) AS jsonb_agg
           FROM public.schedule_contact sc
             JOIN public.contact c ON c.id = sc.contact_id
          WHERE sc.schedule_id = s.id), '[]'::jsonb) AS contacts
   FROM public.schedule s
     LEFT JOIN public.link l ON l.id = s.link_id
     LEFT JOIN public.twist_instance ti ON ti.id = l.created_by AND l.twist_id IS NOT NULL AND ti.archived_at IS NULL
     JOIN public.thread_priority tp ON tp.thread_id = COALESCE(s.thread_id, l.thread_id) AND tp.revoked_at IS NULL AND (tp.priority_id IS NOT NULL OR tp.classify_at < (now() - public.classify_visibility_window())) AND (s.link_id IS NULL OR l.twist_id IS NULL OR ti.owner_id = tp.user_id)
     LEFT JOIN "user".priority_expanded upe ON upe.user_id = tp.user_id AND upe.priority_id = COALESCE(tp.priority_id, "user".root_priority_id(tp.user_id))
  WHERE s.user_id IS NULL OR s.user_id = tp.user_id;

-- ---------------------------------------------------------------------------
-- Data migration: backfill canonical_source, dedup cross-connection notes,
-- archive legacy bare-`description` orphans, and bump parents so clients
-- re-pull under the new visibility rules.
-- ---------------------------------------------------------------------------

-- A. Backfill canonical_source for existing keyed notes whose link has a source.
UPDATE note n
SET canonical_source = l.source
FROM link l
WHERE n.link_id = l.id
  AND n.key IS NOT NULL
  AND l.source IS NOT NULL
  AND n.canonical_source IS NULL;

-- B. Archive cross-connection duplicate notes; keep oldest per (thread, canonical_source, key).
-- Per libs/db/AGENTS.md "Removing Rows from Synced Tables": archived_at, never DELETE.
WITH ranked AS (
    SELECT id,
           row_number() OVER (
               PARTITION BY thread_id, canonical_source, key
               ORDER BY created_at, id
           ) AS rn
    FROM note
    WHERE canonical_source IS NOT NULL
      AND key IS NOT NULL
      AND archived_at IS NULL
)
UPDATE note
SET archived_at = now()
WHERE id IN (SELECT id FROM ranked WHERE rn > 1);

-- C. Archive legacy bare-`description` orphans on threads that have a hashed
-- sibling. Scoped to the Google Calendar twist via link.twist_id to avoid
-- touching other connectors that may legitimately use the `description` key.
WITH gcal_twist AS (
    SELECT id FROM twist WHERE name = 'Google Calendar'
)
UPDATE note legacy
SET archived_at = now()
FROM link l, gcal_twist t
WHERE legacy.link_id = l.id
  AND l.twist_id = t.id
  AND legacy.key = 'description'
  AND legacy.archived_at IS NULL
  AND EXISTS (
      SELECT 1 FROM note sibling
      WHERE sibling.thread_id = legacy.thread_id
        AND sibling.key LIKE 'description-%'
        AND sibling.archived_at IS NULL
  );

-- D. Bump link and schedule rows so clients re-pull under the new per-user
-- visibility filter. Required because the view change alters which rows each
-- user sees without otherwise touching the underlying row's seq.
UPDATE link SET updated_at = now();
UPDATE schedule SET updated_at = now();
