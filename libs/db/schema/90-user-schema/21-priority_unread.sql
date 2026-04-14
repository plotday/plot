-- user.priority_unread — "does this priority have any unread threads
-- visible to this user?". Uses the same contacts-based visibility as
-- user.thread: a thread counts only if thread_priority has a row for
-- the user AND any of the user's linked contacts is present in
-- thread.contacts.
CREATE OR REPLACE VIEW "user"."priority_unread" --
AS
SELECT
    tp.user_id,
    tp.priority_id,
    TRUE AS unread,
    MAX(tu.updated_at) AS updated_at
FROM
    thread_priority tp
    JOIN thread a ON a.id = tp.thread_id
        AND a.archived_at IS NULL
        AND tp.archived_at IS NULL
        AND (a.draft = FALSE OR a.created_by = tp.user_id)
        AND a.contacts && "user".user_contact_ids(tp.user_id)
    JOIN thread_unread tu ON tu.user_id = tp.user_id
        AND tu.thread_id = a.id
        AND tu.read_at IS NULL
GROUP BY
    tp.user_id,
    tp.priority_id;
