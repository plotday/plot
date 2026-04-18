-- Repair onboarding thread ownership and rebuild thread-sourced user_contact rows.
--
-- Seven onboarding threads (keys: welcome, priorities, connections,
-- getting-around, twists, notifications, clean-up) were partially migrated
-- by 20260415202415_system_plot_twist_instance_and_onboarding. They received
-- twist_id pointing at the Plot twist, but their created_by still pointed
-- at the original user author (kris@plot.day in prod). The migration's
-- reattribution UPDATE guarded on twist_id IS NULL and so skipped them.
--
-- Because created_by was still a real user, file_thread_priority_peers
-- treated these threads as user-authored and let every subsequent signer-up
-- promote themselves from pending_contacts into thread.contacts on their
-- own upsert_thread call. sync_user_contact_for_thread_contacts then
-- cross-pollinated user_contact: every user on thread.contacts ended up
-- with user_contact rows for every other user on those same threads.
--
-- Repair is two-phase:
--   1. Reassign the 7 threads' created_by to the system twist_instance so
--      peer-filing treats them as twist-authored (early-return path) and
--      no further contamination can occur. Clear thread.contacts to {}.
--   2. Rebuild every user_contact row with source='thread' from the current
--      (thread_priority × thread.contacts) product. Rows that no longer
--      correspond to any reachable thread are dropped. source='self'
--      identity links (linked=TRUE) are untouched.

DO $$
DECLARE
    c_system_instance_id CONSTANT uuid := '0199b6f4-ae64-7718-0000-000000000001';
BEGIN
    IF EXISTS (SELECT 1 FROM twist_instance WHERE id = c_system_instance_id) THEN
        UPDATE thread
        SET created_by = c_system_instance_id,
            contacts   = ARRAY[]::uuid[]
        WHERE key IN ('welcome', 'priorities', 'connections', 'getting-around',
                      'twists', 'notifications', 'clean-up')
          AND created_by <> c_system_instance_id;
    END IF;
END $$;

DELETE FROM user_contact WHERE source = 'thread';

INSERT INTO user_contact (user_id, contact_id, linked, source)
SELECT DISTINCT tp.user_id, arr.contact_id, FALSE, 'thread'
FROM thread_priority tp
JOIN thread t ON t.id = tp.thread_id
CROSS JOIN LATERAL unnest(t.contacts) AS arr(contact_id)
WHERE EXISTS (SELECT 1 FROM contact c WHERE c.id = arr.contact_id)
ON CONFLICT (user_id, contact_id) DO NOTHING;
