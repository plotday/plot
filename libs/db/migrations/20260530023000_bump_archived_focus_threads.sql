-- Re-emit threads filed under focuses that were ALREADY archived before this
-- release so clients pick up the new "user".effective_priority_id projection
-- (an archived focus now releases its threads to the Inbox/root at read time).
-- Without this, such threads would not re-sync until otherwise touched.
UPDATE "public"."thread" SET updated_at = now()
WHERE id IN (
    SELECT tp.thread_id
    FROM "public"."thread_priority" tp
    JOIN "public"."priority" p ON p.id = tp.priority_id
    WHERE p.archived_at IS NOT NULL
);
