-- Modify "activity" view
CREATE OR REPLACE VIEW "user"."activity" (
  "user_id",
  "id",
  "created_at",
  "updated_at",
  "source_created_at",
  "author_id",
  "assignee_id",
  "updated_by",
  "archived_at",
  "priority_id",
  "priority_path",
  "type",
  "kind",
  "order",
  "draft",
  "private",
  "title",
  "preview",
  "at",
  "on",
  "duration",
  "done_at",
  "recurrence_rule",
  "recurrence_exdates",
  "meta",
  "source",
  "created_by_twist_id",
  "last_note_created_at",
  "last_note_source_created_at",
  "mentions",
  "range_at",
  "range_on",
  "unread"
) AS SELECT upe.user_id,
    a.id,
    a.created_at,
    GREATEST(a.updated_at, COALESCE(a.last_note_created_at, '1970-01-01 00:00:00+00'::timestamp with time zone),
        CASE
            WHEN a.archived_at IS NULL AND (a.created_by = upe.user_id AND a.last_note_created_at IS NOT NULL AND a.last_note_created_at > upe.joined_at OR (a.created_by IS NULL OR a.created_by <> upe.user_id) AND COALESCE(a.last_note_created_at, a.created_at) > upe.joined_at) THEN GREATEST(COALESCE(
            CASE
                WHEN ar.read_at >=
                CASE
                    WHEN a.created_by = upe.user_id THEN a.last_note_source_created_at
                    ELSE COALESCE(a.last_note_source_created_at, a.source_created_at)
                END THEN ar.updated_at
                ELSE NULL::timestamp with time zone
            END, '1970-01-01 00:00:00+00'::timestamp with time zone),
            CASE
                WHEN a.created_by = upe.user_id THEN COALESCE(a.last_note_source_created_at, '1970-01-01 00:00:00+00'::timestamp with time zone)
                ELSE COALESCE(a.last_note_source_created_at, a.source_created_at)
            END)
            ELSE '1970-01-01 00:00:00+00'::timestamp with time zone
        END) AS updated_at,
    a.source_created_at,
    a.author_id,
    a.assignee_id,
    a.updated_by,
    COALESCE(a.archived_at, upe.archived_at) AS archived_at,
    a.priority_id,
    a.priority_path,
    a.type,
    a.kind,
    a."order",
    a.draft,
    a.private,
    a.title,
    a.preview,
    a.at,
    a."on",
    a.duration,
    a.done_at,
    a.recurrence_rule,
    a.recurrence_exdates,
    a.meta,
    a.source,
    a.created_by_twist_id,
    a.last_note_created_at,
    a.last_note_source_created_at,
    a.mentions,
        CASE
            WHEN a.done_at IS NOT NULL THEN tstzrange(a.done_at, a.done_at, '[]'::text)
            WHEN a.assignee_id IS NOT NULL AND (( SELECT c.user_id
               FROM public.contact c
              WHERE c.id = a.assignee_id)) <> upe.user_id OR a."on" IS NULL THEN
            CASE
                WHEN lower(a.at) >= GREATEST(a.source_created_at, COALESCE(a.last_note_source_created_at, '1970-01-01 00:00:00+00'::timestamp with time zone)) THEN a.at
                ELSE tstzrange(GREATEST(a.source_created_at, COALESCE(a.last_note_source_created_at, '1970-01-01 00:00:00+00'::timestamp with time zone)), GREATEST(a.source_created_at, COALESCE(a.last_note_source_created_at, '1970-01-01 00:00:00+00'::timestamp with time zone)), '[]'::text)
            END
            ELSE NULL::tstzrange
        END AS range_at,
        CASE
            WHEN a.done_at IS NOT NULL THEN NULL::daterange
            WHEN a.assignee_id IS NOT NULL AND (( SELECT c.user_id
               FROM public.contact c
              WHERE c.id = a.assignee_id)) <> upe.user_id THEN NULL::daterange
            WHEN a.at IS NOT NULL THEN NULL::daterange
            WHEN a."on" IS NOT NULL THEN a."on"
            ELSE NULL::daterange
        END AS range_on,
    COALESCE(
        CASE
            WHEN a.archived_at IS NULL AND (a.created_by = upe.user_id AND a.last_note_created_at IS NOT NULL AND a.last_note_created_at > upe.joined_at OR (a.created_by IS NULL OR a.created_by <> upe.user_id) AND COALESCE(a.last_note_created_at, a.created_at) > upe.joined_at) THEN ar.read_at IS NULL OR ar.read_at <
            CASE
                WHEN a.created_by = upe.user_id THEN a.last_note_source_created_at
                ELSE COALESCE(a.last_note_source_created_at, a.source_created_at)
            END
            ELSE false
        END, false) AS unread
   FROM public.activity_x a
     JOIN "user".priority_expanded upe ON a.priority_id = upe.priority_id
     LEFT JOIN public.activity_read ar ON ar.user_id = upe.user_id AND ar.activity_id = a.id
  WHERE (a.draft = false OR a.created_by = upe.user_id) AND
        CASE
            WHEN a.private = false THEN true
            WHEN a.created_by = upe.user_id THEN true
            ELSE "user".mentioned_in_activity(upe.user_id, a.id)
        END
UNION ALL
 SELECT upe.user_id,
    a.id,
    a.created_at,
    a.updated_at,
    a.source_created_at,
    a.author_id,
    a.assignee_id,
    a.updated_by,
    COALESCE(a.archived_at, upe.archived_at, a.updated_at) AS archived_at,
    a.priority_id,
    a.priority_path,
    a.type,
    a.kind,
    a."order",
    a.draft,
    a.private,
    NULL::text AS title,
    NULL::text AS preview,
    NULL::tstzrange AS at,
    NULL::daterange AS "on",
    NULL::interval AS duration,
    a.done_at,
    NULL::text AS recurrence_rule,
    NULL::timestamp with time zone[] AS recurrence_exdates,
    NULL::jsonb AS meta,
    NULL::text AS source,
    a.created_by_twist_id,
    a.last_note_created_at,
    a.last_note_source_created_at,
    NULL::uuid[] AS mentions,
    NULL::tstzrange AS range_at,
    NULL::daterange AS range_on,
    false AS unread
   FROM public.activity_x a
     JOIN "user".priority_expanded upe ON a.priority_id = upe.priority_id
  WHERE (a.draft = false OR a.created_by = upe.user_id) AND a.private = true AND a.created_by <> upe.user_id AND NOT "user".mentioned_in_activity(upe.user_id, a.id);
