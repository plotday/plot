-- Create "bump_threads_on_priority_archive" function
CREATE FUNCTION "public"."bump_threads_on_priority_archive" () RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    UPDATE public.thread t
    SET updated_at = now()
    FROM public.thread_priority tp
    JOIN (
        SELECT n.id
        FROM new_table n
        JOIN old_table o ON o.id = n.id
        WHERE (o.archived_at IS NULL) <> (n.archived_at IS NULL)
    ) changed ON changed.id = tp.priority_id
    WHERE t.id = tp.thread_id;
    RETURN NULL;
END;
$$;
-- Create trigger "bump_threads_on_priority_archive"
CREATE TRIGGER "bump_threads_on_priority_archive" AFTER UPDATE ON "public"."priority" REFERENCING OLD TABLE AS "old_table" NEW TABLE AS "new_table" FOR EACH STATEMENT EXECUTE FUNCTION "public"."bump_threads_on_priority_archive"();
-- Create "effective_priority_id" function
CREATE FUNCTION "user"."effective_priority_id" ("p_priority_id" uuid, "p_user_id" uuid) RETURNS uuid LANGUAGE sql STABLE AS $$
SELECT
        CASE
        WHEN p_priority_id IS NULL THEN "user".root_priority_id (p_user_id)
        WHEN EXISTS (
            SELECT 1 FROM priority p
            WHERE p.id = p_priority_id AND p.archived_at IS NOT NULL
        ) THEN "user".root_priority_id (p_user_id)
        ELSE p_priority_id
        END;
$$;
-- Create "thread_priority_negative" table
CREATE TABLE "public"."thread_priority_negative" (
  "user_id" uuid NOT NULL,
  "thread_id" uuid NOT NULL,
  "priority_id" uuid NOT NULL,
  "source" text NOT NULL,
  "created_at" timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY ("user_id", "thread_id", "priority_id"),
  CONSTRAINT "thread_priority_negative_priority_id_fkey" FOREIGN KEY ("priority_id") REFERENCES "public"."priority" ("id") ON UPDATE NO ACTION ON DELETE CASCADE,
  CONSTRAINT "thread_priority_negative_thread_id_fkey" FOREIGN KEY ("thread_id") REFERENCES "public"."thread" ("id") ON UPDATE NO ACTION ON DELETE CASCADE,
  CONSTRAINT "thread_priority_negative_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."user" ("id") ON UPDATE NO ACTION ON DELETE CASCADE
);
-- Create index "idx_thread_priority_negative_user_priority" to table: "thread_priority_negative"
CREATE INDEX "idx_thread_priority_negative_user_priority" ON "public"."thread_priority_negative" ("user_id", "priority_id");
-- Modify "priority_unread" view
CREATE OR REPLACE VIEW "user"."priority_unread" (
  "user_id",
  "priority_id",
  "unread",
  "updated_at"
) AS SELECT tp.user_id,
    "user".effective_priority_id(tp.priority_id, tp.user_id) AS priority_id,
    true AS unread,
    max(ts.updated_at) AS updated_at
   FROM public.thread_priority tp
     JOIN public.thread a ON a.id = tp.thread_id AND a.archived_at IS NULL AND tp.archived_at IS NULL AND tp.revoked_at IS NULL AND (a.draft = false OR a.created_by = tp.user_id) AND (a.contacts && "user".user_contact_ids(tp.user_id) OR a.groups && "user".user_group_ids(tp.user_id)) AND (tp.priority_id IS NOT NULL OR tp.classify_at < (now() - public.classify_visibility_window()))
     JOIN public.priority p ON p.id = "user".effective_priority_id(tp.priority_id, tp.user_id) AND (p.team_id IS NULL OR (EXISTS ( SELECT 1
           FROM public.team_user tu2
          WHERE tu2.team_id = p.team_id AND tu2.user_id = tp.user_id AND tu2.archived_at IS NULL)))
     JOIN public.thread_state ts ON ts.user_id = tp.user_id AND ts.thread_id = a.id AND ts.read_at IS NULL AND (ts.importance >= 50 OR ts.urgent = true)
  GROUP BY tp.user_id, ("user".effective_priority_id(tp.priority_id, tp.user_id));
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
    COALESCE("user".effective_priority_id(tp.priority_id, tp.user_id), l.priority_id) AS priority_id,
    l.merged_from_thread_id,
    COALESCE(upe.path, pp.path) AS priority_path
   FROM public.link l
     LEFT JOIN public.twist_instance ti ON ti.id = l.created_by AND l.twist_id IS NOT NULL AND ti.archived_at IS NULL
     LEFT JOIN public.thread_priority tp ON tp.thread_id = l.thread_id AND tp.revoked_at IS NULL AND (tp.priority_id IS NOT NULL OR tp.classify_at < (now() - public.classify_visibility_window())) AND (l.twist_id IS NULL OR ti.owner_id = tp.user_id)
     LEFT JOIN "user".priority_expanded upe ON upe.user_id = tp.user_id AND upe.priority_id = "user".effective_priority_id(tp.priority_id, tp.user_id)
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
  "at",
  "on",
  "recurrence_rule",
  "duration",
  "recurrence_exdates",
  "occurrence",
  "thread_id",
  "link_id",
  "reason",
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
    s.at,
    s."on",
    s.recurrence_rule,
    s.duration,
    s.recurrence_exdates,
    s.occurrence,
    s.thread_id,
    s.link_id,
    s.reason,
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
     LEFT JOIN "user".priority_expanded upe ON upe.user_id = tp.user_id AND upe.priority_id = "user".effective_priority_id(tp.priority_id, tp.user_id);
