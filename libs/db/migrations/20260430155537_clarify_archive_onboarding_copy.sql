-- Clarify what archiving is for in the onboarding "Clean up without
-- losing anything" thread. The previous copy framed archive as the way
-- to handle "completed projects" and "finished threads", which conflates
-- archive with finishing work. In Plot:
--   - Archive a thread = soft-delete a mistake (hides for everyone).
--   - Archive a priority = hide a priority you're no longer working in.
--   - To finish work on a thread, "Remove from agenda" — that keeps the
--     thread in Activity for everyone and completes tasks/linked items.
--
-- Also points users at the new location for "Show archived" /
-- "Hide archived", which moved out of the search-filter chips into the
-- priority's "More commands" menu.
--
-- Data-only migration. Targets the `clean-up` thread on the system Plot
-- twist by key + twist_id. Defensive LIKE guards on the existing copy
-- make this a no-op once applied (mirrors 20260417205228).

DO $$
DECLARE
    c_twist_package_id CONSTANT uuid := '0199b6f4-ae64-7718-8a02-44716f30358f';
    v_plot_twist_id bigint;
    v_thread_id uuid;
BEGIN
    SELECT id INTO v_plot_twist_id
    FROM twist
    WHERE twist_package_id = c_twist_package_id
      AND environment = 'public'
    LIMIT 1;

    IF v_plot_twist_id IS NULL THEN
        RETURN;
    END IF;

    SELECT id INTO v_thread_id
    FROM thread
    WHERE key = 'clean-up' AND twist_id = v_plot_twist_id
    LIMIT 1;

    IF v_thread_id IS NULL THEN
        RETURN;
    END IF;

    UPDATE thread
    SET preview =
'Archive removes mistakes and hides priorities you''re no longer working in. To finish a thread, **Remove it from your agenda** instead.'
    WHERE id = v_thread_id
      AND preview LIKE '%no longer actively in progress, you can archive it%';

    UPDATE note
    SET content =
'**Archive a thread** when it shouldn''t have been created — a duplicate, a stray, or a mistake. Archive isn''t how you mark work done: when you''ve finished your part, **Remove it from your agenda** instead. That keeps the thread in Activity for everyone and completes your tasks plus any linked items in connected apps.

**Archive a priority** when you''re no longer working in that area. The priority and everything inside it disappears from your main view.

Archive hides items everywhere — for you and anyone you share with. Nothing is deleted; you can bring items back anytime.'
    WHERE thread_id = v_thread_id
      AND content LIKE '%a completed project, an old priority, a finished thread%';

    UPDATE note
    SET content =
'To archive, open the command menu on any thread or priority. To see archived items, open the priority and choose **Show archived** from its **More commands** menu — archived threads, notes, and child priorities reappear so you can unarchive them.'
    WHERE thread_id = v_thread_id
      AND content LIKE '%Use the command menu on any priority or thread to find the archive option%';
END $$;
