-- Unread calculation is inlined from the former user_thread_unread view to avoid
-- a redundant evaluation of user_priority_expanded. thread_read is joined directly
-- with the read threshold applied conditionally in the SELECT expressions.
--
-- Contact lookup for assignee uses a scalar subquery instead of LEFT JOIN to avoid
-- probing the full contact table for every row (most threads have no assignee).
CREATE OR REPLACE VIEW "user"."thread"
--
AS
WITH link_agg AS (
    SELECT thread_id, MAX(source_created_at) AS source_created_at
    FROM link
    GROUP BY thread_id
),
user_done AS (
    SELECT thread_id, user_id, done_at
    FROM schedule
    WHERE link_id IS NULL AND occurrence IS NULL AND done_at IS NOT NULL
)
SELECT
    upe.user_id,
    a.id,
    a.created_at,
    -- updated_at includes last_note_created_at and thread_read contributions
    -- thread_read updated_at only contributes when read_at >= unread threshold
    -- (matching the former user_thread_unread semantics)
    GREATEST (a.updated_at, COALESCE(a.last_note_created_at, 'epoch'::timestamptz),
        CASE WHEN a.archived_at IS NULL
            AND ((a.created_by = upe.user_id
                    AND a.last_note_created_at IS NOT NULL
                    AND a.last_note_created_at > upe.joined_at)
                OR ((a.created_by IS NULL
                        OR a.created_by != upe.user_id)
                    AND COALESCE(a.last_note_created_at, a.created_at) > upe.joined_at))
        THEN
            GREATEST (COALESCE(CASE WHEN ar.read_at >= (CASE WHEN a.created_by = upe.user_id THEN
                                a.last_note_source_created_at
                            ELSE
                                COALESCE(GREATEST(a.last_note_source_created_at, la.source_created_at, ud.done_at), a.created_at)
                            END) THEN
                        ar.updated_at
                    END, 'epoch'::timestamptz), CASE WHEN a.created_by = upe.user_id THEN
                    COALESCE(a.last_note_source_created_at, 'epoch'::timestamptz)
                ELSE
                    COALESCE(GREATEST(a.last_note_source_created_at, la.source_created_at, ud.done_at), a.created_at)
                END)
        ELSE
            'epoch'::timestamptz
        END) AS updated_at,
    a.updated_by,
    COALESCE(a.archived_at, upe.archived_at) AS archived_at,
    a.priority_id,
    a.priority_path,
    a.draft,
    a.private,
    a.title,
    a.preview,
    a.last_note_created_at,
    a.last_note_source_created_at,
    a.mentions,
    -- Unread: TRUE only for non-archived threads where read is missing or stale
    COALESCE(CASE WHEN a.archived_at IS NULL
            AND ((a.created_by = upe.user_id
                    AND a.last_note_created_at IS NOT NULL
                    AND a.last_note_created_at > upe.joined_at)
                OR ((a.created_by IS NULL
                        OR a.created_by != upe.user_id)
                    AND COALESCE(a.last_note_created_at, a.created_at) > upe.joined_at))
        THEN
            ar.read_at IS NULL
            OR ar.read_at < (CASE WHEN a.created_by = upe.user_id THEN
                    a.last_note_source_created_at
                ELSE
                    COALESCE(GREATEST(a.last_note_source_created_at, la.source_created_at, ud.done_at), a.created_at)
                END)
        ELSE
            FALSE
        END, FALSE) AS unread,
    -- activity_at: feed ordering timestamp
    -- GREATEST(lastNoteSourceCreatedAt, link.sourceCreatedAt, userSchedule.doneAt),
    -- falling back to created_at when all three are null
    COALESCE(
        GREATEST(
            a.last_note_source_created_at,
            la.source_created_at,
            ud.done_at
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
             AND s_agg.archived_at IS NULL AND s_agg.done_at IS NULL
             ORDER BY COALESCE(lower(s_agg.at), lower(s_agg."on")::timestamptz) ASC NULLS LAST
             LIMIT 1)
        ),
        a.created_at
    ) AS agenda_at
FROM
    thread_x a
    JOIN "user".priority_expanded upe ON a.priority_id = upe.priority_id
    LEFT JOIN thread_read ar ON ar.user_id = upe.user_id
        AND ar.thread_id = a.id
    LEFT JOIN link_agg la ON la.thread_id = a.id
    LEFT JOIN user_done ud ON ud.thread_id = a.id AND ud.user_id = upe.user_id
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
    a.priority_path,
    a.draft,
    a.private,
    NULL::text AS title,
    NULL::text AS preview,
    a.last_note_created_at,
    a.last_note_source_created_at,
    CAST(NULL AS uuid[]) AS mentions,
    FALSE AS unread,
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
    at.occurrence,
    at.updated_at,
    ua.priority_path,
    at.tags
FROM
    thread_tags at
    JOIN "user".thread ua ON ua.id = at.thread_id;

ALTER VIEW "user"."thread_tags" OWNER TO postgres;
