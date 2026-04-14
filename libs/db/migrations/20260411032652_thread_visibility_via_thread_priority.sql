-- =====================================================================
-- Backfill thread_priority for every (user, thread) pair that was
-- visible under the legacy access/priority_expanded rules, so the
-- rewritten user.thread and user.priority_unread views preserve
-- visibility for pre-existing data.
--
-- Also backfill thread.contacts for threads that were visible via the
-- 'public' / 'members' access modes — the Stage 3a trigger only covered
-- access_contacts + author. Here we add the primary contact of every
-- user who had access so the contacts array matches the old surface.
--
-- Both statements are idempotent (ON CONFLICT, duplicate-check).
-- =====================================================================
INSERT INTO "public"."thread_priority" (thread_id, user_id, priority_id, matched, created_at, updated_at)
SELECT DISTINCT
    a.id,
    upe.user_id,
    a.priority_id,
    FALSE,
    a.created_at,
    a.updated_at
FROM "public"."thread" a
JOIN "user"."priority_expanded" upe ON upe.priority_id = a.priority_id
WHERE a.priority_id IS NOT NULL
  AND (a.draft = FALSE OR a.created_by = upe.user_id)
  AND (
      a.access = 'public'
      OR a.created_by = upe.user_id
      OR (a.access = 'members' AND upe.role = 'member')
      OR COALESCE(a.access_contacts, ARRAY[]::uuid[]) && "user".user_contact_ids(upe.user_id)
  )
ON CONFLICT (thread_id, user_id) DO NOTHING;

-- Extend thread.contacts with the primary linked contact of every user
-- who had old-rule visibility but whose primary contact isn't already
-- in access_contacts. Runs AFTER the thread_priority backfill so it
-- walks the same visibility set via thread_priority.
UPDATE "public"."thread" a
SET contacts = (
    SELECT COALESCE(array_agg(DISTINCT c.id), ARRAY[]::uuid[])
    FROM (
        SELECT unnest(a.contacts) AS id
        UNION
        SELECT uc.contact_id
        FROM "public"."thread_priority" tp
        JOIN "public"."user_contact" uc
            ON uc.user_id = tp.user_id
           AND uc.linked = TRUE
           AND uc."primary" = TRUE
           AND uc.archived_at IS NULL
        WHERE tp.thread_id = a.id
    ) c
)
WHERE EXISTS (
    SELECT 1
    FROM "public"."thread_priority" tp
    JOIN "public"."user_contact" uc
        ON uc.user_id = tp.user_id
       AND uc.linked = TRUE
       AND uc."primary" = TRUE
       AND uc.archived_at IS NULL
    WHERE tp.thread_id = a.id
      AND NOT (uc.contact_id = ANY(a.contacts))
);

-- Drop "note_tags" view
DROP VIEW "user"."note_tags";
-- Drop "thread_tags" view
DROP VIEW "user"."thread_tags";
-- Drop "thread" view
DROP VIEW "user"."thread";
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
  "contacts",
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
 SELECT tp.user_id,
    a.id,
    a.created_at,
    GREATEST(a.updated_at, COALESCE(a.last_note_created_at, '1970-01-01 00:00:00+00'::timestamp with time zone), COALESCE(tu.updated_at, '1970-01-01 00:00:00+00'::timestamp with time zone)) AS updated_at,
    a.updated_by,
    COALESCE(a.archived_at, upe.archived_at) AS archived_at,
    tp.priority_id,
    upe.path AS priority_path,
    a.draft,
    a.access,
    a.access_contacts,
    a.contacts,
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
                          WHERE s_lo.thread_id = a.id AND s_lo.user_id = tp.user_id AND s_lo.archived_at IS NULL
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
                              WHERE s_hi.thread_id = a.id AND s_hi.user_id = tp.user_id AND s_hi.archived_at IS NULL
                              ORDER BY (COALESCE(upper(s_hi.at), upper(s_hi."on")::timestamp with time zone)) DESC NULLS LAST
                             LIMIT 1), ( SELECT COALESCE(upper(s_hi.at), upper(s_hi."on")::timestamp with time zone) AS "coalesce"
                               FROM public.schedule s_hi
                                 JOIN public.link l_hi ON l_hi.id = s_hi.link_id
                              WHERE l_hi.thread_id = a.id AND s_hi.user_id IS NULL AND s_hi.archived_at IS NULL
                              ORDER BY (COALESCE(upper(s_hi.at), upper(s_hi."on")::timestamp with time zone)) DESC NULLS LAST
                             LIMIT 1))
                        END, a.created_at) AS hi) bounds) AS agenda_at
   FROM public.thread a
     JOIN public.thread_priority tp ON tp.thread_id = a.id
     LEFT JOIN "user".priority_expanded upe ON upe.user_id = tp.user_id AND upe.priority_id = tp.priority_id
     LEFT JOIN public.thread_unread tu ON tu.user_id = tp.user_id AND tu.thread_id = a.id
     LEFT JOIN link_agg la ON la.thread_id = a.id
  WHERE (a.draft = false OR a.created_by = tp.user_id) AND a.contacts && "user".user_contact_ids(tp.user_id);
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
-- Modify "priority_unread" view
CREATE OR REPLACE VIEW "user"."priority_unread" (
  "user_id",
  "priority_id",
  "unread",
  "updated_at"
) AS SELECT tp.user_id,
    tp.priority_id,
    true AS unread,
    max(tu.updated_at) AS updated_at
   FROM public.thread_priority tp
     JOIN public.thread a ON a.id = tp.thread_id AND a.archived_at IS NULL AND (a.draft = false OR a.created_by = tp.user_id) AND a.contacts && "user".user_contact_ids(tp.user_id)
     JOIN public.thread_unread tu ON tu.user_id = tp.user_id AND tu.thread_id = a.id AND tu.read_at IS NULL
  GROUP BY tp.user_id, tp.priority_id;
