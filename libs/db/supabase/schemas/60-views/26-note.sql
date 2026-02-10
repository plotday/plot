-- User-accessible notes filtered by priority access
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
    n.mentions,
    n.re_note_id
FROM
    note n
    JOIN activity a ON a.id = n.activity_id
    JOIN user_priority_expanded upe ON upe.priority_id = a.priority_id
WHERE
    (auth.uid() IS NULL OR upe.user_id = auth.uid())
    -- Note-level filtering
    AND (n.draft = FALSE OR auth.uid() IS NULL OR n.created_by = auth.uid())
    AND (n.private = FALSE OR auth.uid() IS NULL
        OR n.created_by = auth.uid()
        OR auth.uid() = ANY(n.mentions))
    -- Activity-level filtering (activity draft/private affects note visibility)
    AND (a.draft = FALSE OR auth.uid() IS NULL OR a.created_by = auth.uid())
    AND (CASE WHEN a.private = FALSE THEN TRUE
        WHEN auth.uid() IS NULL THEN TRUE
        WHEN a.created_by = auth.uid() THEN TRUE
        ELSE public.user_mentioned_in_activity(auth.uid(), a.id)
    END)
UNION ALL
-- Redacted rows for private notes the user cannot see
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
    CAST(NULL AS uuid[]) AS mentions,
    n.re_note_id
FROM
    note n
    JOIN activity a ON a.id = n.activity_id
    JOIN user_priority_expanded upe ON upe.priority_id = a.priority_id
WHERE
    auth.uid() IS NOT NULL
    AND upe.user_id = auth.uid()
    AND (n.draft = FALSE OR n.created_by = auth.uid())
    AND (a.draft = FALSE OR a.created_by = auth.uid())
    -- Hidden by note-level OR activity-level privacy
    AND (
        -- Note is private and user can't see it
        (n.private = TRUE
            AND n.created_by != auth.uid()
            AND NOT (auth.uid() = ANY(COALESCE(n.mentions, CAST('{}' AS uuid[])))))
        OR
        -- Activity is private and user can't see it
        (a.private = TRUE
            AND a.created_by != auth.uid()
            AND NOT public.user_mentioned_in_activity(auth.uid(), a.id))
    );

ALTER VIEW "public"."user_note" OWNER TO postgres;
REVOKE SELECT ON "public"."user_note" FROM anon;

-- Aggregate note tags by note_id
CREATE OR REPLACE VIEW "public"."note_tags" WITH ( security_invoker = TRUE)
--
AS
SELECT
    sq.note_id,
    jsonb_object_agg(sq.tag_id, sq.actor_ids) FILTER (WHERE sq.actor_ids IS NOT NULL
        AND jsonb_array_length(sq.actor_ids) > 0) AS tags,
    MAX(sq.updated_at) AS updated_at,
    (array_agg(sq.updated_by ORDER BY sq.updated_at DESC))[1] AS updated_by
FROM (
    SELECT
        nt.note_id,
        nt.tag_id,
        jsonb_agg(nt.actor_id) FILTER (WHERE nt.archived_at IS NULL) AS actor_ids,
        MAX(COALESCE(nt.archived_at, nt.updated_at)) AS updated_at,
        (array_agg(nt.updated_by ORDER BY nt.updated_at DESC))[1] AS updated_by
    FROM
        "public"."note_tag" nt
    GROUP BY
        nt.note_id,
        nt.tag_id) sq
GROUP BY
    sq.note_id;

-- User-accessible note tags
CREATE OR REPLACE VIEW "public"."user_note_tags"
--
AS
SELECT
    ua.user_id,
    n.id,
    nt.updated_at,
    ua.archived_at,
    ua.priority_path,
    ua.range_at,
    ua.range_on,
    nt.tags
FROM
    note_tags nt
    JOIN note n ON n.id = nt.note_id
    JOIN user_activity ua ON ua.id = n.activity_id
WHERE
    (n.draft = FALSE OR auth.uid() IS NULL OR n.created_by = auth.uid())
    AND (n.private = FALSE OR auth.uid() IS NULL
        OR n.created_by = auth.uid()
        OR auth.uid() = ANY(n.mentions));

ALTER VIEW "public"."user_note_tags" OWNER TO postgres;
REVOKE SELECT ON "public"."user_note_tags" FROM anon;

