-- Repair source_created_at ordering for onboarding threads on the Plot
-- system twist. In prod, the repair step in
-- 20260414233030_repair_onboarding_visibility used
--   row_number() OVER (ORDER BY created_at ASC)
-- but every onboarding note in a thread was inserted in the same statement
-- and shares an identical created_at, so the tie-break is unspecified.
-- Several threads (welcome, connections, getting-around, notifications)
-- ended up reversed on prod while local dev DBs happened to tie the other
-- way and stayed correct.
--
-- Safety: for each wrongly-ordered thread, we shift every note's
-- source_created_at DOWN so that the new value is <= the thread's current
-- minimum (and therefore <= every note's current value). No note becomes
-- "newer" from any user's perspective, so no thread_unread.read_at can
-- cross a note's source_created_at and flip a read note to unread. The
-- thread.last_note_source_created_at cache is GREATEST-maintained only
-- on INSERT/DELETE (see update_thread_on_note_change trigger), so plain
-- UPDATEs of source_created_at do not bump it either.
--
-- Idempotency: a per-thread guard skips the UPDATE when the notes are
-- already in the expected order, so re-running (and fresh dev DBs that
-- were never broken) are no-ops.
--
-- Data-only migration. Safe to re-run.

DO $$
DECLARE
    c_twist_package_id CONSTANT uuid := '0199b6f4-ae64-7718-8a02-44716f30358f';
    v_plot_twist_id bigint;
    v_thread_id uuid;
    v_min timestamptz;
    v_ordered boolean;
    r record;
    p record;
BEGIN
    SELECT id INTO v_plot_twist_id
    FROM twist
    WHERE twist_package_id = c_twist_package_id AND environment = 'public'
    LIMIT 1;
    IF v_plot_twist_id IS NULL THEN RETURN; END IF;

    FOR r IN
        SELECT * FROM (VALUES
            ('welcome',        4),
            ('priorities',     4),
            ('connections',    3),
            ('getting-around', 3),
            ('twists',         4),
            ('notifications',  4),
            ('clean-up',       2)
        ) AS t(thread_key, note_count)
    LOOP
        SELECT id INTO v_thread_id
        FROM thread
        WHERE key = r.thread_key AND twist_id = v_plot_twist_id
        LIMIT 1;
        IF v_thread_id IS NULL THEN CONTINUE; END IF;

        -- Classify each note to its expected position, then compare to
        -- its actual rank by source_created_at. If every note is already
        -- in the right slot, skip this thread (idempotent no-op).
        SELECT bool_and(exp_pos = act_pos), MIN(source_created_at)
        INTO v_ordered, v_min
        FROM (
            SELECT
                source_created_at,
                CASE r.thread_key
                    WHEN 'welcome' THEN
                        CASE
                            WHEN content LIKE 'Plot is your workspace%' THEN 0
                            WHEN content LIKE 'When a thread needs your attention%' THEN 1
                            WHEN content LIKE 'The **Agenda** is everything%' THEN 2
                            WHEN content LIKE 'Threads can contain links%' THEN 3
                        END
                    WHEN 'priorities' THEN
                        CASE
                            WHEN content LIKE 'Priorities are contexts for focus%' THEN 0
                            WHEN content LIKE '**Viewing a priority shows%' THEN 1
                            WHEN content LIKE '**Best practice:**%' THEN 2
                            WHEN content LIKE 'Create your first priority%' THEN 3
                        END
                    WHEN 'connections' THEN
                        CASE
                            WHEN content LIKE '**Connections** sync items%' THEN 0
                            WHEN content LIKE 'Each connection has channels%' THEN 1
                            WHEN content LIKE 'Set up your first connection%' THEN 2
                        END
                    WHEN 'getting-around' THEN
                        CASE
                            WHEN content LIKE 'Plot''s goal%' THEN 0
                            WHEN content LIKE '**Keyboard Navigation**%' THEN 1
                            WHEN content LIKE '**Touch Gestures**%' THEN 2
                        END
                    WHEN 'twists' THEN
                        CASE
                            WHEN content LIKE '**Twists** are automations%' THEN 0
                            WHEN content LIKE 'You can also **create your own twists**%' THEN 1
                            WHEN content LIKE 'You can also **@mention Plot**%' THEN 2
                            WHEN content LIKE 'Try **@mentioning Plot**%' THEN 3
                        END
                    WHEN 'notifications' THEN
                        CASE
                            WHEN content LIKE 'Plot has smart notifications%' THEN 0
                            WHEN content LIKE 'Each priority has two timing%' THEN 1
                            WHEN content LIKE 'Plot also has **quiet hours**%' THEN 2
                            WHEN content LIKE 'Adjust notification timing%' THEN 3
                        END
                    WHEN 'clean-up' THEN
                        CASE
                            WHEN content LIKE 'When something is no longer%' THEN 0
                            WHEN content LIKE 'You can archive both%' THEN 1
                        END
                END AS exp_pos,
                row_number() OVER (ORDER BY source_created_at) - 1 AS act_pos
            FROM note
            WHERE thread_id = v_thread_id
        ) positions;

        IF v_ordered IS TRUE THEN CONTINUE; END IF;

        -- Reorder: each note at expected position P gets
        --   v_min - (note_count - 1 - P) * 1 minute
        -- so every new value is <= v_min <= every current value.
        FOR p IN
            SELECT position, content_pattern FROM (VALUES
                ('welcome',        0, 'Plot is your workspace%'),
                ('welcome',        1, 'When a thread needs your attention%'),
                ('welcome',        2, 'The **Agenda** is everything%'),
                ('welcome',        3, 'Threads can contain links%'),
                ('priorities',     0, 'Priorities are contexts for focus%'),
                ('priorities',     1, '**Viewing a priority shows%'),
                ('priorities',     2, '**Best practice:**%'),
                ('priorities',     3, 'Create your first priority%'),
                ('connections',    0, '**Connections** sync items%'),
                ('connections',    1, 'Each connection has channels%'),
                ('connections',    2, 'Set up your first connection%'),
                ('getting-around', 0, 'Plot''s goal%'),
                ('getting-around', 1, '**Keyboard Navigation**%'),
                ('getting-around', 2, '**Touch Gestures**%'),
                ('twists',         0, '**Twists** are automations%'),
                ('twists',         1, 'You can also **create your own twists**%'),
                ('twists',         2, 'You can also **@mention Plot**%'),
                ('twists',         3, 'Try **@mentioning Plot**%'),
                ('notifications',  0, 'Plot has smart notifications%'),
                ('notifications',  1, 'Each priority has two timing%'),
                ('notifications',  2, 'Plot also has **quiet hours**%'),
                ('notifications',  3, 'Adjust notification timing%'),
                ('clean-up',       0, 'When something is no longer%'),
                ('clean-up',       1, 'You can archive both%')
            ) AS t(thread_key, position, content_pattern)
            WHERE thread_key = r.thread_key
        LOOP
            UPDATE note
            SET source_created_at = v_min - ((r.note_count - 1 - p.position) * interval '1 minute')
            WHERE thread_id = v_thread_id
              AND content LIKE p.content_pattern;
        END LOOP;
    END LOOP;
END $$;
