-- Per-user filtered reaction views.
--
-- Mirror of user.note_tags / user.thread_tags but keyed by emoji string
-- (Unicode grapheme or `provider:workspace/name` custom-emoji ref) rather
-- than tag_id integer. Driven from "user".thread so the planner scopes
-- work to the user's visible threads/notes instead of aggregating every
-- public.note_reaction row in the database.

CREATE OR REPLACE VIEW "user"."note_reactions"
--
AS
SELECT
    ua.user_id,
    n.id,
    nr.updated_at,
    nr.seq,
    ua.archived_at,
    ua.priority_id,
    ua.priority_path,
    nr.reactions
FROM
    "user".thread ua
    JOIN note n ON n.thread_id = ua.id
    JOIN LATERAL (
        SELECT
            jsonb_object_agg(sq.emoji, sq.actor_ids) FILTER (WHERE sq.actor_ids IS NOT NULL
                AND jsonb_array_length(sq.actor_ids) > 0) AS reactions,
            MAX(sq.updated_at) AS updated_at,
            MAX(sq.seq) AS seq
        FROM (
            SELECT
                nr.emoji,
                jsonb_agg(nr.actor_id ORDER BY nr.actor_id) FILTER (WHERE nr.archived_at IS NULL) AS actor_ids,
                MAX(COALESCE(nr.archived_at, nr.updated_at)) AS updated_at,
                MAX(nr.seq) AS seq
            FROM "public"."note_reaction" nr
            WHERE nr.note_id = n.id
            GROUP BY nr.emoji) sq
        HAVING COUNT(*) > 0) nr ON TRUE
WHERE
    (n.draft = FALSE OR n.created_by = ua.user_id)
    -- Scheduled-send hold: no reaction rows for notes invisible to this user
    AND (n.send_at IS NULL OR n.send_at <= now() OR n.created_by = ua.user_id)
    AND (n.access_contacts IS NULL
        OR n.created_by = ua.user_id
        OR n.access_contacts && "user".user_contact_ids(ua.user_id));


CREATE OR REPLACE VIEW "user"."thread_reactions"
--
AS
SELECT
    ua.user_id,
    ua.id,
    ua.archived_at,
    tr.occurrence,
    tr.updated_at,
    tr.seq,
    ua.priority_id,
    ua.priority_path,
    tr.reactions
FROM
    "user".thread ua
    JOIN LATERAL (
        SELECT
            sq.occurrence,
            jsonb_object_agg(sq.emoji, sq.actor_ids) FILTER (WHERE sq.actor_ids IS NOT NULL
                AND jsonb_array_length(sq.actor_ids) > 0) AS reactions,
            MAX(sq.updated_at) AS updated_at,
            MAX(sq.seq) AS seq
        FROM (
            SELECT
                tr.occurrence,
                tr.emoji,
                jsonb_agg(tr.actor_id) FILTER (WHERE tr.archived_at IS NULL) AS actor_ids,
                MAX(COALESCE(tr.archived_at, tr.updated_at)) AS updated_at,
                MAX(tr.seq) AS seq
            FROM
                "public"."thread_reaction" tr
            WHERE
                tr.thread_id = ua.id
            GROUP BY
                tr.occurrence,
                tr.emoji) sq
        GROUP BY
            sq.occurrence) tr ON true;
