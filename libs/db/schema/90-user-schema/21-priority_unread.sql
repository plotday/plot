-- user.priority_unread — "does this priority have any notify-worthy unread
-- threads visible to this user?". Mirrors user.thread's visibility: a thread
-- counts only if thread_priority has a row for the user, the thread is
-- visible through the user's contacts or groups, and (if the thread is
-- team-scoped) the user is still a current member of that team or an exempt
-- external (customer) contact.
--
-- A row counts toward the unread dot only when its thread_state row has
-- importance >= 50 OR urgent = TRUE. Low-importance items (promotional /
-- unsolicited / passive update) intentionally do not light up priorities
-- so the user can choose whether to look at Catch up rather than being
-- prompted by an indicator.
CREATE OR REPLACE VIEW "user"."priority_unread" --
AS
SELECT
    tp.user_id,
    "user".effective_priority_id(tp.priority_id, tp.user_id) AS priority_id,
    TRUE AS unread,
    MAX(ts.updated_at) AS updated_at
FROM
    thread_priority tp
    JOIN thread a ON a.id = tp.thread_id
        AND a.archived_at IS NULL
        AND tp.archived_at IS NULL
        AND tp.revoked_at IS NULL
        AND (a.draft = FALSE OR a.created_by = tp.user_id)
        AND (
            a.contacts && "user".user_contact_ids(tp.user_id)
            OR a.groups && "user".user_group_ids(tp.user_id)
        )
        -- Pending case-A rows past the visibility window fall back to root;
        -- fresh pending rows are hidden so phantom unread dots don't appear.
        AND (
            tp.priority_id IS NOT NULL
            OR tp.classify_at < now() - public.classify_visibility_window()
        )
        -- Team firewall (thread-scoped, mirrors user.thread): a team thread
        -- counts only for current members of thread.team_id, EXCEPT contacts
        -- explicitly marked external (non-team customers), who are exempt.
        -- Personal threads (team_id NULL) are ungated.
        AND (
            a.team_id IS NULL
            OR a.external_contacts && "user".user_contact_ids(tp.user_id)
            OR EXISTS (
                SELECT 1 FROM public.team_user tu2
                WHERE tu2.team_id = a.team_id
                  AND tu2.user_id = tp.user_id
                  AND tu2.archived_at IS NULL
            )
        )
    JOIN thread_state ts ON ts.user_id = tp.user_id
        AND ts.thread_id = a.id
        AND ts.read_at IS NULL
        -- Importance gate: low-importance unreads don't trip the dot
        -- unless they're flagged urgent.
        AND (ts.importance >= 50 OR ts.urgent = TRUE)
GROUP BY
    tp.user_id,
    "user".effective_priority_id(tp.priority_id, tp.user_id);
