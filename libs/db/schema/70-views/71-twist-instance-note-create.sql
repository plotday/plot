-- Notes that a twist should receive for the "create" callback.
-- A twist receives a note only if the twist is mentioned in that note's
-- mentions array. Twists are workspace-level so there is no priority
-- subtree check — the mention itself is the routing mechanism.
CREATE OR REPLACE VIEW "public"."twist_instance_note_create" --
AS
SELECT
    pt.id AS twist_instance_id,
    n.id,
    n.created_at,
    n.updated_at,
    n.seq,
    n.source_created_at,
    n.author_id,
    n.created_by,
    n.updated_by,
    n.sync_depth,
    n.archived_at,
    n.thread_id,
    n.draft,
    n.access_contacts,
    n.content,
    n.actions,
    n.key,
    n.mentions,
    n.re_note_id,
    -- Enriched fields
    tp.priority_id,
    a.title AS thread_title,
    a.created_by AS thread_created_by,
    NULL::jsonb AS thread_meta,
    author.name AS author_name,
    author.type AS author_type,
    nt.tags
FROM
    twist_instance pt
    JOIN note n ON pt.id = ANY (n.mentions)
    JOIN thread a ON a.id = n.thread_id
        AND a.archived_at IS NULL
    LEFT JOIN thread_priority tp ON tp.thread_id = a.id AND tp.user_id = pt.owner_id
    LEFT JOIN actor author ON author.id = n.author_id
    LEFT JOIN note_tags nt ON nt.note_id = n.id
WHERE
    n.draft = FALSE
    -- Exclude archived notes. This view is driven by a seq cursor on the
    -- mutable n.seq, which bumps on EVERY note update — including archival.
    -- Without this guard, archiving a note re-bumps its seq past the
    -- create-cursor and re-surfaces it as a "new note", re-firing the
    -- connector's onNoteCreated (and re-sending it to the external service
    -- if the first dispatch left no idempotency guard). A note the user
    -- archived must never generate a create/send dispatch.
    AND n.archived_at IS NULL
    AND n.created_by != pt.id
    AND updated_by_uuid (pt.id) != n.updated_by
    AND pt.archived_at IS NULL
    AND n.created_at > pt.created_at
ORDER BY
    created_at ASC;
