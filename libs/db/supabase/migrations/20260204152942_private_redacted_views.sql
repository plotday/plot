CREATE OR REPLACE VIEW "public"."user_activity"
--
AS
SELECT
    upe.user_id,
    a.id,
    a.created_at,
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
                                a.last_note_created_at
                            ELSE
                                COALESCE(a.last_note_created_at, a.created_at)
                            END) THEN
                        ar.updated_at
                    END, 'epoch'::timestamptz), CASE WHEN a.created_by = upe.user_id THEN
                    COALESCE(a.last_note_created_at, 'epoch'::timestamptz)
                ELSE
                    COALESCE(a.last_note_created_at, a.created_at)
                END)
        ELSE
            'epoch'::timestamptz
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
    CASE WHEN a.done_at IS NOT NULL THEN
        tstzrange(a.done_at, a.done_at, '[]')
    WHEN (a.assignee_id IS NOT NULL
        AND (
            SELECT
                c.user_id
            FROM
                contact c
            WHERE
                c.id = a.assignee_id) != upe.user_id)
        OR a."on" IS NULL THEN
        CASE WHEN LOWER(a.at) >= GREATEST (a.source_created_at, COALESCE(a.last_note_source_created_at, 'epoch'::timestamptz)) THEN
            a.at
        ELSE
            tstzrange(GREATEST (a.source_created_at, COALESCE(a.last_note_source_created_at, 'epoch'::timestamptz)), GREATEST (a.source_created_at, COALESCE(a.last_note_source_created_at, 'epoch'::timestamptz)), '[]')
        END
    ELSE
        NULL::tstzrange
    END AS range_at,
    CASE WHEN a.done_at IS NOT NULL THEN
        NULL::daterange
    WHEN a.assignee_id IS NOT NULL
        AND (
            SELECT
                c.user_id
            FROM
                contact c
            WHERE
                c.id = a.assignee_id) != upe.user_id THEN
        NULL::daterange
    WHEN a.at IS NOT NULL THEN
        NULL::daterange
    WHEN a."on" IS NOT NULL THEN
        a."on"
    ELSE
        NULL::daterange
    END AS range_on,
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
                    a.last_note_created_at
                ELSE
                    COALESCE(a.last_note_created_at, a.created_at)
                END)
        ELSE
            FALSE
        END, FALSE) AS unread
FROM
    activity_x a
    JOIN user_priority_expanded upe ON a.priority_id = upe.priority_id
    LEFT JOIN activity_read ar ON ar.user_id = upe.user_id
        AND ar.activity_id = a.id
WHERE
    (auth.uid() IS NULL OR upe.user_id = auth.uid())
    AND (a.draft = FALSE OR auth.uid() IS NULL OR a.created_by = auth.uid())
    AND (CASE WHEN a.private = FALSE THEN TRUE
        WHEN auth.uid() IS NULL THEN TRUE
        WHEN a.created_by = auth.uid() THEN TRUE
        ELSE public.user_mentioned_in_activity(auth.uid(), a.id)
    END)
UNION ALL
SELECT
    upe.user_id,
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
    CAST(NULL AS timestamptz[]) AS recurrence_exdates,
    NULL::jsonb AS meta,
    NULL::text AS source,
    a.created_by_twist_id,
    a.last_note_created_at,
    a.last_note_source_created_at,
    CAST(NULL AS uuid[]) AS mentions,
    NULL::tstzrange AS range_at,
    NULL::daterange AS range_on,
    FALSE AS unread
FROM
    activity_x a
    JOIN user_priority_expanded upe ON a.priority_id = upe.priority_id
WHERE
    auth.uid() IS NOT NULL
    AND upe.user_id = auth.uid()
    AND (a.draft = FALSE OR a.created_by = auth.uid())
    AND a.private = TRUE
    AND a.created_by != auth.uid()
    AND NOT public.user_mentioned_in_activity(auth.uid(), a.id);

CREATE OR REPLACE VIEW "public"."user_note"
--
AS
SELECT
    upe.user_id,
    n.id,
    n.created_at,
    n.updated_at,
    n.source_created_at,
    n.author_id,
    n.created_by,
    n.updated_by,
    n.archived_at,
    n.activity_id,
    n.draft,
    n.private,
    n.content,
    n.links,
    n.mentions
FROM
    note n
    JOIN activity a ON a.id = n.activity_id
    JOIN user_priority_expanded upe ON upe.priority_id = a.priority_id
WHERE
    (auth.uid() IS NULL OR upe.user_id = auth.uid())
    AND (n.draft = FALSE OR auth.uid() IS NULL OR n.created_by = auth.uid())
    AND (n.private = FALSE OR auth.uid() IS NULL
        OR n.created_by = auth.uid()
        OR auth.uid() = ANY(n.mentions))
    AND (a.draft = FALSE OR auth.uid() IS NULL OR a.created_by = auth.uid())
    AND (CASE WHEN a.private = FALSE THEN TRUE
        WHEN auth.uid() IS NULL THEN TRUE
        WHEN a.created_by = auth.uid() THEN TRUE
        ELSE public.user_mentioned_in_activity(auth.uid(), a.id)
    END)
UNION ALL
SELECT
    upe.user_id,
    n.id,
    n.created_at,
    n.updated_at,
    n.source_created_at,
    n.author_id,
    n.created_by,
    n.updated_by,
    COALESCE(n.archived_at, n.updated_at) AS archived_at,
    n.activity_id,
    n.draft,
    n.private,
    NULL::text AS content,
    NULL::jsonb AS links,
    CAST(NULL AS uuid[]) AS mentions
FROM
    note n
    JOIN activity a ON a.id = n.activity_id
    JOIN user_priority_expanded upe ON upe.priority_id = a.priority_id
WHERE
    auth.uid() IS NOT NULL
    AND upe.user_id = auth.uid()
    AND (n.draft = FALSE OR n.created_by = auth.uid())
    AND (a.draft = FALSE OR a.created_by = auth.uid())
    AND (
        (n.private = TRUE
            AND n.created_by != auth.uid()
            AND NOT (auth.uid() = ANY(COALESCE(n.mentions, CAST('{}' AS uuid[])))))
        OR
        (a.private = TRUE
            AND a.created_by != auth.uid()
            AND NOT public.user_mentioned_in_activity(auth.uid(), a.id))
    );
