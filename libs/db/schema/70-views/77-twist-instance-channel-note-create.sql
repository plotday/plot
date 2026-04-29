-- Notes created on threads that have links from source channels a twist is observing.
-- Used to dispatch onLinkNoteCreated callbacks to twists with link permission.
-- DISTINCT ON deduplicates when a thread has multiple links from the same channel.
CREATE OR REPLACE VIEW "public"."twist_instance_channel_note_create" --
AS
SELECT DISTINCT ON (ptc.twist_instance_id, n.id)
    ptc.twist_instance_id,
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
    -- Link fields
    l.id AS link_id,
    l.source AS link_source,
    l.title AS link_title,
    l.type AS link_type,
    l.meta AS link_meta,
    l.channel_id AS link_channel_id,
    l.source_url AS link_source_url,
    -- Enriched fields
    tp.priority_id,
    t.title AS thread_title,
    t.created_by AS thread_created_by,
    author.name AS author_name,
    author.type AS author_type,
    nt.tags
FROM
    twist_instance_channel ptc
    JOIN link l ON l.created_by = ptc.source_twist_instance_id
        AND l.channel_id = ptc.channel_id
    JOIN thread t ON t.id = l.thread_id
    JOIN note n ON n.thread_id = t.id
    JOIN twist_instance pt ON pt.id = ptc.twist_instance_id
    LEFT JOIN thread_priority tp ON tp.thread_id = t.id AND tp.user_id = pt.owner_id
    LEFT JOIN actor author ON author.id = n.author_id
    LEFT JOIN note_tags nt ON nt.note_id = n.id
WHERE
    ptc.enabled = TRUE
    AND pt.archived_at IS NULL
    AND t.draft = FALSE
    AND n.draft = FALSE
    AND n.created_by != ptc.twist_instance_id
    AND n.created_at > pt.created_at
ORDER BY
    ptc.twist_instance_id,
    n.id,
    n.created_at ASC;
