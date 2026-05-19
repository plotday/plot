-- User-scoped thread association view
-- Shows associations where the user has a thread_priority row for the parent thread
CREATE OR REPLACE VIEW "user"."thread_association"
--
AS
SELECT
    tp.user_id,
    ta.id,
    ta.created_at,
    ta.updated_at,
    ta.seq,
    ta.archived_at,
    ta.parent_thread_id,
    ta.child_thread_id,
    ta."order"
FROM
    thread_association ta
    JOIN thread_priority tp ON tp.thread_id = ta.parent_thread_id
        AND (
            tp.priority_id IS NOT NULL
            OR tp.classify_at < now() - public.classify_visibility_window()
        );
