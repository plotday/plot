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
    a.private,
    a.title,
    a.preview,
    a.last_note_created_at,
    a.last_note_source_created_at,
    a.mentions,
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
    -- agenda_at: earliest schedule start (shared, user, or link) for forward-agenda sorting
    COALESCE(
        LEAST(
            (SELECT COALESCE(lower(s_agg.at), lower(s_agg."on")::timestamptz)
             FROM schedule s_agg WHERE s_agg.thread_id = a.id AND s_agg.user_id IS NULL
             AND s_agg.archived_at IS NULL
             ORDER BY COALESCE(lower(s_agg.at), lower(s_agg."on")::timestamptz) ASC NULLS LAST
             LIMIT 1),
            (SELECT COALESCE(lower(s_agg.at), lower(s_agg."on")::timestamptz)
             FROM schedule s_agg WHERE s_agg.thread_id = a.id AND s_agg.user_id = upe.user_id
             AND s_agg.archived_at IS NULL
             ORDER BY COALESCE(lower(s_agg.at), lower(s_agg."on")::timestamptz) ASC NULLS LAST
             LIMIT 1)
        ),
        a.created_at
    ) AS agenda_at
FROM
    thread_x a
    JOIN "user".priority_expanded upe ON a.priority_id = upe.priority_id
    LEFT JOIN thread_unread tu ON tu.user_id = upe.user_id
        AND tu.thread_id = a.id
    LEFT JOIN link_agg la ON la.thread_id = a.id
WHERE
    (a.draft = FALSE OR a.created_by = upe.user_id)
    AND (CASE WHEN a.private = FALSE THEN TRUE
        WHEN a.created_by = upe.user_id THEN TRUE
        ELSE "user".mentioned_in_thread(upe.user_id, a.id)
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
    a.private,
    NULL::text AS title,
    NULL::text AS preview,
    a.last_note_created_at,
    a.last_note_source_created_at,
    CAST(NULL AS uuid[]) AS mentions,
    NULL::timestamptz AS bumped_at,
    FALSE AS unread,
    0::smallint AS importance,
    NULL::text AS urgency,
    a.created_at AS activity_at,
    a.created_at AS agenda_at
FROM
    thread_x a
    JOIN "user".priority_expanded upe ON a.priority_id = upe.priority_id
WHERE
    (a.draft = FALSE OR a.created_by = upe.user_id)
    AND a.private = TRUE
    AND a.created_by != upe.user_id
    AND NOT "user".mentioned_in_thread(upe.user_id, a.id);

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
