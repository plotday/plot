-- Create "maybe_archive_thread_last_holder" function
CREATE FUNCTION "public"."maybe_archive_thread_last_holder" () RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    v_thread_id uuid;
BEGIN
    v_thread_id := CASE TG_OP
        WHEN 'DELETE' THEN OLD.thread_id
        ELSE NEW.thread_id
    END;

    IF v_thread_id IS NULL THEN
        RETURN NULL;
    END IF;

    -- If the thread already has a global archived_at, nothing to do.
    IF EXISTS (
        SELECT 1 FROM public.thread t
        WHERE t.id = v_thread_id AND t.archived_at IS NOT NULL
    ) THEN
        RETURN NULL;
    END IF;

    -- Active thread_priority rows?
    IF EXISTS (
        SELECT 1 FROM public.thread_priority tp
        WHERE tp.thread_id = v_thread_id
          AND tp.archived_at IS NULL
    ) THEN
        RETURN NULL;
    END IF;

    -- Any remaining links pointing at this thread?
    IF EXISTS (
        SELECT 1 FROM public.link l
        WHERE l.thread_id = v_thread_id
    ) THEN
        RETURN NULL;
    END IF;

    UPDATE public.thread t
    SET archived_at = now()
    WHERE t.id = v_thread_id
      AND t.archived_at IS NULL;

    RETURN NULL;
END;
$$;
-- Create trigger "maybe_archive_thread_after_link_delete"
CREATE TRIGGER "maybe_archive_thread_after_link_delete" AFTER DELETE ON "public"."link" FOR EACH ROW EXECUTE FUNCTION "public"."maybe_archive_thread_last_holder"();
-- Create trigger "maybe_archive_thread_after_priority_archive"
CREATE TRIGGER "maybe_archive_thread_after_priority_archive" AFTER UPDATE OF "archived_at" ON "public"."thread_priority" FOR EACH ROW WHEN ((new.archived_at IS NOT NULL) AND ((old.archived_at IS NULL) OR (old.archived_at IS DISTINCT FROM new.archived_at))) EXECUTE FUNCTION "public"."maybe_archive_thread_last_holder"();
-- Modify "archive_links" function
CREATE OR REPLACE FUNCTION "public"."archive_links" ("p_created_by" uuid, "p_filter" jsonb DEFAULT '{}') RETURNS uuid[] LANGUAGE plpgsql AS $$
DECLARE
    v_owner_user_id uuid;
    v_affected_priority_ids uuid[];
    v_now timestamptz := now();
BEGIN
    -- Resolve the user who owns this twist_instance. All archive effects
    -- apply only to this user.
    SELECT owner_id INTO v_owner_user_id
    FROM public.twist_instance
    WHERE id = p_created_by;

    IF v_owner_user_id IS NULL THEN
        RETURN ARRAY[]::uuid[];
    END IF;

    WITH matched_links AS (
        SELECT l.id AS link_id, l.thread_id
        FROM public.link l
        WHERE l.created_by = p_created_by
          AND l.thread_id IS NOT NULL
          AND (NOT (p_filter ? 'channelId')
               OR l.channel_id = (p_filter ->> 'channelId'))
          AND (NOT (p_filter ? 'type')
               OR l.type = (p_filter ->> 'type'))
          AND (NOT (p_filter ? 'status')
               OR l.status = (p_filter ->> 'status'))
          AND (NOT (p_filter ? 'meta')
               OR l.meta @> (p_filter -> 'meta'))
    ),
    -- For per-user archive we only want to retire the user's filing on
    -- threads where this twist_instance has no remaining unmatched links.
    -- (If the filter excluded some of its links, the user's connector still
    -- actively contributes to the thread, so don't archive their filing.)
    threads_fully_matched AS (
        SELECT DISTINCT ml.thread_id
        FROM matched_links ml
        WHERE NOT EXISTS (
            SELECT 1 FROM public.link other_l
            WHERE other_l.thread_id = ml.thread_id
              AND other_l.created_by = p_created_by
              AND other_l.id NOT IN (SELECT link_id FROM matched_links)
        )
    ),
    archived_priorities AS (
        UPDATE public.thread_priority tp
        SET archived_at = v_now
        FROM threads_fully_matched tfm
        WHERE tp.thread_id = tfm.thread_id
          AND tp.user_id = v_owner_user_id
          AND tp.archived_at IS NULL
        RETURNING tp.priority_id
    ),
    -- Delete the link rows we just archived at the thread_priority level.
    deleted_links AS (
        DELETE FROM public.link l
        USING matched_links ml
        WHERE l.id = ml.link_id
        RETURNING l.id
    )
    SELECT ARRAY(SELECT DISTINCT priority_id FROM archived_priorities)
    INTO v_affected_priority_ids;

    RETURN COALESCE(v_affected_priority_ids, ARRAY[]::uuid[]);
END;
$$;
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
     JOIN public.thread a ON a.id = tp.thread_id AND a.archived_at IS NULL AND tp.archived_at IS NULL AND (a.draft = false OR a.created_by = tp.user_id) AND a.contacts && "user".user_contact_ids(tp.user_id)
     JOIN public.thread_unread tu ON tu.user_id = tp.user_id AND tu.thread_id = a.id AND tu.read_at IS NULL
  GROUP BY tp.user_id, tp.priority_id;
-- Modify "thread" view
CREATE OR REPLACE VIEW "user"."thread" (
  "user_id",
  "id",
  "created_at",
  "updated_at",
  "updated_by",
  "archived_at",
  "priority_id",
  "priority_path",
  "draft",
  "contacts",
  "topics",
  "title",
  "preview",
  "icon",
  "has_embedding",
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
    COALESCE(a.archived_at, tp.archived_at, upe.archived_at) AS archived_at,
    tp.priority_id,
    upe.path AS priority_path,
    a.draft,
    a.contacts,
    a.topics,
    a.title,
    a.preview,
    a.icon,
    a.embedding IS NOT NULL AS has_embedding,
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
  WHERE (a.draft = false OR a.created_by = tp.user_id) AND (a.contacts && "user".user_contact_ids(tp.user_id) OR a.topics && "user".user_topic_ids(tp.user_id));
