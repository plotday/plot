-- Follow-up to 20260418050000_repair_onboarding_thread_ownership.
--
-- The previous migration gated its UPDATE on `created_by <> system_twist_instance`,
-- which skipped threads whose created_by had already been fixed (by an earlier
-- partial repair or a direct INSERT) but whose thread.contacts still carried
-- historic contamination. Clear contacts unconditionally on the 7 onboarding
-- keys, then rebuild source='thread' user_contact rows from the new state.

UPDATE thread
SET contacts = ARRAY[]::uuid[]
WHERE key IN ('welcome', 'priorities', 'connections', 'getting-around',
              'twists', 'notifications', 'clean-up')
  AND cardinality(COALESCE(contacts, ARRAY[]::uuid[])) > 0;

DELETE FROM user_contact WHERE source = 'thread';

INSERT INTO user_contact (user_id, contact_id, linked, source)
SELECT DISTINCT tp.user_id, arr.contact_id, FALSE, 'thread'
FROM thread_priority tp
JOIN thread t ON t.id = tp.thread_id
CROSS JOIN LATERAL unnest(t.contacts) AS arr(contact_id)
WHERE EXISTS (SELECT 1 FROM contact c WHERE c.id = arr.contact_id)
ON CONFLICT (user_id, contact_id) DO NOTHING;
