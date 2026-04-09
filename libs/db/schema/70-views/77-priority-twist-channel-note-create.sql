-- Notes created on threads that have links from source channels a twist is observing.
-- Used to dispatch onLinkNoteCreated callbacks to twists with link permission.
-- DISTINCT ON deduplicates when a thread has multiple links from the same channel.
CREATE OR REPLACE VIEW "public"."priority_twist_channel_note_create" --
AS
SELECT DISTINCT ON (ptc.priority_twist_id, n.id)
    ptc.priority_twist_id,
    n.id,
    n.created_at,
    n.updated_at,
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
    t.priority_id,
    t.title AS thread_title,
    t.created_by AS thread_created_by,
    author.name AS author_name,
    author.type AS author_type,
    nt.tags
FROM
    priority_twist_channel ptc
    JOIN link l ON l.created_by = ptc.source_priority_twist_id
        AND l.channel_id = ptc.channel_id
    JOIN thread t ON t.id = l.thread_id
    JOIN note n ON n.thread_id = t.id
    JOIN priority_twist pt ON pt.id = ptc.priority_twist_id
    JOIN priority pp ON pp.id = pt.priority_id
    JOIN priority pc ON pc.id = t.priority_id
        AND pc.path <@ pp.path
    LEFT JOIN actor author ON author.id = n.author_id
    LEFT JOIN note_tags nt ON nt.note_id = n.id
WHERE
    ptc.enabled = TRUE
    AND pt.archived_at IS NULL
    AND t.draft = FALSE
    AND n.draft = FALSE
    AND n.created_by != ptc.priority_twist_id
    AND n.created_at > pt.created_at
ORDER BY
    ptc.priority_twist_id,
    n.id,
    n.created_at ASC;
