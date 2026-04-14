-- Create "sync_thread_contacts" function
CREATE FUNCTION "public"."sync_thread_contacts" () RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    _author_contact_id uuid;
    _contacts uuid[];
BEGIN
    -- Start from access_contacts (legacy source of truth) and fall back
    -- to an empty array. Cast to uuid[] to normalise NULL.
    _contacts := COALESCE(NEW.access_contacts, ARRAY[]::uuid[]);

    -- For human-authored threads, ensure the author's primary linked
    -- contact is present in contacts. Twist-created threads (created_by
    -- = priority_twist_id) have no user row, so user_contact_id returns
    -- NULL and we leave contacts as-is.
    _author_contact_id := "user".user_contact_id(NEW.created_by);
    IF _author_contact_id IS NOT NULL
       AND NOT (_author_contact_id = ANY(_contacts)) THEN
        _contacts := _contacts || _author_contact_id;
    END IF;

    NEW.contacts := _contacts;
    RETURN NEW;
END;
$$;
-- Create trigger "sync_thread_contacts"
CREATE TRIGGER "sync_thread_contacts" BEFORE INSERT OR UPDATE OF "access_contacts", "created_by" ON "public"."thread" FOR EACH ROW EXECUTE FUNCTION "public"."sync_thread_contacts"();
-- Drop "thread_tags" view
DROP VIEW "user"."thread_tags";
-- Drop "note_tags" view
DROP VIEW "user"."note_tags";
-- Drop "thread" view
DROP VIEW "user"."thread";
-- Drop "thread_x" view
DROP VIEW "public"."thread_x";
-- Modify "thread" table
ALTER TABLE "public"."thread" ADD COLUMN "contacts" uuid[] NOT NULL DEFAULT ARRAY[]::uuid[];
-- Create index "idx_thread_contacts" to table: "thread"
CREATE INDEX "idx_thread_contacts" ON "public"."thread" USING GIN ("contacts");
-- Set comment to column: "access" on table: "thread"
COMMENT ON COLUMN "public"."thread"."access" IS 'Deprecated. Kept for backwards compatibility with legacy callers while the new contacts-only visibility model rolls out. Remove after all callers migrate.';
-- Set comment to column: "access_contacts" on table: "thread"
COMMENT ON COLUMN "public"."thread"."access_contacts" IS 'Deprecated. Kept in sync with thread.contacts by trigger while the migration rolls out. Readers should use thread.contacts instead.';
-- Set comment to column: "contacts" on table: "thread"
COMMENT ON COLUMN "public"."thread"."contacts" IS 'Canonical list of contact_ids with access to this thread, including the author''s primary contact for human-created threads. A user can access the thread if any of their linked (user_contact.linked=true) contacts appears in this array.';
-- Create "thread_priority" table
CREATE TABLE "public"."thread_priority" (
  "thread_id" uuid NOT NULL,
  "user_id" uuid NOT NULL,
  "priority_id" uuid NOT NULL,
  "matched" boolean NOT NULL DEFAULT false,
  "created_at" timestamptz NOT NULL DEFAULT now(),
  "updated_at" timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY ("thread_id", "user_id"),
  CONSTRAINT "thread_priority_priority_id_fkey" FOREIGN KEY ("priority_id") REFERENCES "public"."priority" ("id") ON UPDATE NO ACTION ON DELETE CASCADE,
  CONSTRAINT "thread_priority_thread_id_fkey" FOREIGN KEY ("thread_id") REFERENCES "public"."thread" ("id") ON UPDATE NO ACTION ON DELETE CASCADE,
  CONSTRAINT "thread_priority_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."user" ("id") ON UPDATE NO ACTION ON DELETE CASCADE
);
-- Create index "idx_thread_priority_priority_id" to table: "thread_priority"
CREATE INDEX "idx_thread_priority_priority_id" ON "public"."thread_priority" ("priority_id");
-- Create index "idx_thread_priority_updated_at" to table: "thread_priority"
CREATE INDEX "idx_thread_priority_updated_at" ON "public"."thread_priority" ("updated_at");
-- Create index "idx_thread_priority_user_priority" to table: "thread_priority"
CREATE INDEX "idx_thread_priority_user_priority" ON "public"."thread_priority" ("user_id", "priority_id");
-- Set comment to table: "thread_priority"
COMMENT ON TABLE "public"."thread_priority" IS 'Per-user filing of a thread into the user''s priority hierarchy. Replaces the single thread.priority_id as the source of truth for which priority a user sees a thread under.';
-- Set comment to column: "matched" on table: "thread_priority"
COMMENT ON COLUMN "public"."thread_priority"."matched" IS 'TRUE if this filing was assigned by the priority matching algorithm (vs explicitly chosen by the user or inherited from the author).';
-- Create trigger "set_thread_priority_created_at"
CREATE TRIGGER "set_thread_priority_created_at" BEFORE INSERT ON "public"."thread_priority" FOR EACH ROW EXECUTE FUNCTION "public"."set_created_at"();
-- Create trigger "set_thread_priority_updated_at"
CREATE TRIGGER "set_thread_priority_updated_at" BEFORE INSERT OR UPDATE ON "public"."thread_priority" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at"();
-- Create "populate_thread_priority_for_author" function
CREATE FUNCTION "public"."populate_thread_priority_for_author" () RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.priority_id IS NOT NULL
       AND EXISTS (SELECT 1 FROM "public"."user" WHERE id = NEW.created_by) THEN
        INSERT INTO thread_priority (thread_id, user_id, priority_id, matched)
        VALUES (NEW.id, NEW.created_by, NEW.priority_id, FALSE)
        ON CONFLICT (thread_id, user_id)
        DO UPDATE SET priority_id = EXCLUDED.priority_id, updated_at = now();
    END IF;
    RETURN NEW;
