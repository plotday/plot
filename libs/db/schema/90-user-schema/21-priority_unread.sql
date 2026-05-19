-- user.priority_unread — "does this priority have any unread threads
-- visible to this user?". Mirrors user.thread's visibility: a thread
-- counts only if thread_priority has a row for the user, the thread is
-- visible through the user's contacts or groups, and (if the priority is
-- team-scoped) the user is still a current member of that team. Without
-- the team_user guard, leaving a team would leave stale unread dots on
-- the team's priorities until the priority-archive cascade reaches the
-- client.
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
        AND (
            a.contacts && "user".user_contact_ids(tp.user_id)
            OR a.groups && "user".user_group_ids(tp.user_id)
        )
    JOIN priority p ON p.id = tp.priority_id
        AND (
            p.team_id IS NULL
            OR EXISTS (
                SELECT 1 FROM public.team_user tu2
                WHERE tu2.team_id = p.team_id
                  AND tu2.user_id = tp.user_id
                  AND tu2.archived_at IS NULL
            )
        )
    JOIN thread_unread tu ON tu.user_id = tp.user_id
        AND tu.thread_id = a.id
        AND tu.read_at IS NULL
GROUP BY
    tp.user_id,
    tp.priority_id;
