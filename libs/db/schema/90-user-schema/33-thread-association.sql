-- User-scoped thread association view
-- Shows associations where the user has access to the parent thread's priority
CREATE OR REPLACE VIEW "user"."thread_association"
--
AS
SELECT
    upe.user_id,
    ta.id,
    ta.created_at,
    ta.updated_at,
    ta.archived_at,
    ta.parent_thread_id,
    ta.child_thread_id,
    ta."order"
FROM
    thread_association ta
    JOIN thread t ON t.id = ta.parent_thread_id
    JOIN "user".priority_expanded upe ON upe.priority_id = t.priority_id;
