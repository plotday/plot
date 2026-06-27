-- user.note — per-user note feed (visible rows only).
--
-- Split from the old UNION-ALL view for sync performance: pushing LIMIT
-- through a UNION stalled the planner and timed out initial syncs for
-- users with many accessible threads. Redacted stubs for notes a user
-- can no longer see live in user.note_redacted and are queried only on
-- incremental sync (when the client already has local copies to reconcile).
CREATE OR REPLACE VIEW "user"."note"
--
AS
SELECT
    tp.user_id,
    n.id,
    n.created_at,
    n.updated_at,
    n.seq,
    n.source_created_at,
    n.author_id,
    n.created_by,
    n.updated_by,
    n.archived_at,
    n.thread_id,
    n.draft,
    n.access_contacts,
    n.access_groups,
    n.content,
    n.actions,
    n.cta,
    n.delivery_error,
    n.mentions,
    n.re_note_id,
    n.merged_from_thread_id,
    n.section_key,
    n.section_label,
    n.section_position,
    n.item_position
FROM
    note n
    JOIN thread a ON a.id = n.thread_id
    JOIN thread_priority tp ON tp.thread_id = a.id
        AND tp.revoked_at IS NULL
        AND (
            tp.priority_id IS NOT NULL
            OR tp.classify_at < now() - public.classify_visibility_window()
        )
WHERE
    -- Note-level filtering
    (n.draft = FALSE OR n.created_by = tp.user_id)
    AND (
        n.created_by = tp.user_id
        OR (n.access_contacts IS NULL AND n.access_groups IS NULL)
        OR (n.access_contacts IS NOT NULL AND n.access_contacts && "user".user_contact_ids(tp.user_id))
        OR (n.access_groups IS NOT NULL AND n.access_groups && "user".user_group_ids(tp.user_id))
    )
    -- Thread-level filtering
    AND (a.draft = FALSE OR a.created_by = tp.user_id)
    AND (
        a.contacts && "user".user_contact_ids(tp.user_id)
        OR a.groups && "user".user_group_ids(tp.user_id)
        OR (a.topic_id IS NOT NULL AND a.topic_id = ANY("user".user_topic_ids(tp.user_id)))
    );


-- user.note_redacted — stub rows for notes the user can no longer see.
--
-- Queried by the sync handler only when the client already has local data
-- (i.e. a non-epoch updated_since). On initial sync we skip it because a
-- fresh client has nothing to reconcile. The updated_since filter keeps
-- this branch small on incremental syncs.
CREATE OR REPLACE VIEW "user"."note_redacted"
--
AS
SELECT
    tp.user_id,
    n.id,
    n.created_at,
    n.updated_at,
    n.seq,
    n.source_created_at,
    n.author_id,
    n.created_by,
    n.updated_by,
    COALESCE(n.archived_at, n.updated_at) AS archived_at,
    n.thread_id,
    n.draft,
    CAST(NULL AS uuid[]) AS access_contacts,
    CAST(NULL AS uuid[]) AS access_groups,
    NULL::text AS content,
    NULL::jsonb AS actions,
    NULL::jsonb AS cta,
    NULL::jsonb AS delivery_error,
    CAST(NULL AS uuid[]) AS mentions,
    n.re_note_id,
    n.merged_from_thread_id,
    NULL::text AS section_key,
    NULL::text AS section_label,
    NULL::text AS section_position,
    NULL::text AS item_position
FROM
    note n
    JOIN thread a ON a.id = n.thread_id
    JOIN thread_priority tp ON tp.thread_id = a.id
        AND tp.revoked_at IS NULL
        AND (
            tp.priority_id IS NOT NULL
            OR tp.classify_at < now() - public.classify_visibility_window()
        )
WHERE
    (n.draft = FALSE OR n.created_by = tp.user_id)
    AND (a.draft = FALSE OR a.created_by = tp.user_id)
    AND (
        a.contacts && "user".user_contact_ids(tp.user_id)
        OR a.groups && "user".user_group_ids(tp.user_id)
        OR (a.topic_id IS NOT NULL AND a.topic_id = ANY("user".user_topic_ids(tp.user_id)))
    )
    -- Hidden by note-level access restriction
    AND n.created_by != tp.user_id
    AND (n.access_contacts IS NOT NULL OR n.access_groups IS NOT NULL)
    AND NOT (
        (n.access_contacts IS NOT NULL AND n.access_contacts && "user".user_contact_ids(tp.user_id))
        OR (n.access_groups IS NOT NULL AND n.access_groups && "user".user_group_ids(tp.user_id))
    )
    -- Exclude users who are in this thread's dropped_contacts — they should
    -- not see redacted stubs for messages they never had access to. Without
    -- this filter, dropped users (still in thread.contacts for visibility)
    -- would receive stubs for every post-drop note, leaking message existence.
    AND NOT (
        a.dropped_contacts IS NOT NULL
        AND cardinality(a.dropped_contacts) > 0
        AND a.dropped_contacts && "user".user_contact_ids(tp.user_id)
    );


-- User-accessible note tags
--
-- Driven from "user".thread (per-user) so the planner scopes work to the
-- user's visible notes instead of aggregating every public.note_tag row in
-- the database. Mirrors the LATERAL pattern used by user.thread_tags.
CREATE OR REPLACE VIEW "user"."note_tags"
--
AS
SELECT
    ua.user_id,
    n.id,
    nt.updated_at,
    nt.seq,
    ua.archived_at,
    ua.priority_id,
    ua.priority_path,
    nt.tags
FROM
    "user".thread ua
    JOIN note n ON n.thread_id = ua.id
    JOIN LATERAL (
        SELECT
            jsonb_object_agg(sq.tag_id, sq.actor_ids) FILTER (WHERE sq.actor_ids IS NOT NULL
                AND jsonb_array_length(sq.actor_ids) > 0) AS tags,
            MAX(sq.updated_at) AS updated_at,
            MAX(sq.seq) AS seq
        FROM (
            SELECT
                nt.tag_id,
                jsonb_agg(nt.actor_id ORDER BY nt.actor_id) FILTER (WHERE nt.archived_at IS NULL) AS actor_ids,
                MAX(COALESCE(nt.archived_at, nt.updated_at)) AS updated_at,
                MAX(nt.seq) AS seq
            FROM "public"."note_tag" nt
            WHERE nt.note_id = n.id
            GROUP BY nt.tag_id) sq
        HAVING COUNT(*) > 0) nt ON TRUE
WHERE
    (n.draft = FALSE OR n.created_by = ua.user_id)
    AND (
        n.created_by = ua.user_id
        OR (n.access_contacts IS NULL AND n.access_groups IS NULL)
        OR (n.access_contacts IS NOT NULL AND n.access_contacts && "user".user_contact_ids(ua.user_id))
        OR (n.access_groups IS NOT NULL AND n.access_groups && "user".user_group_ids(ua.user_id))
    );