END;
$$;
-- Create trigger "populate_thread_priority_for_author"
CREATE TRIGGER "populate_thread_priority_for_author" AFTER INSERT OR UPDATE OF "priority_id" ON "public"."thread" FOR EACH ROW EXECUTE FUNCTION "public"."populate_thread_priority_for_author"();

-- =====================================================================
-- Backfill existing data.
--
-- 1. Populate thread.contacts from the legacy access_contacts array plus
--    the author's primary contact (for human-authored threads). The
--    sync_thread_contacts trigger handles future writes; existing rows
--    need a one-shot update.
-- 2. Populate thread_priority with the author's filing, mirroring
--    thread.priority_id → (created_by, priority_id) for every thread
--    whose created_by is a real user.
-- =====================================================================

UPDATE "public"."thread" t
SET contacts = (
    SELECT COALESCE(
        CASE
            WHEN "user".user_contact_id(t.created_by) IS NOT NULL
             AND NOT (
                 "user".user_contact_id(t.created_by) = ANY(COALESCE(t.access_contacts, ARRAY[]::uuid[]))
             )
            THEN COALESCE(t.access_contacts, ARRAY[]::uuid[])
                 || "user".user_contact_id(t.created_by)
            ELSE COALESCE(t.access_contacts, ARRAY[]::uuid[])
        END,
        ARRAY[]::uuid[]
    )
);

INSERT INTO "public"."thread_priority" (thread_id, user_id, priority_id, matched, created_at, updated_at)
SELECT t.id, t.created_by, t.priority_id, FALSE, t.created_at, t.updated_at
FROM "public"."thread" t
WHERE t.priority_id IS NOT NULL
  AND EXISTS (SELECT 1 FROM "public"."user" u WHERE u.id = t.created_by)
