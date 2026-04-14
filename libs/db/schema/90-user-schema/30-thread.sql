-- user.thread — per-user thread feed.
--
-- Filing is driven by thread_priority (one row per visible user). Visibility
-- is enforced by the contacts array: a user sees a thread only if any of
-- their linked contacts appears in thread.contacts. No more redacted stub
-- branch — if you don't have a thread_priority row, the thread doesn't
-- exist as far as you're concerned.
--
-- Transitional note (until Stage 4 lands): priority_expanded is still joined
-- to recover the user-specific priority path + per-user archived_at. When
-- priorities become per-user the join can be replaced with a direct join
-- on priority.
CREATE OR REPLACE VIEW "user"."thread"
--
AS
WITH link_agg AS (
    SELECT thread_id, MAX(source_created_at) AS source_created_at
    FROM link
    GROUP BY thread_id
)
SELECT
    tp.user_id,
    a.id,
    a.created_at,
    -- updated_at: use the latest of thread, last note, and thread_unread timestamps
    GREATEST (a.updated_at, COALESCE(a.last_note_created_at, 'epoch'::timestamptz),
        COALESCE(tu.updated_at, 'epoch'::timestamptz)) AS updated_at,
    a.updated_by,
    -- User-visible archived_at is the first of: global thread archive,
    -- per-user thread_priority archive, or per-user priority archive.
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
                 FROM schedule s_lo WHERE s_lo.thread_id = a.id AND s_lo.user_id = tp.user_id
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
                     FROM schedule s_hi WHERE s_hi.thread_id = a.id AND s_hi.user_id = tp.user_id
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
    thread a
    JOIN thread_priority tp ON tp.thread_id = a.id
    LEFT JOIN "user".priority_expanded upe
        ON upe.user_id = tp.user_id AND upe.priority_id = tp.priority_id
    LEFT JOIN thread_unread tu ON tu.user_id = tp.user_id
        AND tu.thread_id = a.id
    LEFT JOIN link_agg la ON la.thread_id = a.id
WHERE
    (a.draft = FALSE OR a.created_by = tp.user_id)
    AND (
        a.contacts && "user".user_contact_ids(tp.user_id)
        OR a.topics && "user".user_topic_ids(tp.user_id)
    );

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
