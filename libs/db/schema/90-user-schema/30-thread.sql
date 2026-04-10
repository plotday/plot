-- Unread is now explicit via thread_unread table. When a thread_unread row exists
-- with read_at IS NULL, the thread is unread. The complex timestamp comparison
-- logic is no longer needed since unread classification is done by note analysis.
CREATE OR REPLACE VIEW "user"."thread"
--
AS
WITH link_agg AS (
    SELECT thread_id, MAX(source_created_at) AS source_created_at
    FROM link
    GROUP BY thread_id
)
SELECT
    upe.user_id,
    a.id,
    a.created_at,
    -- updated_at: when thread_unread exists, use its updated_at; otherwise use thread timestamps
    GREATEST (a.updated_at, COALESCE(a.last_note_created_at, 'epoch'::timestamptz),
        COALESCE(tu.updated_at, 'epoch'::timestamptz)) AS updated_at,
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
    -- Unread: TRUE when thread_unread row exists and read_at is NULL
    COALESCE(tu.read_at IS NULL AND tu.user_id IS NOT NULL, FALSE) AS unread,
    COALESCE(CASE WHEN tu.read_at IS NULL AND tu.user_id IS NOT NULL THEN tu.importance END, 0::smallint) AS importance,
    COALESCE(CASE WHEN tu.read_at IS NULL AND tu.user_id IS NOT NULL THEN tu.urgency END, NULL) AS urgency,
    -- activity_at: feed ordering timestamp
    COALESCE(
        GREATEST(
            a.last_note_source_created_at,
            la.source_created_at,
            tu.bumped_at,
            (SELECT CASE
                WHEN COALESCE(upper(s_feed.at), upper(s_feed."on")::timestamptz) <= now()
                THEN COALESCE(upper(s_feed.at), upper(s_feed."on")::timestamptz)
            END
            FROM schedule s_feed
            WHERE s_feed.thread_id = a.id
                AND s_feed.user_id IS NULL
                AND s_feed.occurrence IS NULL
                AND s_feed.archived_at IS NULL
            LIMIT 1)
        ),
        a.created_at
    ) AS activity_at,
    -- agenda_at: range from earliest schedule start to latest end (or infinity for recurring/unbounded)
    -- Considers both direct thread schedules (thread_id) and link schedules (link_id → link.thread_id)
    -- Uses GREATEST on upper bound to guarantee upper >= lower (prevents tstzrange error)
    (SELECT tstzrange(
        lo,
        GREATEST(lo, hi),
        '[]'
    ) FROM (SELECT
        COALESCE(
            LEAST(
                -- Direct shared schedule start
                (SELECT COALESCE(lower(s_lo.at), lower(s_lo."on")::timestamptz)
                 FROM schedule s_lo WHERE s_lo.thread_id = a.id AND s_lo.user_id IS NULL
                 AND s_lo.archived_at IS NULL
                 ORDER BY COALESCE(lower(s_lo.at), lower(s_lo."on")::timestamptz) ASC NULLS LAST
                 LIMIT 1),
                -- Direct per-user schedule start
                (SELECT COALESCE(lower(s_lo.at), lower(s_lo."on")::timestamptz)
                 FROM schedule s_lo WHERE s_lo.thread_id = a.id AND s_lo.user_id = upe.user_id
                 AND s_lo.archived_at IS NULL
                 ORDER BY COALESCE(lower(s_lo.at), lower(s_lo."on")::timestamptz) ASC NULLS LAST
                 LIMIT 1),
                -- Link schedule start (calendar events from sources)
                (SELECT COALESCE(lower(s_lo.at), lower(s_lo."on")::timestamptz)
                 FROM schedule s_lo
                 JOIN link l_lo ON l_lo.id = s_lo.link_id
                 WHERE l_lo.thread_id = a.id AND s_lo.user_id IS NULL
                 AND s_lo.archived_at IS NULL
                 ORDER BY COALESCE(lower(s_lo.at), lower(s_lo."on")::timestamptz) ASC NULLS LAST
                 LIMIT 1)
            ),
            a.created_at
        ) AS lo,
        COALESCE(
            CASE
                -- Recurring schedules span to infinity (direct or link)
                WHEN EXISTS (
                    SELECT 1 FROM schedule s_rec
                    WHERE s_rec.thread_id = a.id AND s_rec.archived_at IS NULL
                    AND s_rec.recurrence_rule IS NOT NULL
                ) OR EXISTS (
                    SELECT 1 FROM schedule s_rec
                    JOIN link l_rec ON l_rec.id = s_rec.link_id
                    WHERE l_rec.thread_id = a.id AND s_rec.archived_at IS NULL
                    AND s_rec.recurrence_rule IS NOT NULL
                ) THEN 'infinity'::timestamptz
                -- Unbounded-upper schedules (direct or link)
                WHEN EXISTS (
                    SELECT 1 FROM schedule s_ub
                    WHERE s_ub.thread_id = a.id AND s_ub.archived_at IS NULL
                    AND (s_ub.at IS NOT NULL OR s_ub."on" IS NOT NULL)
                    AND COALESCE(upper(s_ub.at), upper(s_ub."on")::timestamptz) IS NULL
                ) OR EXISTS (
                    SELECT 1 FROM schedule s_ub
                    JOIN link l_ub ON l_ub.id = s_ub.link_id
                    WHERE l_ub.thread_id = a.id AND s_ub.archived_at IS NULL
                    AND (s_ub.at IS NOT NULL OR s_ub."on" IS NOT NULL)
                    AND COALESCE(upper(s_ub.at), upper(s_ub."on")::timestamptz) IS NULL
                ) THEN 'infinity'::timestamptz
                ELSE GREATEST(
                    -- Direct shared schedule end
                    (SELECT COALESCE(upper(s_hi.at), upper(s_hi."on")::timestamptz)
                     FROM schedule s_hi WHERE s_hi.thread_id = a.id AND s_hi.user_id IS NULL
                     AND s_hi.archived_at IS NULL
                     ORDER BY COALESCE(upper(s_hi.at), upper(s_hi."on")::timestamptz) DESC NULLS LAST
                     LIMIT 1),
                    -- Direct per-user schedule end
                    (SELECT COALESCE(upper(s_hi.at), upper(s_hi."on")::timestamptz)
                     FROM schedule s_hi WHERE s_hi.thread_id = a.id AND s_hi.user_id = upe.user_id
                     AND s_hi.archived_at IS NULL
                     ORDER BY COALESCE(upper(s_hi.at), upper(s_hi."on")::timestamptz) DESC NULLS LAST
                     LIMIT 1),
                    -- Link schedule end
                    (SELECT COALESCE(upper(s_hi.at), upper(s_hi."on")::timestamptz)
                     FROM schedule s_hi
                     JOIN link l_hi ON l_hi.id = s_hi.link_id
                     WHERE l_hi.thread_id = a.id AND s_hi.user_id IS NULL
                     AND s_hi.archived_at IS NULL
                     ORDER BY COALESCE(upper(s_hi.at), upper(s_hi."on")::timestamptz) DESC NULLS LAST
                     LIMIT 1)
                )
            END,
            a.created_at
        ) AS hi
    ) bounds) AS agenda_at