ON CONFLICT (thread_id, user_id) DO NOTHING;
-- Create "thread_x" view
CREATE VIEW "public"."thread_x" (
  "id",
  "created_at",
  "updated_at",
  "created_by",
  "updated_by",
  "archived_at",
  "priority_id",
  "draft",
  "access",
  "access_contacts",
  "contacts",
  "title",
  "preview",
  "last_note_created_at",
  "sync_depth",
  "last_note_source_created_at",
  "key",
  "icon",
  "priority_path"
) AS SELECT a.id,
    a.created_at,
    a.updated_at,
    a.created_by,
    a.updated_by,
    a.archived_at,
    a.priority_id,
    a.draft,
    a.access,
    a.access_contacts,
    a.contacts,
    a.title,
    a.preview,
    a.last_note_created_at,
    a.sync_depth,
    a.last_note_source_created_at,
    a.key,
    a.icon,
    p.path AS priority_path
   FROM public.thread a
     JOIN public.priority p ON p.id = a.priority_id;
-- Create "thread" view
CREATE VIEW "user"."thread" (
  "user_id",
  "id",
  "created_at",
  "updated_at",
  "updated_by",
  "archived_at",
  "priority_id",
  "priority_path",
  "draft",
  "access",
  "access_contacts",
  "title",
  "preview",
  "icon",
  "last_note_created_at",
  "last_note_source_created_at",
  "bumped_at",
  "unread",
  "importance",
  "urgency",
  "activity_at",
  "agenda_at"
) AS WITH link_agg AS (
         SELECT link.thread_id,
            max(link.source_created_at) AS source_created_at
           FROM public.link
          GROUP BY link.thread_id
        )
 SELECT upe.user_id,
    a.id,
    a.created_at,
    GREATEST(a.updated_at, COALESCE(a.last_note_created_at, '1970-01-01 00:00:00+00'::timestamp with time zone), COALESCE(tu.updated_at, '1970-01-01 00:00:00+00'::timestamp with time zone)) AS updated_at,
    a.updated_by,
    COALESCE(a.archived_at, upe.archived_at) AS archived_at,
    a.priority_id,
    upe.path AS priority_path,
    a.draft,
    a.access,
    a.access_contacts,
    a.title,
    a.preview,
    a.icon,
    a.last_note_created_at,
    a.last_note_source_created_at,
    tu.bumped_at,
    COALESCE(tu.read_at IS NULL AND tu.user_id IS NOT NULL, false) AS unread,
    COALESCE(
        CASE
            WHEN tu.read_at IS NULL AND tu.user_id IS NOT NULL THEN tu.importance
            ELSE NULL::smallint
        END, 0::smallint) AS importance,
    COALESCE(
        CASE
            WHEN tu.read_at IS NULL AND tu.user_id IS NOT NULL THEN tu.urgency
            ELSE NULL::text
        END, NULL::text) AS urgency,
    COALESCE(GREATEST(a.last_note_source_created_at, la.source_created_at, tu.bumped_at, ( SELECT
                CASE
                    WHEN COALESCE(upper(s_feed.at), upper(s_feed."on")::timestamp with time zone) <= now() THEN COALESCE(upper(s_feed.at), upper(s_feed."on")::timestamp with time zone)
                    ELSE NULL::timestamp with time zone
                END AS "case"
           FROM public.schedule s_feed
          WHERE s_feed.thread_id = a.id AND s_feed.user_id IS NULL AND s_feed.occurrence IS NULL AND s_feed.archived_at IS NULL
         LIMIT 1)), a.created_at) AS activity_at,
    ( SELECT tstzrange(bounds.lo, GREATEST(bounds.lo, bounds.hi), '[]'::text) AS tstzrange
           FROM ( SELECT COALESCE(LEAST(( SELECT COALESCE(lower(s_lo.at), lower(s_lo."on")::timestamp with time zone) AS "coalesce"
                           FROM public.schedule s_lo
                          WHERE s_lo.thread_id = a.id AND s_lo.user_id IS NULL AND s_lo.archived_at IS NULL
                          ORDER BY (COALESCE(lower(s_lo.at), lower(s_lo."on")::timestamp with time zone))
                         LIMIT 1), ( SELECT COALESCE(lower(s_lo.at), lower(s_lo."on")::timestamp with time zone) AS "coalesce"
                           FROM public.schedule s_lo
                          WHERE s_lo.thread_id = a.id AND s_lo.user_id = upe.user_id AND s_lo.archived_at IS NULL
                          ORDER BY (COALESCE(lower(s_lo.at), lower(s_lo."on")::timestamp with time zone))
                         LIMIT 1), ( SELECT COALESCE(lower(s_lo.at), lower(s_lo."on")::timestamp with time zone) AS "coalesce"
                           FROM public.schedule s_lo
                             JOIN public.link l_lo ON l_lo.id = s_lo.link_id
                          WHERE l_lo.thread_id = a.id AND s_lo.user_id IS NULL AND s_lo.archived_at IS NULL
                          ORDER BY (COALESCE(lower(s_lo.at), lower(s_lo."on")::timestamp with time zone))
                         LIMIT 1)), a.created_at) AS lo,
                    COALESCE(
                        CASE
                            WHEN (EXISTS ( SELECT 1
                               FROM public.schedule s_rec
                              WHERE s_rec.thread_id = a.id AND s_rec.archived_at IS NULL AND s_rec.recurrence_rule IS NOT NULL)) OR (EXISTS ( SELECT 1
                               FROM public.schedule s_rec
                                 JOIN public.link l_rec ON l_rec.id = s_rec.link_id
                              WHERE l_rec.thread_id = a.id AND s_rec.archived_at IS NULL AND s_rec.recurrence_rule IS NOT NULL)) THEN 'infinity'::timestamp with time zone
                            WHEN (EXISTS ( SELECT 1
                               FROM public.schedule s_ub
                              WHERE s_ub.thread_id = a.id AND s_ub.archived_at IS NULL AND (s_ub.at IS NOT NULL OR s_ub."on" IS NOT NULL) AND COALESCE(upper(s_ub.at), upper(s_ub."on")::timestamp with time zone) IS NULL)) OR (EXISTS ( SELECT 1
                               FROM public.schedule s_ub
                                 JOIN public.link l_ub ON l_ub.id = s_ub.link_id
                              WHERE l_ub.thread_id = a.id AND s_ub.archived_at IS NULL AND (s_ub.at IS NOT NULL OR s_ub."on" IS NOT NULL) AND COALESCE(upper(s_ub.at), upper(s_ub."on")::timestamp with time zone) IS NULL)) THEN 'infinity'::timestamp with time zone
                            ELSE GREATEST(( SELECT COALESCE(upper(s_hi.at), upper(s_hi."on")::timestamp with time zone) AS "coalesce"
                               FROM public.schedule s_hi
                              WHERE s_hi.thread_id = a.id AND s_hi.user_id IS NULL AND s_hi.archived_at IS NULL
                              ORDER BY (COALESCE(upper(s_hi.at), upper(s_hi."on")::timestamp with time zone)) DESC NULLS LAST
                             LIMIT 1), ( SELECT COALESCE(upper(s_hi.at), upper(s_hi."on")::timestamp with time zone) AS "coalesce"
                               FROM public.schedule s_hi
                              WHERE s_hi.thread_id = a.id AND s_hi.user_id = upe.user_id AND s_hi.archived_at IS NULL
                              ORDER BY (COALESCE(upper(s_hi.at), upper(s_hi."on")::timestamp with time zone)) DESC NULLS LAST
                             LIMIT 1), ( SELECT COALESCE(upper(s_hi.at), upper(s_hi."on")::timestamp with time zone) AS "coalesce"
                               FROM public.schedule s_hi
                                 JOIN public.link l_hi ON l_hi.id = s_hi.link_id
                              WHERE l_hi.thread_id = a.id AND s_hi.user_id IS NULL AND s_hi.archived_at IS NULL
                              ORDER BY (COALESCE(upper(s_hi.at), upper(s_hi."on")::timestamp with time zone)) DESC NULLS LAST
                             LIMIT 1))
                        END, a.created_at) AS hi) bounds) AS agenda_at
   FROM public.thread_x a
     JOIN "user".priority_expanded upe ON a.priority_id = upe.priority_id
     LEFT JOIN public.thread_unread tu ON tu.user_id = upe.user_id AND tu.thread_id = a.id
     LEFT JOIN link_agg la ON la.thread_id = a.id
  WHERE (a.draft = false OR a.created_by = upe.user_id) AND
        CASE
            WHEN a.access = 'public'::text THEN true
            WHEN a.created_by = upe.user_id THEN true
            WHEN a.access = 'members'::text AND upe.role = 'member'::text THEN true
            WHEN a.access_contacts && "user".user_contact_ids(upe.user_id) THEN true
            ELSE false
        END