-- Modify "thread" view
CREATE OR REPLACE VIEW "user"."thread" (
  "user_id",
  "id",
  "created_at",
  "updated_at",
  "seq",
  "updated_by",
  "archived_at",
  "priority_id",
  "priority_path",
  "draft",
  "contacts",
  "contact_meta",
  "groups",
  "topic",
  "title",
  "preview",
  "icon",
  "merged_into_thread_id",
  "has_embedding",
  "mute_by_thread_id",
  "last_note_created_at",
  "last_note_source_created_at",
  "bumped_at",
  "unread",
  "importance",
  "active",
  "task",
  "to_read",
  "urgent",
  "state_order",
  "state_on",
  "state_at",
  "activity_at",
  "agenda_at",
  "revoked"
) AS WITH link_agg AS (
         SELECT link.thread_id,
            max(link.source_created_at) AS source_created_at
           FROM public.link
          GROUP BY link.thread_id
        )
 SELECT tp.user_id,
    a.id,
    a.created_at,
    GREATEST(a.updated_at, COALESCE(a.last_note_created_at, '1970-01-01 00:00:00+00'::timestamp with time zone), tp.updated_at, COALESCE(ts.updated_at, '1970-01-01 00:00:00+00'::timestamp with time zone)) AS updated_at,
    GREATEST(a.seq, a.last_note_seq, tp.seq, COALESCE(ts.seq, '0'::xid8)) AS seq,
    a.updated_by,
    COALESCE(a.archived_at, tp.archived_at, upe.archived_at) AS archived_at,
    "user".effective_priority_id(tp.priority_id, tp.user_id) AS priority_id,
    upe.path AS priority_path,
    a.draft,
    a.contacts,
    a.contact_meta,
    a.groups,
    a.topic,
    a.title,
    a.preview,
    a.icon,
    a.merged_into_thread_id,
    a.embedding IS NOT NULL AS has_embedding,
    tp.mute_by_thread_id,
    a.last_note_created_at,
    a.last_note_source_created_at,
    ts.bumped_at,
    COALESCE(ts.read_at IS NULL AND ts.user_id IS NOT NULL, false) AS unread,
    COALESCE(ts.importance, 0::smallint) AS importance,
    COALESCE(ts.active, false) AS active,
    COALESCE(ts.task, false) AS task,
    COALESCE(ts.to_read, false) AS to_read,
    ts.urgent,
    ts."order" AS state_order,
    ts."on" AS state_on,
    ts.at AS state_at,
    COALESCE(GREATEST(a.last_note_source_created_at, la.source_created_at, ts.bumped_at, ( SELECT
                CASE
                    WHEN COALESCE(upper(s_feed.at), upper(s_feed."on")::timestamp with time zone) <= now() THEN COALESCE(upper(s_feed.at), upper(s_feed."on")::timestamp with time zone)
                    ELSE NULL::timestamp with time zone
                END AS "case"
           FROM public.schedule s_feed
          WHERE s_feed.thread_id = a.id AND s_feed.occurrence IS NULL AND s_feed.archived_at IS NULL
         LIMIT 1)), a.created_at) AS activity_at,
    ( SELECT tstzrange(bounds.lo, GREATEST(bounds.lo, bounds.hi), '[]'::text) AS tstzrange
           FROM ( SELECT COALESCE(LEAST(( SELECT COALESCE(lower(s_lo.at), lower(s_lo."on")::timestamp with time zone) AS "coalesce"
                           FROM public.schedule s_lo
                          WHERE s_lo.thread_id = a.id AND s_lo.archived_at IS NULL
                          ORDER BY (COALESCE(lower(s_lo.at), lower(s_lo."on")::timestamp with time zone))
                         LIMIT 1), COALESCE(lower(ts.at), lower(ts."on")::timestamp with time zone), ( SELECT COALESCE(lower(s_lo.at), lower(s_lo."on")::timestamp with time zone) AS "coalesce"
                           FROM public.schedule s_lo
                             JOIN public.link l_lo ON l_lo.id = s_lo.link_id
                          WHERE l_lo.thread_id = a.id AND s_lo.archived_at IS NULL
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
                              WHERE s_hi.thread_id = a.id AND s_hi.archived_at IS NULL
                              ORDER BY (COALESCE(upper(s_hi.at), upper(s_hi."on")::timestamp with time zone)) DESC NULLS LAST
                             LIMIT 1), COALESCE(upper(ts.at), upper(ts."on")::timestamp with time zone), ( SELECT COALESCE(upper(s_hi.at), upper(s_hi."on")::timestamp with time zone) AS "coalesce"
                               FROM public.schedule s_hi
                                 JOIN public.link l_hi ON l_hi.id = s_hi.link_id
                              WHERE l_hi.thread_id = a.id AND s_hi.archived_at IS NULL
                              ORDER BY (COALESCE(upper(s_hi.at), upper(s_hi."on")::timestamp with time zone)) DESC NULLS LAST
                             LIMIT 1))
                        END, a.created_at) AS hi) bounds) AS agenda_at,
    false AS revoked
   FROM public.thread a
     JOIN public.thread_priority tp ON tp.thread_id = a.id
     LEFT JOIN "user".priority_expanded upe ON upe.user_id = tp.user_id AND upe.priority_id = "user".effective_priority_id(tp.priority_id, tp.user_id)
     JOIN public.priority p ON p.id = "user".effective_priority_id(tp.priority_id, tp.user_id)
     LEFT JOIN public.thread_state ts ON ts.user_id = tp.user_id AND ts.thread_id = a.id
     LEFT JOIN link_agg la ON la.thread_id = a.id
  WHERE tp.revoked_at IS NULL AND (a.draft = false OR a.created_by = tp.user_id) AND (a.contacts && "user".user_contact_ids(tp.user_id) OR a.groups && "user".user_group_ids(tp.user_id)) AND (tp.priority_id IS NOT NULL OR tp.classify_at < (now() - public.classify_visibility_window())) AND (p.team_id IS NULL OR (EXISTS ( SELECT 1
           FROM public.team_user tu2
          WHERE tu2.team_id = p.team_id AND tu2.user_id = tp.user_id AND tu2.archived_at IS NULL)));