FROM
    thread_x a
    JOIN "user".priority_expanded upe ON a.priority_id = upe.priority_id
    LEFT JOIN thread_unread tu ON tu.user_id = upe.user_id
        AND tu.thread_id = a.id
    LEFT JOIN link_agg la ON la.thread_id = a.id
WHERE
    (a.draft = FALSE OR a.created_by = upe.user_id)
    AND (CASE
        WHEN a.access = 'public' THEN TRUE
        WHEN a.created_by = upe.user_id THEN TRUE
        WHEN a.access = 'members' AND upe.role = 'member' THEN TRUE
        WHEN a.access_contacts && "user".user_contact_ids(upe.user_id) THEN TRUE
        ELSE FALSE
    END)
UNION ALL
-- Redacted rows for private threads the user cannot see
SELECT
    upe.user_id,
    a.id,
    a.created_at,
    a.updated_at,
    a.updated_by,
    COALESCE(a.archived_at, upe.archived_at, a.updated_at) AS archived_at,
    a.priority_id,
    upe.path AS priority_path,
    a.draft,
    a.access,
    CAST(NULL AS uuid[]) AS access_contacts,
    NULL::text AS title,
    NULL::text AS preview,
    a.icon,
    a.last_note_created_at,
    a.last_note_source_created_at,
    NULL::timestamptz AS bumped_at,
    FALSE AS unread,
    0::smallint AS importance,
    NULL::text AS urgency,
    a.created_at AS activity_at,
    tstzrange(a.created_at, a.created_at, '[]') AS agenda_at
FROM
    thread_x a
    JOIN "user".priority_expanded upe ON a.priority_id = upe.priority_id
WHERE
    (a.draft = FALSE OR a.created_by = upe.user_id)
    AND a.access != 'public'
    AND a.created_by != upe.user_id
    AND NOT (a.access = 'members' AND upe.role = 'member')
    AND NOT (COALESCE(a.access_contacts, ARRAY[]::uuid[]) && "user".user_contact_ids(upe.user_id));

ALTER VIEW "user"."thread" OWNER TO postgres;

CREATE OR REPLACE VIEW "user"."thread_tags"
--
AS
SELECT
    ua.user_id,
    ua.id,
    ua.archived_at,
    tt.occurrence,
    tt.updated_at,
    ua.priority_id,
    ua.priority_path,
    tt.tags
FROM
    "user".thread ua
    JOIN LATERAL (
        SELECT
            sq.occurrence,
            jsonb_object_agg(sq.tag_id, sq.actor_ids) FILTER (WHERE sq.actor_ids IS NOT NULL
                AND jsonb_array_length(sq.actor_ids) > 0) AS tags,
            MAX(sq.updated_at) AS updated_at
        FROM (
            SELECT
                at.occurrence,
                at.tag_id,
                jsonb_agg(at.actor_id) FILTER (WHERE at.archived_at IS NULL) AS actor_ids,
                MAX(COALESCE(at.archived_at, at.updated_at)) AS updated_at
            FROM
                "public"."thread_tag" at
            WHERE
                at.thread_id = ua.id
            GROUP BY
                at.occurrence,
                at.tag_id) sq
        GROUP BY
            sq.occurrence) tt ON true;

ALTER VIEW "user"."thread_tags" OWNER TO postgres;