UNION ALL
 SELECT upe.user_id,
    a.id,
    a.created_at,
    a.updated_at,
    a.updated_by,
    COALESCE(a.archived_at, upe.archived_at, a.updated_at) AS archived_at,
    a.priority_id,
    upe.path AS priority_path,
    a.draft,
    a.access,
    NULL::uuid[] AS access_contacts,
    NULL::text AS title,
    NULL::text AS preview,
    a.icon,
    a.last_note_created_at,
    a.last_note_source_created_at,
    NULL::timestamp with time zone AS bumped_at,
    false AS unread,
    0::smallint AS importance,
    NULL::text AS urgency,
    a.created_at AS activity_at,
    tstzrange(a.created_at, a.created_at, '[]'::text) AS agenda_at
   FROM public.thread_x a
     JOIN "user".priority_expanded upe ON a.priority_id = upe.priority_id
  WHERE (a.draft = false OR a.created_by = upe.user_id) AND a.access <> 'public'::text AND a.created_by <> upe.user_id AND NOT (a.access = 'members'::text AND upe.role = 'member'::text) AND NOT COALESCE(a.access_contacts, ARRAY[]::uuid[]) && "user".user_contact_ids(upe.user_id);
-- Create "thread_tags" view
CREATE VIEW "user"."thread_tags" (
  "user_id",
  "id",
  "archived_at",
  "occurrence",
  "updated_at",
  "priority_id",
  "priority_path",
  "tags"
) AS SELECT ua.user_id,
    ua.id,
    ua.archived_at,
    tt.occurrence,
    tt.updated_at,
    ua.priority_id,
    ua.priority_path,
    tt.tags
   FROM "user".thread ua
     JOIN LATERAL ( SELECT sq.occurrence,
            jsonb_object_agg(sq.tag_id, sq.actor_ids) FILTER (WHERE sq.actor_ids IS NOT NULL AND jsonb_array_length(sq.actor_ids) > 0) AS tags,
            max(sq.updated_at) AS updated_at
           FROM ( SELECT at.occurrence,
                    at.tag_id,
                    jsonb_agg(at.actor_id) FILTER (WHERE at.archived_at IS NULL) AS actor_ids,
                    max(COALESCE(at.archived_at, at.updated_at)) AS updated_at
                   FROM public.thread_tag at
                  WHERE at.thread_id = ua.id
                  GROUP BY at.occurrence, at.tag_id) sq
          GROUP BY sq.occurrence) tt ON true;
-- Create "note_tags" view
CREATE VIEW "user"."note_tags" (
  "user_id",
  "id",
  "updated_at",
  "archived_at",
  "priority_id",
  "priority_path",
  "tags"
) AS SELECT ua.user_id,
    n.id,
    nt.updated_at,
    ua.archived_at,
    ua.priority_id,
    ua.priority_path,
    nt.tags
   FROM public.note_tags nt
     JOIN public.note n ON n.id = nt.note_id
     JOIN "user".thread ua ON ua.id = n.thread_id
  WHERE (n.draft = false OR n.created_by = ua.user_id) AND (n.access_contacts IS NULL OR n.created_by = ua.user_id OR n.access_contacts && "user".user_contact_ids(ua.user_id));