-- Modify "thread_redacted" view
CREATE OR REPLACE VIEW "user"."thread_redacted" (
  "user_id",
  "id",
  "created_at",
  "updated_at",
  "seq",
  "updated_by",
  "archived_at",
  "priority_id",
  "priority_path",
  "draft",
  "contacts",
  "contact_meta",
  "groups",
  "topic",
  "title",
  "preview",
  "icon",
  "merged_into_thread_id",
  "has_embedding",
  "mute_by_thread_id",
  "last_note_created_at",
  "last_note_source_created_at",
  "bumped_at",
  "unread",
  "importance",
  "active",
  "task",
  "to_read",
  "urgent",
  "state_order",
  "state_on",
  "state_at",
  "activity_at",
  "agenda_at",
  "revoked"
) AS SELECT tp.user_id,
    a.id,
    a.created_at,
    tp.revoked_at AS updated_at,
    tp.seq,
    a.updated_by,
    tp.revoked_at AS archived_at,
    "user".effective_priority_id(tp.priority_id, tp.user_id) AS priority_id,
    upe.path AS priority_path,
    a.draft,
    ARRAY[]::uuid[] AS contacts,
    '{}'::jsonb AS contact_meta,
    ARRAY[]::uuid[] AS groups,
    NULL::text AS topic,
    NULL::text AS title,
    NULL::text AS preview,
    NULL::text AS icon,
    NULL::uuid AS merged_into_thread_id,
    false AS has_embedding,
    NULL::uuid AS mute_by_thread_id,
    NULL::timestamp with time zone AS last_note_created_at,
    NULL::timestamp with time zone AS last_note_source_created_at,
    NULL::timestamp with time zone AS bumped_at,
    false AS unread,
    0::smallint AS importance,
    false AS active,
    false AS task,
    false AS to_read,
    NULL::boolean AS urgent,
    NULL::double precision AS state_order,
    NULL::daterange AS state_on,
    NULL::tstzrange AS state_at,
    a.created_at AS activity_at,
    tstzrange(a.created_at, a.created_at, '[]'::text) AS agenda_at,
    true AS revoked
   FROM public.thread a
     JOIN public.thread_priority tp ON tp.thread_id = a.id
     LEFT JOIN "user".priority_expanded upe ON upe.user_id = tp.user_id AND upe.priority_id = "user".effective_priority_id(tp.priority_id, tp.user_id)
  WHERE tp.revoked_at IS NOT NULL;
